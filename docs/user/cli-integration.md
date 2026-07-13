# CLI integration

`pg-migrate-cli` is a reusable library, not a standalone executable. The application
supplies the exact embedded plan and owns configuration precedence, credentials, streams,
logging, and the final process exit code. The library supplies parsers, command dispatch,
structured outcomes, and text or JSON rendering.

This boundary prevents an executable installed independently of the service from
discovering a different migration plan at runtime.

## Mount the command parser

Add `migrationCommandParser plan` to an `optparse-applicative` program:

```haskell
import Database.PostgreSQL.Migrate (MigrationPlan)
import Database.PostgreSQL.Migrate.CLI
import Options.Applicative

parseMigrationCommand :: MigrationPlan -> IO MigrationCommand
parseMigrationCommand plan =
  execParser
    ( info
        (migrationCommandParser plan <**> helper)
        (fullDesc <> progDesc "Manage the service migration plan")
    )
```

You may use this parser as the whole administrative executable, as the
[`examples/basic`](../../examples/basic/app/Main.hs) application does, or nest it under a
service-owned subcommand.

The parser is pure. It never reads environment variables, configuration files, or a
database. That remains application policy.

## Supply the default connection

For a concrete Hasql connection string:

```haskell
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI
import Hasql.Connection.Settings qualified as Settings

let environment =
      cliEnvironment
        (Settings.connectionString (Text.pack databaseUrl))
        plan
        defaultRunOptions
```

If the application already owns a connection-acquisition bracket, adapt it once and keep
the dedicated-connection guarantee:

```haskell
let provider = connectionProvider applicationConnectionBracket
    environment =
      cliEnvironmentWithConnectionProvider
        provider
        plan
        defaultRunOptions
```

Every database operation needs one dedicated connection for its entire session lock,
execution, and cleanup. Do not implement a provider by checking a connection out of a pool
for each individual statement.

Database-backed commands accept `--database-url URL`. When present, that explicit flag
overrides the environment's default connection. When absent, the `CliEnvironment` default
is used. The CLI library never gives an environment variable an implicit precedence.

## Configure runner defaults

Build options from `defaultRunOptions` with functional modifiers:

```haskell
import Database.PostgreSQL.Migrate

let runOptions =
      withEventHandler emitMigrationEvent
        $ withStatementTimeout (Just 120)
        $ withLockWait (WaitFor 30)
        $ defaultRunOptions
```

Durations are `NominalDiffTime` values in seconds in the Haskell API.
`withStatementTimeout (Just duration)` requires a strictly positive duration; zero and
negative values fail with `InvalidStatementTimeout` before a connection is acquired. Use
`Nothing` when no temporary statement-timeout override is wanted.

On `up` and `repair`, an absent execution flag preserves the corresponding application
setting. The command-line `--no-wait`, `--lock-timeout MILLISECONDS`, and `--wait` flags
explicitly replace the lock policy for that command. `--statement-timeout MILLISECONDS`
sets a temporary timeout, while `--no-statement-timeout` explicitly disables it. The three
lock flags are mutually exclusive, as are the two statement-timeout flags.

The conservative defaults use the `pgmigrate` ledger schema, the project lock key,
indefinite lock waiting, no statement timeout, rejection of unknown stored migrations,
and no event callback. Read the [locking and timeout guide](../operations/locking-and-timeouts.md)
before choosing production limits.

`withUnknownMigrationsPolicy` configures how execution, repair, and history import treat
unknown stored rows. `migrationStatus` also honors that policy, while
`verifyMigrationPlan` remains unconditionally strict. Keep the default
`RejectUnknownMigrations` unless applications intentionally share one ledger; selecting
`AllowUnknownMigrations` does not relax validation of migrations owned by the active plan.

Use `withEventHandler` for application logging or telemetry. Events describe defined
lifecycle and durable boundaries; they do not change commit, rollback, or retry behavior.
If an event callback throws, the command returns a structured error and preserves an
underlying migration error when one already exists.

## Dispatch and render

Dispatching does not write to stdout or stderr and does not exit the process:

```haskell
outcome <- runMigrationCommand environment parsedCommand
```

Choose the renderer from the parsed command's `OutputOptions`:

```haskell
case commandOutputFormat parsedCommand of
  TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
  JsonOutput ->
    LazyByteString.putStrLn
      (Aeson.encode (renderMigrationCommandJson outcome))
```

