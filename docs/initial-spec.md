# pg-migrate Initial Specification

## Status

This document defines the first releasable version of `pg-migrate`.

Implementation correction (2026-07-10): the metadata schema is `pgmigrate`, not the
original draft's `pg_migrate`. PostgreSQL reserves the `pg_` prefix for system schemas and
rejects user attempts to create one on every supported server version.

`pg-migrate` is a Hasql-native migration library. It lets Haskell libraries own
and embed their migrations, lets an application compose those migrations in an
explicit order, and applies the result without exposing an engine-specific
parser, stream, or filesystem representation to consumers.

Replacing Codd, `codd-extras`, and `hasql-migration` provides the first migration
use cases, but they must not shape the core architecture. Compatibility lives in
separate adapter packages built on one generic history-import API.

The key words **must**, **must not**, **should**, and **may** are normative.

## 1. Product Requirements

The first release must:

1. Let each Haskell package own a named migration component.
2. Give migration names component-local scope instead of requiring globally
   unique timestamps.
3. Let components declare ordering dependencies on other components.
4. Let the final executable choose the order of otherwise unrelated components.
5. Embed SQL in the binary so runtime execution never depends on source files.
6. Apply transactional SQL and its ledger row atomically.
7. Represent interrupted nontransactional SQL explicitly and conservatively.
8. Detect changes to applied SQL with SHA-256 checksums stored in PostgreSQL.
9. Serialize a complete plan with a session-level PostgreSQL advisory lock.
10. Use one dedicated Hasql connection for the complete run.
11. Provide reusable `optparse-applicative` parsers for service executables.
12. Expose structured errors, reports, status values, and execution events so
    libraries and microservices can integrate without parsing rendered text.
13. Keep connection settings, custom acquisition strategy, configuration
    loading, logging, and process exit policy under consumer control while the
    runner owns the dedicated connection lifecycle.
14. Provide test support based on `ephemeral-pg` without adding it to the
    production dependency closure.
15. Require PostgreSQL 17 or newer. The first release supports and integration
    tests PostgreSQL 17 and 18.
16. Import existing history through maintained Codd and `hasql-migration`
    adapters without executing already-applied migrations.

The `pg-migrate` package must not depend on `codd`, `codd-extras`,
`hasql-migration`, `postgresql-simple`, Codd environment variables, or Codd's
internal modules.

Maintained import adapters may read predecessor ledgers, but they remain optional
packages and have no place in the normal runner API.

After v1, a new stable PostgreSQL major is supported only after it is present in
the integration matrix. The runner rejects PostgreSQL below 17 and stable majors
newer than its tested matrix. Removing an end-of-life supported major is
announced at least one minor release in advance and recorded in the
compatibility table.

## 2. Design Drivers

`pg-migrate` is intended for broad use across independently versioned Haskell
libraries and deployed microservices. Its architecture is driven by these
general constraints:

| Constraint                                                          | Design response                                                                 |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Libraries release migrations independently                          | Identity is `(component, migration)` and ordering is component-local            |
| Applications combine framework, infrastructure, and service schemas | Components retain explicit dependencies in the final plan                       |
| Deployment binaries must be self-contained                          | Exact SQL bytes are embedded at compile time                                    |
| Released history must be immutable                                  | SHA-256 is stored with every applied migration                                  |
| Multiple replicas can race during deploy                            | One session advisory lock covers the complete plan                              |
| DDL is not uniformly transactional                                  | Transactional and nontransactional execution have different, explicit semantics |
| Libraries and CLIs need the same engine                             | Core APIs return values and emit events; only CLI modules render or exit        |
| Consumers use different configuration systems                       | The library accepts typed settings or a bracketed connection provider           |
| Adding an embedded file must reliably rebuild                       | An ordered manifest is the tracked Template Haskell input                       |
| Tests should exercise real PostgreSQL behavior                      | A separate test-support package integrates with `ephemeral-pg`                  |

### Library quality bar

The public API must satisfy the following:

- Public data constructors are hidden unless direct construction is safe.
- Every validation and execution failure is represented by a structured error.
- Pure plan validation does not perform `IO` or inspect process environment.
- Runtime library functions do not write to stdout or stderr and do not call
  `exitWith`.
- Execution emits typed events through a caller-supplied callback.
- Reports preserve component identity, migration identity, timing, status, and
  underlying Hasql errors where available.
- Text and JSON rendering live at integration boundaries.
- JSON output has an explicit schema version.
- All ordering is deterministic and independent of `HashMap` or filesystem
  iteration order.
- Breaking public API, ledger, manifest, or JSON changes follow semantic
  versioning and include upgrade documentation.

## 3. Explicit Non-goals

Version 1 does not include:

- down migrations or automatic rollback;
- automatic retries;
- automatic repair;
- a general effects framework;
- arbitrary `IO` migrations;
- per-migration dependency edges;
- interleaving migrations from two components;
- remote or runtime filesystem migration sources;
- static SQL safety analysis;
- background migrations;
- whole-database schema snapshot generation or equality checks;
- compatibility code for another migration engine in the normal runner package.

The `verify` command in `pg-migrate` verifies the declared plan against the
ledger. It does **not** prove that the live PostgreSQL schema equals a snapshot.
This narrower meaning must be visible in command help and API documentation.

Schema drift detection can be added later as an independent package. It must not
be coupled to migration execution or require temporary filesystem
materialization.

## 4. Haskell Baseline

The implementation must follow the conventions in
`mori://shinzui/haskell-jitsurei`.

Every package uses GHC 9.12 or newer, `GHC2024`, and a shared Cabal stanza:

```cabal
common common
  default-language: GHC2024
  default-extensions:
    DeriveAnyClass
    DuplicateRecordFields
    MultilineStrings
    OverloadedLabels
    OverloadedStrings
```

