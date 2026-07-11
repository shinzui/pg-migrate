# Testing

Test migrations at three boundaries: validate definitions without PostgreSQL, apply the
complete composed plan to a fresh database, and exercise the application against the
migrated schema. A migration that merely parses is not proven to work on PostgreSQL.

## Fast checks without PostgreSQL

Compile every module that contains `embedMigrationManifest`. Compilation verifies the
manifest, ensures all sibling SQL files are listed, and embeds the exact bytes. Then
evaluate the application plan in a pure test so `migrationComponentFromEmbeddedSql`
validates SQL and the application constructs every component.

Also run the CLI manifest check explicitly in CI:

```console
cabal run my-service-migrate -- check migrations/accounts/manifest
cabal run my-service-migrate -- plan
cabal run my-service-migrate -- list
```

`check` validates manifest syntax, membership, and readability without connecting to a
database. It does not scan SQL transaction rules. `plan` and `list` operate on the
constructed embedded plan and catch SQL definition and application composition failures
during initialization. If the administrative
executable requires connection configuration before dispatch, supply a harmless configured
default for these local commands or expose a test that evaluates the plan directly.

Pure tests should also cover any custom construction logic:

```haskell
case applicationPlan of
  Left definitionError -> assertFailure (show definitionError)
  Right (Left planError) -> assertFailure (show planError)
  Right (Right _) -> pure ()
```

These checks are fast and useful, but they do not ask PostgreSQL to parse or execute the
DDL.

## Ephemeral database tests

Add `pg-migrate-test-support` only to the test suite, together with the Hasql packages used
by assertions:

```cabal
test-suite my-service-database-test
  type:             exitcode-stdio-1.0
  main-is:          Main.hs
  hs-source-dirs:   test
  default-language: GHC2024

  build-depends:
    base,
    hasql                 >=1.10 && <1.11,
    pg-migrate            >=1.0  && <1.1,
    pg-migrate-test-support >=1.0 && <1.1,
    tasty,
    tasty-hunit
```

`pg-migrate-test-support` depends on `ephemeral-pg`, which starts an isolated temporary
PostgreSQL server. It is intentionally absent from the production dependency closure.

Use `withMigratedDatabase` around an assertion:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Test
import Hasql.Connection qualified as Connection
import Hasql.Session qualified as Session
import Test.Tasty.HUnit

assertAccountSchema :: MigrationPlan -> Assertion
assertAccountSchema plan = do
  result <-
    withMigratedDatabase plan $ \connection ->
      Connection.use connection
        ( Session.script
            "INSERT INTO accounts (email) VALUES ('reader@example.com')"
        )
  case result of
    Right (Right ()) -> pure ()
    other -> assertFailure ("unexpected database result: " <> show other)
```

The helper performs this lifecycle:

1. start a fresh ephemeral PostgreSQL instance;
2. run the complete plan with a dedicated migration connection;
3. release that connection;
4. acquire a different Hasql connection for the callback;
5. run the assertion and bracket connection and server cleanup.

The fresh callback connection matters: it prevents tests from accidentally relying on
session state left behind by the runner.

`withMigratedDatabase` returns `Either MigratedDatabaseError value`. If the callback itself
returns an `Either`, as `Connection.use` does, the successful shape is nested. Pattern
match both layers so a Hasql session failure cannot be mistaken for a successful test.

## Choose the helper variant

Use the smallest variant that expresses the test:

```haskell
withMigratedDatabase
  :: MigrationPlan
  -> (Connection.Connection -> IO value)
  -> IO (Either MigratedDatabaseError value)

withMigratedDatabaseOptions
  :: RunOptions
  -> MigrationPlan
  -> (Connection.Connection -> IO value)
  -> IO (Either MigratedDatabaseError value)

withMigratedDatabaseConfig
  :: EphemeralPg.Config
  -> RunOptions
  -> MigrationPlan
  -> (Connection.Connection -> IO value)
  -> IO (Either MigratedDatabaseError value)
```

- `withMigratedDatabase` uses normal runner and ephemeral-server defaults.
- `withMigratedDatabaseOptions` is appropriate for a custom ledger schema, lock policy,
  statement timeout, unknown-migration policy, or event handler.
- `withMigratedDatabaseConfig` also customizes the ephemeral server, such as its executable
  paths or startup arguments.

The signatures above assume `Hasql.Connection` is imported as `Connection` and the
`ephemeral-pg` API as `EphemeralPg`.

## Diagnose structured failures

`MigratedDatabaseError` tells you which lifecycle stage failed:

| Constructor | Meaning |
| --- | --- |
| `MigratedDatabaseStartupFailed` | `initdb` or server startup failed |
| `MigratedDatabaseMigrationFailed` | plan verification or migration execution failed |
| `MigratedDatabaseCallbackAcquisitionFailed` | the fresh assertion connection could not be acquired |
| `MigratedDatabaseCallbackFailed` | the callback threw an exception |
| `MigratedDatabaseCallbackCleanupFailed` | releasing the callback connection failed |
| `MigratedDatabaseCallbackAndCleanupFailed` | both the callback and its cleanup failed |

A Hasql `Left` returned normally by the callback is the callback's result, not a thrown
exception, so inspect it explicitly. Preserve structured migration and Hasql errors in test
output instead of reducing them to a generic boolean.

## What to test

At minimum, apply the final application plan and assert behavior that depends on every
component. Useful coverage includes:

- a fresh database can apply the complete plan;
- constraints, indexes, functions, triggers, and extensions required by the application
  behave as expected;
- one component can use objects supplied by each declared dependency;
- applying the same plan again reports only `AlreadyApplied` results;
- strict verification succeeds after the fresh plan is applied;
- the application data-access layer works against the resulting schema;
- nontransactional migrations have an explicit operational test and repair rehearsal.

For migrations that transform existing data, a fresh empty database is insufficient. Add
an upgrade test that applies the old released plan, inserts representative old data, then
runs the new plan and asserts the transformed data and constraints. Keep historical SQL
immutable in the fixture; otherwise the test will not model a real upgrade.

## Shared PostgreSQL integration suites

A repository-wide integration suite may use an existing server from
`PG_CONNECTION_STRING` instead of starting one process per test. Give concurrent tests
unique ledger schemas and isolate application objects so they cannot observe each other.
Clean up with brackets and retain the original error if cleanup also fails.

In this repository:

```console
just unit
just acceptance
```

The acceptance aggregate covers the package family and production dependency closure.
Explicit Nix shells named `postgresql17` and `postgresql18` select the supported server
majors. Downstream applications should test every PostgreSQL major they claim to support,
not only the developer's local version.

## CI sequence

A practical pipeline runs increasingly expensive checks:

1. compile all migration-owning packages;
2. run manifest checks and pure plan-construction tests;
3. run ephemeral fresh-database and application schema tests;
4. run old-plan-to-new-plan upgrade tests for data migrations;
5. run the supported PostgreSQL version matrix;
6. build the same migration artifact that deployment will execute.

Before production rollout, supplement automated tests with the
[deployment](../operations/deployment.md),
[locking](../operations/locking-and-timeouts.md), and—when applicable—
[repair](../operations/nontransactional-repair.md) runbooks.