Text output is for operators and may improve between compatible package versions. JSON is
the stable automation boundary: `--json` emits schema version 1 with stable command,
success, data, and error structure. See the [JSON v1 reference](../reference/json-v1.md).
Do not parse rendered text or `Show` output in automation.

The application also chooses how the result maps to process exit:

```haskell
exitCode :: ExitClass -> System.Exit.ExitCode
exitCode exit =
  case exit of
    ExitSucceeded -> System.Exit.ExitSuccess
    ExitVerificationFailed -> System.Exit.ExitFailure 2
    ExitUsageFailed -> System.Exit.ExitFailure 64
    ExitExecutionFailed -> System.Exit.ExitFailure 1
```

The four classes distinguish success, a valid strict verification report containing
issues, invalid command inputs or authoring state, and runtime execution failure. Keep the
mapping stable within the application if deployment automation relies on it.

## Command guide

| Command | Database | Purpose |
| --- | --- | --- |
| `plan` | no | show component order and dependencies |
| `list` | no | list declared migration metadata and checksums |
| `check --manifest PATH` | no | validate manifest syntax, file membership, and checksums |
| `status` | yes | summarize applied, pending, unknown, and inconsistent ledger state |
| `verify` | yes | strictly compare the complete declared plan with the ledger |
| `up` | yes | apply the complete validated pending plan |
| `repair COMPONENT/MIGRATION` | yes | perform one confirmed repair after operator inspection |
| `new` | no | create one SQL file and append it to a manifest |

All commands support `--json`. `plan`, `list`, `status`, and `verify` accept
`--component COMPONENT` and `--migration MIGRATION` display filters. These filters never
change validation or execution. A filter that names no migration in the application's plan
is a usage error rather than an empty successful result. Filtered status and verification
payloads include only issues for the selected migrations, but the exit class is still
computed from the complete report so a filtered view cannot conceal a failure. In
particular, `up` has no component, count, or target option: it always advances the complete
plan.

### Inspect before execution

A typical review sequence for a new artifact is:

```console
my-service-migrate plan
my-service-migrate list
my-service-migrate status --database-url "$DATABASE_URL"
my-service-migrate verify --database-url "$DATABASE_URL"
```

Strict `verify` reports pending migrations as issues, so a new artifact normally returns
`ExitVerificationFailed` with the expected pending suffix before deployment. Any checksum,
position, kind, mode, gap, unknown row, `Running`, or `Failed` issue needs explanation
before `up`.

### Apply the plan

```console
my-service-migrate up \
  --database-url "$DATABASE_URL" \
  --lock-timeout 30000 \
  --statement-timeout 120000 \
  --json
```

Timeout values are positive integer milliseconds. Use `--wait` to override an
application-configured finite or no-wait policy with indefinite waiting. Use
`--no-statement-timeout` to override an application-configured timeout. Choose values from
the service's operational requirements; a timeout does not make nontransactional SQL
atomic.

### Repair only after inspection

Repair targets exactly one nontransactional migration and requires an audit reason,
explicit operation, and confirmation:

```console
my-service-migrate repair accounts/0003-build-index \
  --mark-applied \
  --reason "index exists and matches reviewed definition" \
  --confirm
```

or:

```console
my-service-migrate repair accounts/0003-build-index \
  --retry \
  --reason "partial index was removed after inspection" \
  --confirm
```

Do not infer the operation from the ledger status alone. Follow the
[nontransactional repair runbook](../operations/nontransactional-repair.md) and retain the
command outcome with deployment records.

### Create a migration

```console
my-service-migrate new \
  --manifest migrations/accounts/manifest \
  --name 0004-add-preferences \
  --description "Add account preferences"
```

`new` edits local files only; it never runs the migration. Review and fill in the generated
SQL, then run `check` and rebuild the application. Descriptions must be a single line and
cannot contain control characters; invalid descriptions are rejected before any file is
created. See
[manifest authoring](manifest-authoring.md#create-the-next-migration).

## Integrate with application configuration safely

A practical precedence policy is:

1. parse service configuration and secrets using the application's existing mechanism;
2. build the default `CliEnvironment` from that configuration;
3. allow `--database-url` only where an explicit operator override is desired;
4. avoid logging full connection strings, because they may contain passwords;
5. render the structured outcome once and record the target environment separately.

For production, run the command from an explicit deployment job using the same reviewed
artifact as the service. Continue with the [deployment runbook](../operations/deployment.md).