Every library, executable, test, and benchmark stanza imports `common`.

The project defines `PgMigrate.Prelude`. `PackageImports` is enabled only in
that prelude module. Other modules import `PgMigrate.Prelude`, use postpositive
qualified imports, and import `Data.Generics.Labels ()` only in modules that use
generic-lens labels.

```haskell
module Database.PostgreSQL.Migrate.Runner where

import PgMigrate.Prelude

import Hasql.Connection qualified as Connection
import Hasql.Session qualified as Session
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions qualified as Transaction.Sessions
```

Records use unprefixed, strict fields and explicit deriving strategies:

```haskell
data MigrationId = MigrationId
  { component :: !ComponentName
  , name :: !MigrationName
  }
  deriving stock (Generic, Eq, Ord, Show)
```

Embedded multiline SQL in Haskell source uses `MultilineStrings`. Migration
files remain ordinary `.sql` files.

## 5. Core Model

The conceptual internal types are:

```haskell
newtype ComponentName = ComponentName
  { unComponentName :: Text
  }
  deriving stock (Generic, Eq, Ord, Show)

newtype MigrationName = MigrationName
  { unMigrationName :: Text
  }
  deriving stock (Generic, Eq, Ord, Show)

newtype MigrationChecksum = MigrationChecksum
  { unMigrationChecksum :: ByteString
  }
  deriving stock (Generic, Eq, Ord, Show)

data TransactionMode
  = Transactional
  | NonTransactional
  deriving stock (Generic, Eq, Ord, Show)

data MigrationKind
  = SqlKind
  | HaskellKind
  deriving stock (Generic, Eq, Ord, Show)

data MigrationAction
  = SqlAction !ByteString
  | TransactionAction !(Hasql.Transaction.Transaction ())
  | SessionAction !(Hasql.Session.Session ())

data Migration = Migration
  { name :: !MigrationName
  , description :: !(Maybe Text)
  , mode :: !TransactionMode
  , kind :: !MigrationKind
  , checksum :: !MigrationChecksum
  , action :: !MigrationAction
  }

data MigrationComponent = MigrationComponent
  { name :: !ComponentName
  , dependencies :: !(Set ComponentName)
  , migrations :: !(NonEmpty Migration)
  }

data MigrationPlan = MigrationPlan
  { components :: !(NonEmpty MigrationComponent)
  }
```

These constructors are internal. Public smart constructors return structured
errors and are the only way to build validated values.

```haskell
componentName :: Text -> Either DefinitionError ComponentName
migrationName :: Text -> Either DefinitionError MigrationName
migrationId :: Text -> Text -> Either DefinitionError MigrationId

migrationComponent
  :: Text
  -> Set Text
  -> NonEmpty Migration
  -> Either DefinitionError MigrationComponent
```

Identifiers must be non-empty printable ASCII, must not contain `/`, control
characters, or surrounding whitespace, and must be no longer than 200 bytes in
UTF-8. The conventional native name is a zero-padded package-local sequence such
as `0001-create-message-store`. The manifest, not the identifier grammar, is the
source of execution order.

## 6. Identity and Ordering

A migration is identified by both its component and its local name:

```text
event-store/0001-create-message-store
event-store/0002-create-stream-indexes
event-sourcing/0001-create-projection-checkpoints
queue/0001-create-queue-schema
orders-service/0001-create-orders
```

The order of `migrations` inside a component is authoritative. The name prefix
is for humans and does not replace the ordered manifest.

Once a migration in a component is applied:

- existing entries must not be renamed, modified, removed, or reordered;
- new entries must be appended;
- the applied migrations known to the current binary must form a prefix of the
  component's current migration list.

This prefix rule prevents a newly inserted `0002` from running after an already
applied `0003`.

There is no global sequence such as:

```text
0001-event-store
0002-queue
0003-orders-service
```

That model couples independent packages and is intentionally rejected.

## 7. Components and Plans

A provider exports one component value:

```haskell
eventStoreMigrations :: Either DefinitionError MigrationComponent
eventStoreMigrations =
  migrationComponentFromEmbeddedSql
    "event-store"
    mempty
    $(embedMigrationManifest "migrations/manifest")
```

A dependent library declares only component-level dependencies:

```haskell
eventSourcingMigrations :: Either DefinitionError MigrationComponent
eventSourcingMigrations =
  migrationComponentFromEmbeddedSql
    "event-sourcing"
    (Set.singleton "event-store")
    $(embedMigrationManifest "migrations/manifest")
```

`migrationComponentFromEmbeddedSql` uses each manifest basename without the
`.sql` suffix as its `MigrationName`. Manual `sqlMigration` and
`migrationComponent` construction remains available for generated modules and
tests.

The final executable constructs the plan:

```haskell
migrationPlan
  :: NonEmpty MigrationComponent
  -> Either PlanError MigrationPlan
```

```haskell
ordersServiceMigrationPlan
  :: MigrationComponent
  -> MigrationComponent
  -> MigrationComponent
  -> MigrationComponent
  -> Either PlanError MigrationPlan
ordersServiceMigrationPlan eventStore eventSourcing queue ordersService =
  migrationPlan
    ( eventStore
        :| [ eventSourcing
           , queue
           , ordersService
           ]
    )
```

`migrationPlan` preserves the supplied order and rejects:

- duplicate component names;
- duplicate migration names within a component;
- missing dependencies;
- a component placed before one of its dependencies;
- dependency cycles.

An unrelated component may appear anywhere. The library must not impose an
arbitrary global order on unrelated components.

A separate optional function may perform a stable topological sort:

```haskell
resolveMigrationPlan
  :: NonEmpty MigrationComponent
  -> Either PlanError MigrationPlan
```

