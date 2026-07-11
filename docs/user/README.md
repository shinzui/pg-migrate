# User guide

This guide is for developers adding `pg-migrate` to a Haskell application or library.
Start with the [quickstart](quickstart.md) if you want to run a migration. Return to the
focused guides when you need to split migration ownership across packages, customize the
CLI, or add database tests.

## How pg-migrate fits into an application

`pg-migrate` does not discover SQL files at runtime and does not install a standalone
executable. Migration-owning libraries embed ordered SQL files into their binaries and
export `MigrationComponent` values. The final application puts those components in one
validated `MigrationPlan` and mounts the reusable CLI commands.

```text
library SQL + manifest ──> MigrationComponent ──┐
                                                ├──> MigrationPlan ──> service CLI ──> PostgreSQL
application SQL + manifest ─> MigrationComponent ┘
```

This ownership model gives a migration the stable identity
`component-name/migration-name`. Two libraries may both have a migration named
`0001-create-tables`; their component names keep those migrations distinct.

At runtime, the runner uses one dedicated Hasql connection and a PostgreSQL advisory lock
for the complete plan. It records applied migrations in the `pgmigrate` schema by default.
SQL bytes, order, transaction mode, and migration kind become durable history once a
migration is applied.

## Choose the packages you need

| Package | Add it when you need to |
| --- | --- |
| `pg-migrate` | define components, compose plans, inspect or run migrations |
| `pg-migrate-embed` | validate a manifest and embed SQL at compile time |
| `pg-migrate-cli` | mount the standard `plan`, `status`, `verify`, `up`, `repair`, `check`, `list`, and `new` commands |
| `pg-migrate-test-support` | migrate an ephemeral PostgreSQL instance in a test suite |
| `pg-migrate-import-codd` | import an existing Codd migration history |
| `pg-migrate-import-hasql-migration` | import an existing `hasql-migration` history |

A normal migration-owning library needs `pg-migrate` and `pg-migrate-embed`. The final
application usually adds `pg-migrate-cli`. Keep `pg-migrate-test-support` in test
dependencies and add an import adapter only during a predecessor cutover.

## Learning path

1. Complete the [quickstart](quickstart.md) to embed SQL, build a plan, mount the CLI, and
   apply the plan twice safely.
2. Read [manifest authoring](manifest-authoring.md) before creating or renaming migration
   files.
3. Read [component authoring](component-authoring.md) when a library owns migrations or a
   migration cannot be ordinary transactional SQL.
4. Read [plan composition](plan-composition.md) when the application combines components
   from several packages.
5. Use [CLI integration](cli-integration.md) to fit commands into the application's
   configuration, logging, JSON, and exit-code conventions.
6. Add the checks described in [testing](testing.md) before deploying.
7. Use [troubleshooting](troubleshooting.md) to interpret authoring, verification, lock,
   and nontransactional failures without bypassing safety checks.

The runnable [`examples/basic`](../../examples/basic) application demonstrates two
components with an explicit dependency. It is the best source to copy when starting a new
integration.

## Common tasks

| I want to… | Start here |
| --- | --- |
| add the first migration | [Quickstart](quickstart.md) |
| append a migration safely | [Manifest authoring: Create the next migration](manifest-authoring.md#create-the-next-migration) |
| make one component depend on another | [Plan composition: Dependencies and order](plan-composition.md#dependencies-and-order) |
| run SQL that PostgreSQL forbids in a transaction | [Component authoring: Nontransactional SQL](component-authoring.md#nontransactional-sql) |
| expose migration commands in a service executable | [CLI integration](cli-integration.md) |
| check migrations in CI without a database | [Testing: Fast checks](testing.md#fast-checks-without-postgresql) |
| test against a fresh PostgreSQL instance | [Testing: Ephemeral database tests](testing.md#ephemeral-database-tests) |
| understand a validation or runtime failure | [Troubleshooting](troubleshooting.md) |
| deploy or recover a failed migration | [Operations runbooks](../operations/deployment.md) |
| move from Codd or `hasql-migration` | [History import](../operations/history-import.md) |

## Safety rules to learn first

- Append migrations; do not edit, remove, insert before, or reorder an applied migration.
- Review `plan`, `status`, and `verify` before `up`, then run `verify` again afterward.
- Treat `verify` as a comparison of the declared plan with the ledger. It does not compare
  the live database schema with the SQL source.
- Run migrations as an explicit deployment or administrative job. Avoid making service
  startup the primary production migration path.
- Back up the database and understand restore procedures before production deployment or
  history import.
- Inspect the database before repairing an interrupted nontransactional migration. Never
  edit the ledger by hand.

For the precise supported API and version contracts, see the [public API](../reference/public-api.md),
[manifest v1](../reference/manifest-v1.md), [ledger v1](../reference/ledger-v1.md), and
[compatibility](../reference/compatibility.md) references.
