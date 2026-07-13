# Quickstart

This walkthrough builds a small application-owned migration plan, exposes the standard
commands, applies one migration, and verifies the result. It uses the same structure as the
runnable [`examples/basic`](../../examples/basic) project.

## Prerequisites

You need the GHC toolchain used by your application, a supported PostgreSQL server, and a
database role that can create the application objects and the migration ledger. This
repository currently tests GHC 9.12.4 with PostgreSQL 17 and 18; see the
[compatibility table](../reference/compatibility.md) before adopting a different version.

In this repository, enter the complete development environment with:

```console
nix develop
```

## 1. Add the packages

Add the core model, manifest embedding, reusable CLI, Hasql, and the libraries used by the
example executable:

```cabal
executable my-service-migrate
  main-is:          Main.hs
  hs-source-dirs:   app
  other-modules:    Migrations
  default-language: GHC2024
  default-extensions:
    DuplicateRecordFields
    OverloadedStrings
    TemplateHaskell

  build-depends:
    aeson                 >=2.2  && <2.3,
    base                  >=4.20 && <4.22,
    bytestring            >=0.12 && <0.13,
    containers            >=0.7  && <0.8,
    hasql                 >=1.10 && <1.11,
    optparse-applicative  >=0.19 && <0.20,
    pg-migrate            >=1.0  && <1.1,
    pg-migrate-cli        >=1.0  && <1.1,
    pg-migrate-embed      >=1.0  && <1.1,
    text                  >=2.1  && <2.2
```

Also include the SQL and manifest in a source distribution. For a Cabal package, one
simple rule is:

```cabal
extra-source-files:
  migrations/*.sql
  migrations/manifest
```

If a library owns the component and the application only composes it, the library needs
`pg-migrate` and `pg-migrate-embed`; only the final CLI executable needs
`pg-migrate-cli`.

## 2. Create a manifest and SQL file

Create this layout relative to the package file:

```text
my-service/
├── app/
│   ├── Main.hs
│   └── Migrations.hs
├── migrations/
│   ├── 0001-create-accounts.sql
│   └── manifest
└── my-service.cabal
```

The manifest is an ordered list of filenames. Put this exact line in
`migrations/manifest`:

```text
0001-create-accounts.sql
```

Put the migration in `migrations/0001-create-accounts.sql`:

```sql
CREATE TABLE accounts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);
```

The order in the manifest is the migration order. `pg-migrate-embed` validates the
manifest and embeds the exact SQL bytes during compilation; the production executable
does not need the files at runtime.

## 3. Define the component and plan

Use Template Haskell to embed the manifest, then create one component and one plan:

```haskell
{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

module Migrations (applicationPlan) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Embed

applicationPlan :: Either DefinitionError (Either PlanError MigrationPlan)
applicationPlan = do
  accounts <-
    migrationComponentFromEmbeddedSql
      "accounts"
      Set.empty
      $(embedMigrationManifest "migrations/manifest")
  pure (migrationPlan (accounts :| []))
```

`accounts` is the stable component name. The migration file becomes migration name
`0001-create-accounts`, so the durable migration identity is
`accounts/0001-create-accounts`.

Both construction steps can fail deliberately:

- `DefinitionError` means a component name, migration name, or SQL payload is invalid.
- `PlanError` means the components cannot form a valid dependency-ordered plan.

Resolve those errors once when starting the administrative executable, before connecting
to PostgreSQL. The complete [`examples/basic/app/Main.hs`](../../examples/basic/app/Main.hs)
shows this handling and is safe to copy.

## 4. Mount the CLI

The application owns database configuration, output streams, logging, and process exit.
The reusable package owns parsing, dispatch, reports, and rendering. A complete minimal
`Main.hs` is:

```haskell
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI
import Hasql.Connection.Settings qualified as Settings
import Migrations (applicationPlan)
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit qualified as System.Exit

main :: IO ()
main = do
  plan <-
    case applicationPlan of
      Left definitionError -> fail (show definitionError)
      Right (Left planError) -> fail (show planError)
      Right (Right validPlan) -> pure validPlan
  parsedCommand <-
    execParser
      ( info
          (migrationCommandParser plan <**> helper)
          (fullDesc <> progDesc "Manage service migrations")
      )
  databaseUrl <-
    lookupEnv "DATABASE_URL"
      >>= maybe (fail "DATABASE_URL is required") pure
  let environment =
        cliEnvironment
          (Settings.connectionString (Text.pack databaseUrl))
          plan
          defaultRunOptions
  outcome <- runMigrationCommand environment parsedCommand
  case commandOutputFormat parsedCommand of
    TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
    JsonOutput ->
      LazyByteString.putStrLn
        (Aeson.encode (renderMigrationCommandJson outcome))
  System.Exit.exitWith
    ( case exitClass outcome of
        ExitSucceeded -> System.Exit.ExitSuccess
        _ -> System.Exit.ExitFailure 1
    )

commandOutputFormat :: MigrationCommand -> OutputFormat
commandOutputFormat parsedCommand =
  case parsedCommand of
    Plan PlanOptions {output = OutputOptions format} -> format
    List ListOptions {output = OutputOptions format} -> format
    Check CheckOptions {output = OutputOptions format} -> format
    Status StatusOptions {output = OutputOptions format} -> format
    Verify VerifyOptions {output = OutputOptions format} -> format
    Up UpOptions {output = OutputOptions format} -> format
    Repair RepairOptions {output = OutputOptions format} -> format
    New NewOptions {output = OutputOptions format} -> format
```

This minimal version maps every failure to exit code 1. See
[CLI integration](cli-integration.md) for a complete command map, configuration precedence,
and a distinct exit-code mapping for verification, usage, and execution failures.

## 5. Build and inspect locally

Build the executable. Template Haskell reports invalid manifest syntax, missing files, or
unlisted sibling SQL files during this step:

```console
cabal build my-service-migrate
```

Inspect the embedded plan without changing a database. Constructing the plan also validates
the SQL payloads and reports a `DefinitionError` before command dispatch:

```console
DATABASE_URL="$PG_CONNECTION_STRING" cabal run my-service-migrate -- plan
DATABASE_URL="$PG_CONNECTION_STRING" cabal run my-service-migrate -- list
DATABASE_URL="$PG_CONNECTION_STRING" cabal run my-service-migrate -- check --manifest migrations/manifest
```

`plan` shows component order and dependencies. `list` shows migration identity, position,
kind, transaction mode, and checksum. `check` revalidates a manifest from the filesystem;
it is useful in authoring and CI workflows.

The sample executable reads `DATABASE_URL` before dispatching every command even though
these three commands do not access the database. An application may instead provide its
normal default connection settings and only require external configuration for the
database-backed commands.

## 6. Apply and verify

Run `status` first to see the pending migration, then apply the complete plan:

```console
DATABASE_URL="$PG_CONNECTION_STRING" cabal run my-service-migrate -- status
DATABASE_URL="$PG_CONNECTION_STRING" cabal run my-service-migrate -- up
DATABASE_URL="$PG_CONNECTION_STRING" cabal run my-service-migrate -- verify
```

`up` initializes the default `pgmigrate` ledger schema, acquires the plan's advisory lock,
verifies durable history, and applies every pending migration in order. Transactional SQL
and its ledger row commit atomically.

Run `up` a second time:

```console
DATABASE_URL="$PG_CONNECTION_STRING" cabal run my-service-migrate -- up
```

The first report marks the migration `AppliedNow`; the second marks it `AlreadyApplied`.
This idempotence makes rerunning the same reviewed artifact safe.

`verify` succeeds when the database ledger is a valid applied prefix of the declared plan
and all stored positions, checksums, kinds, and transaction modes match. Pending
migrations make strict verification fail. `verify` does not compare live tables, indexes,
or other schema objects with the SQL source.

## 7. Append the next migration

Create and append a file through the mounted authoring command:

```console
DATABASE_URL="$PG_CONNECTION_STRING" cabal run my-service-migrate -- \
  new \
  --manifest migrations/manifest \
  --description "Add account status"
```

With the numeric manifest above, this creates `0002.sql` exclusively and appends it to
the manifest atomically. To choose a descriptive basename, include
`--name 0002-add-account-status` in the `new` command before the file is created. Add SQL
to the new file, rebuild, review `plan` and `check`, and run the normal deployment sequence
again.

Do not edit the already applied `0001-create-accounts.sql`. Exact-byte changes alter its
SHA-256 checksum and cause verification to fail. The normal evolution path is always to
append a new migration.

## Production handoff

Use the migration executable as an explicit pre-deployment or administrative job. Before
the first production run, read the [deployment runbook](../operations/deployment.md) and
the [locking and timeout guide](../operations/locking-and-timeouts.md). If the plan
contains nontransactional SQL, also read the
[repair runbook](../operations/nontransactional-repair.md) before deployment.

Next, read [manifest authoring](manifest-authoring.md) for filename and SQL validation
rules, then [component authoring](component-authoring.md) and
[plan composition](plan-composition.md) as your application grows.