It preserves input order whenever dependencies do not constrain two components.
Automatic sorting is never performed by `migrationPlan`.

## 8. Dependency Semantics

For `event-sourcing` depending on `event-store`, the guarantee is:

> Before any pending `event-sourcing` migration runs, every migration supplied
> by the current `event-store` component is applied.

The runner executes components as blocks:

```text
all pending event-store migrations
then all pending event-sourcing migrations
```

It does not support:

```text
event-store/0001
event-sourcing/0001
event-store/0002
```

If that interleaving is required, the two sets are one migration component or
the package boundary is wrong.

Version compatibility between libraries is enforced by Cabal dependency bounds.
Version 1 does not express "component A at least migration N" in the migration
graph; it guarantees only that every migration supplied by the linked component
is applied before its dependent runs.

## 9. SQL Migrations

Pure SQL is the default. `sqlMigration` accepts exact UTF-8 bytes, validates the
name and leading directives, derives the transaction mode, and computes SHA-256
over the original bytes.

```haskell
sqlMigration
  :: Text
  -> ByteString
  -> Either DefinitionError Migration
```

SQL is transactional unless its leading comment section contains exactly:

```sql
-- pg-migrate: no-transaction

CREATE INDEX CONCURRENTLY orders_created_at_idx
  ON orders.orders (created_at);
```

Only the leading whitespace and comment section is inspected. The directive is
not recognized inside a string literal or after the first SQL token. Unknown
`pg-migrate` directives are definition errors rather than ignored comments.

The directive is part of the checksummed payload. Changing transaction mode
therefore changes the checksum.

### Transactional SQL

Transactional SQL and its ledger insert run in one
`Hasql.Transaction.Transaction`:

```text
BEGIN
  execute the complete SQL payload
  insert the Applied ledger row
COMMIT
```

The implementation uses `Hasql.Transaction.sql`, followed by the ledger
statement, and runs the transaction with:

```haskell
Hasql.Transaction.Sessions.transactionNoRetry
  Hasql.Transaction.Sessions.ReadCommitted
  Hasql.Transaction.Sessions.Write
```

No application-level transaction retry is performed.

Pure SQL migrations in either mode must not contain transaction-control statements such as
`BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, or prepared-transaction commands.
Those statements could escape or interfere with the transaction that makes the
ledger write atomic. Definition validation uses a PostgreSQL-aware lexical
scanner that understands quoted identifiers, standard and escape strings,
dollar-quoted bodies, line comments, nested block comments, and statement
boundaries. If it cannot classify a top-level statement safely, it rejects the
payload.

Version 1 does not support psql meta-commands or `COPY FROM STDIN` payload data.
They require protocols beyond executing an embedded SQL script.

### Nontransactional SQL

A nontransactional SQL migration must contain exactly one PostgreSQL statement.
It is executed as an unprepared Hasql `Statement () ()` through
`Hasql.Session.statement`, not `Hasql.Session.script`.

This restriction is required because PostgreSQL executes multiple statements in
one simple-query message inside an implicit transaction block. Hasql statements
use the extended query protocol and are strictly single-statement, so the server
rejects an accidental multi-statement payload.

Multiple nontransactional operations belong in separate migrations. More complex
session logic must use `sessionMigration`.

## 10. Haskell Migrations

Haskell migrations are a constrained escape hatch:

```haskell
transactionMigration
  :: Text
  -> MigrationChecksum
  -> Hasql.Transaction.Transaction ()
  -> Either DefinitionError Migration

sessionMigration
  :: Text
  -> MigrationChecksum
  -> Hasql.Session.Session ()
  -> Either DefinitionError Migration
```

`transactionMigration` has the same atomic ledger guarantee as transactional
SQL. `sessionMigration` uses the nontransactional state machine.

`Hasql.Transaction.condemn` can deliberately abort a transaction without
turning its result into a `SessionError`. After every transactional Haskell
migration, the runner verifies that the expected ledger row committed before it
reports success. A missing row is a structured `TransactionCondemned` error.

Haskell functions cannot be hashed from their runtime value. Their checksum is
therefore an explicit caller-supplied SHA-256 fingerprint. The component owner
must change that fingerprint whenever the migration behavior changes.

```haskell
migrationFingerprint :: ByteString -> MigrationChecksum
```

The helper hashes a stable caller-owned version tag; it does not pretend to hash
the function closure.

An arbitrary `IO` constructor is not included in v1. External effects cannot be
made atomic with a PostgreSQL ledger and would make retry and repair semantics
misleading.

## 11. Nontransactional State Machine

Nontransactional work cannot atomically combine execution with its ledger
update. The runner uses:

```haskell
data MigrationStatus
  = Running
  | Applied
  | Failed
  deriving stock (Generic, Eq, Ord, Show)
```

Execution is:

1. Commit a `Running` ledger row.
2. Execute the single SQL statement or `Session` action outside an explicit
   transaction.
3. Commit an update to `Applied` on success.
4. Attempt to commit `Failed` and the Hasql error on an observed failure.

A process crash or lost connection can leave `Running`. Failure reporting can
also fail, so `Running` is an expected durable state, not a transient
implementation detail.

An asynchronous exception rolls back transactional work. During
nontransactional work it may arrive after PostgreSQL has committed the statement
but before the runner records the outcome, so the durable result is `Running`.
Cleanup still releases the advisory lock; the next run requires repair rather
than guessing what committed.

The runner must stop on any pre-existing `Running` or `Failed` migration. It
must not guess whether an operation is idempotent. A failed concurrent index
build can leave an invalid index, so repair requires operator inspection.

## 12. Ledger

The default ledger is `pgmigrate.migrations`. `LedgerConfig` may change the
metadata schema and advisory lock key; table names inside that schema are fixed.
The schema is a validated PostgreSQL identifier and is always encoded through an
identifier-safe SQL builder, never interpolated from raw user input.

```haskell
data LedgerConfig = LedgerConfig
  { schema :: !PostgresIdentifier
  , lockKey :: !Int64
  }
  deriving stock (Generic, Eq, Show)
```

The public constructor is hidden. `defaultLedgerConfig` selects `pgmigrate`
and the project lock key; `ledgerConfig` validates an alternate schema and key.

```sql
CREATE SCHEMA IF NOT EXISTS pgmigrate;

CREATE TABLE pgmigrate.ledger_metadata
(
    singleton       boolean     PRIMARY KEY DEFAULT true CHECK (singleton),
    schema_version  integer     NOT NULL CHECK (schema_version > 0),
    updated_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    runner_version  text        NOT NULL
);

CREATE TABLE pgmigrate.migrations
(
    component          text        NOT NULL,
    migration          text        NOT NULL,
    position           integer     NOT NULL CHECK (position > 0),
    checksum           bytea       NOT NULL CHECK (octet_length(checksum) = 32),
    kind               text        NOT NULL CHECK (kind IN ('sql', 'haskell')),
    transaction_mode   text        NOT NULL
        CHECK (transaction_mode IN ('transactional', 'nontransactional')),
    status             text        NOT NULL
        CHECK (status IN ('running', 'applied', 'failed')),
    started_at         timestamptz NOT NULL,
    finished_at        timestamptz,
    execution_time_ms  bigint      CHECK (execution_time_ms >= 0),
    error              text,
    runner_version     text        NOT NULL,
    CHECK (transaction_mode = 'nontransactional' OR status = 'applied'),
    CHECK
    (
        (status = 'running' AND finished_at IS NULL AND error IS NULL)
        OR
        (status = 'applied' AND finished_at IS NOT NULL AND error IS NULL)
        OR
        (status = 'failed' AND finished_at IS NOT NULL AND error IS NOT NULL)
    ),
    PRIMARY KEY (component, migration),
    UNIQUE (component, position)
);

CREATE TABLE pgmigrate.history_imports
(
    component       text        NOT NULL,
    migration       text        NOT NULL,
    source          text        NOT NULL,
    source_evidence jsonb       NOT NULL,
    reason          text        NOT NULL,
    imported_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    imported_by     text        NOT NULL DEFAULT current_user,
    runner_version  text        NOT NULL,
    PRIMARY KEY (component, migration),
    FOREIGN KEY (component, migration)
        REFERENCES pgmigrate.migrations (component, migration)
);

CREATE TABLE pgmigrate.repairs
(
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    component       text        NOT NULL,
    migration       text        NOT NULL,
    operation       text        NOT NULL
        CHECK (operation IN ('mark-applied', 'retry')),
    old_status      text        NOT NULL,
    new_status      text        NOT NULL,
    reason          text        NOT NULL,
    repaired_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    repaired_by     text        NOT NULL DEFAULT current_user,
    runner_version  text        NOT NULL,
    FOREIGN KEY (component, migration)
        REFERENCES pgmigrate.migrations (component, migration)
);
```

The actual DDL is owned by versioned internal ledger migrations. Installations
that do not use history import still receive the small audit table so the ledger
schema has one deterministic version. The runner acquires the advisory lock
before initializing or upgrading the ledger.

A runner transactionally upgrades every older supported ledger version under
the lock. It refuses a ledger version newer than it understands. CI must test
upgrade from every ledger version released in the current major series; a
release may drop old upgrade paths only in a new major version with a documented
offline upgrade route.

The plan is compared with the ledger before any user migration executes. The
runner rejects:

- a checksum mismatch;
- an applied migration that is not in the expected component prefix;
- a known migration at a different position;
- a known migration whose kind or transaction mode changed;
- a `Running` or `Failed` row;
- an unknown database migration when strict verification is enabled.

Unknown rows may be tolerated for status and rolling application rollback under
an explicit policy, but `verify` is strict by default.

## 13. Checksums and Immutability

SQL checksums cover the exact original bytes, including comments, whitespace,
and directives. No normalization occurs.

When a checksum differs, all mutating commands stop and report both values.
Applied migrations must not be modified.

Version 1 does not provide `--update-checksum`. A generic checksum override
would erase evidence that the executable and database disagree. A future repair
facility may add an append-only audit table, an operator identity, and a required
reason before supporting that operation.

The database ledger makes a separate source checksum file unnecessary for new
components.

## 14. Locking and Connections

The runner takes one session-level PostgreSQL advisory lock for the entire plan:

```text
connection provider acquires dedicated connection
verify the PostgreSQL server version
acquire advisory lock
initialize or upgrade ledger
validate plan against ledger
run every pending component and migration
release advisory lock
connection provider releases connection
```

The runner rejects unsupported PostgreSQL major versions before initializing or
upgrading the ledger.

PostgreSQL advisory locks are local to a database. The default lock key is a
stable constant owned by `pg-migrate`; a custom ledger configuration includes a
custom lock key.

The same dedicated connection holds the lock and runs every Hasql session.
Reconnecting would release the session lock and is therefore a fatal run error.
The runner explicitly releases the advisory lock and restores every
session-level setting it changes before returning. The provider then releases
the connection rather than making it available for application traffic.

Options include:

```text
--lock-timeout DURATION
--no-wait
--statement-timeout DURATION
```

The lock timeout is implemented by polling `pg_try_advisory_lock`; it must not
silently change the connection-wide `lock_timeout` setting.

Service startup is not the primary migration mechanism. A deployment job or CI
step should invoke the service's migration command before normal replicas start.

## 15. Embedding and Source Layout

Each component has an ordered manifest:

```text
event-store/
  migrations/
    manifest
    0001-create-message-store.sql
    0002-add-stream-indexes.sql
```

The manifest contains one relative SQL filename per line in execution order:

```text
0001-create-message-store.sql
0002-add-stream-indexes.sql
```

Blank lines and comments are not supported in v1. This keeps the format
deterministic and makes every line meaningful.

`pg-migrate-embed` reads the manifest at compile time, registers the manifest
and every listed SQL file as Template Haskell dependent files, and emits the
embedded bytes. Changing the manifest therefore invalidates the embedding
module. The checker rejects missing files, duplicate entries, absolute paths,
parent-directory traversal, nested paths, non-`.sql` entries, and unlisted
`.sql` files.

```haskell
embedMigrationManifest
  :: FilePath
  -> Q Exp

migrationComponentFromEmbeddedSql
  :: Text
  -> Set Text
  -> NonEmpty (FilePath, ByteString)
  -> Either DefinitionError MigrationComponent
```

The embedding package also accepts manual
`NonEmpty (FilePath, ByteString)` input so tests and generated modules do not
depend on Template Haskell.

When every existing entry uses the conventional numeric prefix, the `new` helper
creates the next package-local zero-padded file and atomically appends it to the
manifest. Otherwise the caller supplies `--name`. It never applies a migration.

## 16. Public API

The initial top-level module is singular and follows the project name:

```haskell
module Database.PostgreSQL.Migrate
  ( ComponentName
  , componentName
  , MigrationName
  , migrationName
  , MigrationId
  , migrationId
  , MigrationChecksum
  , migrationFingerprint
  , MigrationComponent
  , migrationComponent
  , Migration
  , sqlMigration
  , transactionMigration
  , sessionMigration
  , MigrationPlan
  , migrationPlan
  , resolveMigrationPlan
  , LedgerConfig
  , defaultLedgerConfig
  , ledgerConfig
  , RunOptions
  , defaultRunOptions
  , withLedger
  , withLockWait
  , withStatementTimeout
  , withUnknownMigrationsPolicy
  , withEventHandler
  , MigrationEvent (..)
  , ConnectionProvider
  , connectionProvider
  , connectionProviderFromSettings
  , runMigrationPlan
  , runMigrationPlanWith
  , verifyMigrationPlan
  , migrationStatus
  , MigrationOutcome (..)
  , MigrationResult (..)
  , MigrationReport (..)
  , MigrationError
  )
```

`RunOptions` contains typed ledger, lock, timeout, unknown-history, and event
settings:

```haskell
data RunOptions = RunOptions
  { ledger :: !LedgerConfig
  , lockWait :: !LockWait
  , statementTimeout :: !(Maybe NominalDiffTime)
  , unknownMigrations :: !UnknownMigrationsPolicy
  , emit :: !(MigrationEvent -> IO ())
  }
```

The record shown is conceptual; the public type is opaque. The exported `with*`
functions above return updated options without exposing an invalid construction
path.

`defaultRunOptions` uses the default ledger, waits for the lock, performs no
automatic retries, treats unknown history strictly, and emits to a no-op
callback. The library never chooses a logging framework.

`MigrationEvent` covers lock waiting/acquisition, plan validation, migration
start/completion/failure, and plan completion. Events carry structured IDs and
timings rather than pre-rendered log lines. The callback is invoked only at
consistency boundaries: never between successful user work and its required
ledger write. A callback exception fails the run before the next mutation and is
handled under the same connection-cleanup rules as other exceptions.
`MigrationStarted` is emitted before a nontransactional `Running` row is written;
completion and failure events are emitted only after their durable ledger
transition. No callback runs inside a user migration transaction.

Successful execution returns stable report data:

```haskell
data MigrationOutcome
  = AlreadyApplied
  | AppliedNow
  deriving stock (Generic, Eq, Ord, Show)

data MigrationResult = MigrationResult
  { migration :: !MigrationId
  , outcome :: !MigrationOutcome
  , duration :: !(Maybe NominalDiffTime)
  }
  deriving stock (Generic, Eq, Show)

data MigrationReport = MigrationReport
  { startedAt :: !UTCTime
  , finishedAt :: !UTCTime
  , results :: !(NonEmpty MigrationResult)
  }
  deriving stock (Generic, Eq, Show)
```

Status and verification have separate report types and do not overload
`MigrationReport` with modes that did not execute.

Event, outcome, and report constructors are public because they are immutable
output values intended for integration and testing. Constructors for validated
inputs and runtime configuration remain hidden.

The safe primary runner owns connection acquisition and release:

```haskell
runMigrationPlan
  :: RunOptions
  -> Hasql.Connection.Settings.Settings
  -> MigrationPlan
  -> IO (Either MigrationError MigrationReport)
```

Advanced consumers provide bracketed acquisition without exposing a raw reusable
connection:

```haskell
data ConnectionProvider = ConnectionProvider
  { useDedicatedConnection
      :: !( forall a.
            (Hasql.Connection.Connection -> IO a)
            -> IO (Either Hasql.Errors.ConnectionError a)
          )
  }

runMigrationPlanWith
  :: RunOptions
  -> ConnectionProvider
  -> MigrationPlan
  -> IO (Either MigrationError MigrationReport)
```

`connectionProviderFromSettings` implements the normal Hasql acquire/release
bracket. `connectionProvider` constructs an advanced provider with the same
contract: it supplies a new connection for one callback and always releases it
afterward. Migration connections are never returned to an application pool
because user SQL may change arbitrary session state.

`MigrationError` preserves structured `Hasql.Errors.SessionError` information
where available. Rendering errors to `Text` happens at the CLI boundary, not in
the core runner.

## 17. CLI Integration

The library exports reusable `optparse-applicative` parsers. It does not require
every migration-owning package to ship a standalone executable.

`pg-migrate-cli` requires `optparse-applicative >= 0.19` so option and command
groups follow the project CLI conventions.

```haskell
migrationCommandParser
  :: MigrationPlan
  -> Parser MigrationCommand
```

Commands are grouped by operator intent:

```text
Inspection
  plan
  status
  verify
  list
  check

Execution
  up
  repair

Authoring
  new
```

Common options are grouped as Connection, Execution, and Output in `--help`.
Machine-readable commands support `--json`. Shell completions are derived from
the real parser tree.

The generic package cannot discover migrations embedded in arbitrary Haskell
packages. The normal integration remains:

```text
pg-migrate provides CLI machinery
the consumer executable supplies its MigrationPlan
```

Parsers do not read environment variables or acquire connections. The consumer
chooses configuration precedence and passes the parsed command plus Hasql
settings or a `ConnectionProvider` to the CLI handler. The CLI package may
provide an optional `--database-url` parser, but no environment variable is
mandatory.

`up` applies the complete plan in v1. Component and migration filters may limit
inspection output, but selective execution is deferred because it complicates
dependency closure and operational reasoning.

`verify` makes no database changes and exits unsuccessfully for pending required
migrations, checksum differences, invalid prefixes, failed or interrupted rows,
unsatisfied dependencies, or unknown rows under strict policy.

## 18. Repair

Version 1 exposes only the operations required to recover nontransactional
migrations:

```text
repair COMPONENT/MIGRATION --mark-applied --reason TEXT --confirm
repair COMPONENT/MIGRATION --retry --reason TEXT --confirm
```

`--mark-applied` is valid only for a `Running` or `Failed` nontransactional
migration after an operator verifies the database result. `--retry` returns the
`Running` or `Failed` row to `Running` and executes the action again only after
explicit confirmation.

Repair never bypasses a checksum mismatch and never modifies transactional
history. Every repair is written to an append-only audit table with the old and
new status, reason, database role, runner version, and timestamp.

## 19. History Import

Migration from an existing engine is a first-class feature, but remains layered
outside normal execution:

```text
source adapter reads and verifies legacy evidence
project mapping translates source evidence to pg-migrate identities
generic importer validates the target plan and records applied history
normal runner remains unaware of the source engine
```

The generic model is:

```haskell
newtype EvidenceKey = EvidenceKey
  { unEvidenceKey :: Text
  }
  deriving stock (Generic, Eq, Ord, Show)

data EvidenceStrength
  = LedgerOnly
  | SourceManifestVerified
  | SourceLedgerChecksumVerified
  | StateVerified
  deriving stock (Generic, Eq, Ord, Show)

data SourceTimestamp
  = AbsoluteTime !UTCTime
  | LocalTimeWithoutZone !LocalTime
  deriving stock (Generic, Eq, Ord, Show)

data ImportEvidence = ImportEvidence
  { identity :: !Text
  , appliedAt :: !(Maybe SourceTimestamp)
  , strength :: !EvidenceStrength
  , payloadChecksum :: !(Maybe MigrationChecksum)
  , details :: !Value
  }
  deriving stock (Generic, Eq, Show)

data EvidenceRequirement
  = Evidence !EvidenceKey
  | AllOf !(NonEmpty EvidenceRequirement)
  | AnyOf !(NonEmpty EvidenceRequirement)
  deriving stock (Generic, Eq, Show)

data PayloadRelation
  = SamePayload !EvidenceKey
  | EquivalentState
  deriving stock (Generic, Eq, Show)

data HistoryMapping = HistoryMapping
  { target :: !MigrationId
  , requirement :: !EvidenceRequirement
  , payload :: !PayloadRelation
  }
  deriving stock (Generic, Eq, Show)

data HistoryImport = HistoryImport
  { source :: !Text
  , evidence :: !(Map EvidenceKey ImportEvidence)
  , mappings :: !(NonEmpty HistoryMapping)
  , reason :: !Text
  }
  deriving stock (Generic, Eq, Show)
```

`ImportEvidence` contains a source identity, source timestamp when available,
adapter verification status, and SHA-256 of exact source bytes when available.
It never supplies a target checksum. The generic importer resolves checksums,
positions, kinds, and transaction modes from the current validated
`MigrationPlan`.

```haskell
importMigrationHistory
  :: ImportOptions
  -> ConnectionProvider
  -> MigrationPlan
  -> HistoryImport
  -> IO (Either HistoryImportError HistoryImportReport)
```

Import requires a maintenance window in which the predecessor runner is
disabled. A source-specific advisory lock is additional protection, not proof
that no uncoordinated legacy process can write.

The importer:

1. Acquires the normal `pg-migrate` advisory lock.
2. Validates all evidence and mappings before writing.
3. Requires imported targets to form a prefix of each affected component.
4. Rejects duplicate targets, unsatisfied or ambiguous requirements, conflicts
   with existing rows, and mappings to unknown target migrations.
5. Requires `SamePayload` evidence to equal the target checksum. An
   `EquivalentState` mapping requires satisfied `StateVerified` evidence and an
   explicit equivalent-history policy.
6. Inserts `Applied` rows using the current target metadata without executing
   user migration actions.
7. Writes source evidence, mapping, reason, database role, runner version, and
   timestamp to an append-only `pgmigrate.history_imports` audit table.
8. Commits the ledger and audit rows atomically.

`SamePayload` is valid only for a SQL target. Importing a Haskell migration
requires `EquivalentState`, because its explicit fingerprint is not a hash of an
executable payload.
The `SamePayload` key must also participate in the mapping's satisfied evidence
requirement; it cannot smuggle in unrelated bytes solely to match a target hash.

Imported ledger rows use the import time for `started_at` and `finished_at`.
Source timestamps are retained only as audit evidence so a timestamp without a
time zone is never misrepresented as an absolute execution time.

Imports are idempotent only when the existing ledger and audit rows match the
same source evidence and target metadata exactly. A different second import is a
conflict, not an update.

### Source adapters

Adapters are optional maintained packages:

```text
pg-migrate-import-codd
pg-migrate-import-hasql-migration
```

They depend on `pg-migrate`; the normal `pg-migrate` runner does not depend on
them. Each adapter exposes a library API and an
`optparse-applicative` command parser that a consumer can mount under an
`Import` command group. A generic standalone executable cannot discover the
consumer's embedded plan or project-specific mappings.

Adapters read legacy tables with Hasql and their own fixture-tested decoders.
They do not depend on the predecessor Haskell libraries.

Adapters never infer a component from a filename. The consumer supplies the
mapping and an explicit source-evidence selection. Every selected source entry
must participate in a satisfied mapping; unselected source rows are preserved
and reported. A strict-source option rejects any unselected rows, which is
appropriate when transforming a complete shared ledger in one operation.

### Codd adapter

The Codd adapter:

- reads `codd.sql_migrations` and legacy
  `codd_schema.sql_migrations` through Hasql;
- understands only documented ledger shapes that have integration fixtures;
- rejects rows with `no_txn_failed_at IS NOT NULL`;
- acquires the configured legacy runner lock before the `pg-migrate` lock;
- treats each successfully applied Codd filename as an evidence key;
- never writes to or drops a Codd schema.

The adapter defaults the legacy lock to the `codd-extras` key
`0x6B69726F6B754D67`, but keeps it configurable for consumers that used another
wrapper. Codd processes that do not honor that lock still require operational
quiescence.

Codd does not store a SQL checksum. When a repository has a Codd-era
`migrations.lock`, the adapter validates it against the source payload before
accepting `SourceManifestVerified` evidence and separately compares that payload
with the target plan checksum for `SamePayload` mappings. A manifest proves
repository integrity, not which bytes Codd historically executed, so Codd import
always requires an explicit confirmation policy. Without a manifest, the
evidence is `LedgerOnly`.

Mappings are checked-in data and may rename migrations cleanly:

```text
2026-05-16-12-17-14-kiroku-bootstrap.sql
  -> kiroku/0001-bootstrap
```

### `hasql-migration` adapter

The `hasql-migration` adapter reads `schema_migrations`, whose current shape is:

```text
filename text
checksum text
executed_at timestamp without time zone
```

The source table is supplied as a validated qualified identifier, defaulting to
`public.schema_migrations`; the adapter never relies on `search_path`.

The stored checksum is base64-encoded MD5 of the original migration bytes. For
direct evidence, the adapter must recompute that exact legacy checksum from the
mapped source payload and reject a mismatch before import. `pg-migrate` still
stores its own SHA-256 of the target payload in the new ledger.

The adapter then compares SHA-256 of the verified source payload with the target
checksum exposed by the plan description when the mapping declares
`SamePayload`. A match produces `SourceLedgerChecksumVerified` evidence.
Adapters receive exact legacy source payloads from the owning package; they do
not bypass opacity to extract executable actions from the target plan.

The adapter also rejects duplicate filenames. The legacy table has no primary or
unique constraint, so silently choosing one duplicate row would be unsafe.

Some libraries have more than one historical route to the same schema. A
mapping may therefore use `AllOf` and `AnyOf`, but equivalent history is not
accepted from ledger names alone. The owning library must provide a
domain-specific validator, executed in a Hasql transaction with `Mode = Read`,
and the operator must opt in to the equivalence rule.

## 20. Test Support

Production database integration uses Hasql only. A public test-support package
may depend on `ephemeral-pg` and provide:

```haskell
withMigratedDatabase
  :: MigrationPlan
  -> (Hasql.Connection.Connection -> IO a)
  -> IO (Either MigratedDatabaseError a)
```

`MigratedDatabaseError` distinguishes `ephemeral-pg` startup failure, Hasql
connection acquisition failure, and `pg-migrate` execution failure. The helper
uses `EphemeralPg.connectionSettings` directly rather than converting through a
libpq connection string. It releases the migration connection and acquires a
fresh connection for the test callback.

The initial acceptance suite includes:

1. Plan validation for duplicates, missing dependencies, invalid order, and
   cycles.
2. Prefix validation after append, removal, insertion, and reorder.
3. Exact-byte checksum mismatch detection.
4. Atomic rollback of transactional SQL and its ledger row.
5. Successful execution of `CREATE INDEX CONCURRENTLY` as a single
   nontransactional statement.
6. Rejection of multiple statements in a nontransactional SQL migration.
7. Crash injection leaving `Running` and observed failure leaving `Failed`.
8. Two concurrent runners applying each migration exactly once.
9. Lock timeout and no-wait behavior.
10. Generic history import prefix, conflict, idempotency, and audit behavior.
11. Codd import from legacy and current ledger fixtures, including rejection of
    a partially applied nontransactional migration.
12. `hasql-migration` import with valid and invalid legacy MD5 checksums.
13. Alternative-history import with a required domain validator.
14. Manifest checks and compile-time embedding.
15. JSON output contract tests for `plan`, `status`, `verify`, and import.

## 21. Package Structure

The project is named `pg-migrate`. Its packages keep library and microservice
dependency surfaces explicit:

```text
pg-migrate
  PgMigrate.Prelude
  Database.PostgreSQL.Migrate
  Database.PostgreSQL.Migrate.Types
  Database.PostgreSQL.Migrate.Plan
  Database.PostgreSQL.Migrate.Ledger
  Database.PostgreSQL.Migrate.Runner
  Database.PostgreSQL.Migrate.History

pg-migrate-embed
  Database.PostgreSQL.Migrate.Embed

pg-migrate-cli
  Database.PostgreSQL.Migrate.CLI

pg-migrate-import-codd
  Database.PostgreSQL.Migrate.History.Codd

pg-migrate-import-hasql-migration
  Database.PostgreSQL.Migrate.History.HasqlMigration

pg-migrate-test-support
  Database.PostgreSQL.Migrate.Test
```

`pg-migrate` contains the stable model, pure plan validation, ledger, Hasql
runner, and source-agnostic history importer. A migration-owning library
normally depends on `pg-migrate` and `pg-migrate-embed`. A microservice migration
executable additionally depends on `pg-migrate-cli`. Import adapters and test
support never enter the production runtime closure unless explicitly selected.

## 22. Rollout Sequence

1. Implement the pure model, manifest parser, and plan validation.
2. Implement the versioned ledger, locking, and transactional SQL runner.
3. Implement the nontransactional state machine and repair audit.
4. Implement CLI inspection and execution commands.
5. Implement the generic history importer and its audit table.
6. Implement and fixture-test the Codd and `hasql-migration` adapters.
7. Upgrade Kiroku, Keiro, and `pgmq-migration` as described below.
8. Import real database copies in staging and run strict `pg-migrate verify`.
9. Add one new native migration to each component and prove it applies exactly
   once on fresh and imported databases.
10. Cut production over in a maintenance window and disable the old runners.
11. Remove predecessor dependencies only after every deployed database passes
    strict `pg-migrate verify`.

## 23. Initial Library Upgrades

The first ecosystem migrations prove that the component and import APIs work for
libraries with different histories. They are consumers of the architecture, not
special cases in it.

### Kiroku

`kiroku-store-migrations` becomes the owner of component `kiroku` and exports:

```haskell
kirokuMigrations
  :: Either DefinitionError MigrationComponent
```

Its seven current timestamped files may be renamed to native component-local
names `0001-...` through `0007-...`. The ordered manifest records the new order,
and a checked-in Codd import mapping records every old filename to its new
`MigrationId`.

The package removes Codd settings, parsed migration actions, ledger detection,
expected-schema materialization, and runner functions from its primary library
API. Its migration executable is a thin `pg-migrate-cli` integration.

### Keiro

`keiro-migrations` becomes the owner of component `keiro` and exports:

```haskell
keiroMigrations
  :: Either DefinitionError MigrationComponent
```

The component declares `kiroku` as a dependency. Keiro does not re-embed Kiroku
files, wrap them in a second migration-set type, or own a combined ledger API.
Its sixteen current timestamped files may be renamed to `0001-...` through
`0016-...`, with the old-to-new Codd mapping checked in beside the manifest.

The final service composes concrete components:

```haskell
frameworkMigrationPlan
  :: MigrationComponent
  -> MigrationComponent
  -> Either PlanError MigrationPlan
frameworkMigrationPlan kiroku keiro =
  migrationPlan (kiroku :| [keiro])
```

The dependency declaration makes the plan fail if `kiroku` is absent or placed
after `keiro`.

### PGMQ

`pgmq-migration` becomes the owner of component `pgmq` and exports a native
component instead of `Hasql.Migration.MigrationCommand` values.

The current histories are not one-to-one:

```text
fresh install:
  pgmq_v1.11.0

incremental upgrade:
  pgmq_v1.10.0_to_v1.10.1
  pgmq_v1.10.1_to_v1.11.0
```

Both routes can establish a PGMQ 1.11 schema. The native component may use one
baseline migration, `0001-install-v1.11.0`, followed by normal append-only
upgrades. Its import rule accepts either the verified full-install evidence or
both verified upgrade entries:

```text
target pgmq/0001-install-v1.11.0 requires
  pgmq_v1.11.0
or
  all of:
    pgmq_v1.10.0_to_v1.10.1
    pgmq_v1.10.1_to_v1.11.0
    pgmq_schema_contract_v1.11
```

For the direct full-install route, the `hasql-migration` adapter verifies the
stored MD5 against the same source bytes. For the two-step route, the target
payload differs from the historical payloads, so `pgmq-migration` must provide a
read-only PGMQ 1.11 schema-contract validator that produces the third,
`StateVerified` evidence item. Names in `schema_migrations` are not sufficient
evidence of semantic equivalence by themselves.

### Snapshot checks during transition

Codd expected-schema checks are orthogonal to migration execution. Kiroku and
Keiro may temporarily retain their existing snapshot checks in test-only legacy
targets while their runtime libraries and executables move to `pg-migrate`.
Removing those targets requires either a replacement schema-contract test or an
explicit decision that migration, checksum, and focused integration tests are
the accepted drift controls. Snapshot behavior does not enter the
`pg-migrate` runner.

## 24. Central Design Rule

A library owns its migration component, its ordered manifest, and its dependency
declarations.

The final executable owns the migration plan, determines the order of unrelated
components, and controls when the plan runs.

`pg-migrate` validates and executes that plan without flattening independent
packages into one global migration namespace and without leaking the migration
engine's internal representation into consumer code.

## Validation Basis

This specification was checked against:

- `mori://shinzui/haskell-jitsurei/docs/core-standards`;
- `mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`;
- `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`;
- `mori://shinzui/haskell-jitsurei/docs/core-multiline-strings`;
- the locally registered Hasql 1.10+ and `hasql-transaction` source;
- the locally registered Codd source and the current `codd-extras` design;
- [PostgreSQL message-flow documentation](https://www.postgresql.org/docs/current/protocol-flow.html);
- [PostgreSQL advisory-lock documentation](https://www.postgresql.org/docs/current/explicit-locking.html#ADVISORY-LOCKS);
- [PostgreSQL `CREATE INDEX` documentation](https://www.postgresql.org/docs/current/sql-createindex.html);
- [PostgreSQL versioning policy](https://www.postgresql.org/support/versioning/).
