# Troubleshooting

Start with the structured error or verification issue instead of the rendered prose. In
Haskell, pattern match public constructors. At the CLI boundary, use `--json` and the
[JSON v1 schema](../reference/json-v1.md). `Show` output and human-readable text are
diagnostics, not machine protocols.

## The manifest fails during compilation

`embedMigrationManifest` reports `invalid pg-migrate manifest` when compile-time validation
fails. Run the same check directly for a shorter feedback loop:

```console
my-service-migrate check --manifest path/to/manifest
```

Common causes are an empty or blank line, a comment in the manifest, whitespace around a
filename, a missing listed file, an unlisted sibling `.sql` file, a nested path, or invalid
UTF-8. The manifest format is intentionally only an ordered filename list; move explanatory
comments into project documentation or the SQL files.

If Cabal does not rebuild after a migration edit, confirm that the component uses
`embedMigrationManifest` rather than a custom runtime reader and that the manifest and SQL
files are included in the package source distribution. The splice registers all listed
files as compiler dependencies.

## SQL validation rejects a file

Check the `SqlError` constructor:

- `EmptySql` means comments and whitespace were found but no SQL statement.
- `ProhibitedTransactionCommand` means the file contains a transaction boundary such as
  `BEGIN` or `COMMIT`; remove it because the runner owns the transaction.
- `PsqlMetaCommand` or `CopyFromStdin` means the payload relies on psql client behavior not
  provided by Hasql.
- `NonTransactionalStatementCount` means a file with the `no-transaction` directive does
  not contain exactly one statement.
- `UnknownDirective` or `DuplicateNoTransactionDirective` means the leading
  `pg-migrate:` comment is misspelled or repeated.
- `UnterminatedSqlConstruct` means a quoted string, identifier, dollar-quoted body, or
  block comment is incomplete.

For nontransactional syntax, use the exact leading directive:

```sql
-- pg-migrate: no-transaction
CREATE INDEX CONCURRENTLY example_idx ON example (id);
```

## Plan construction fails

Render or pattern match `DefinitionError` and `PlanError` before creating a CLI
environment. A missing dependency means the application did not include the concrete
component. A dependency placed after its consumer means the explicit `migrationPlan` order
is wrong. A cycle requires redesigning component ownership; changing to
`resolveMigrationPlan` cannot make a cycle valid.

Duplicate component names indicate an ownership conflict, not just a display-name clash.
Do not silently rename an already released component: its name is part of every durable
migration identity.

## `status` says pending on a new database

This is expected. Read-only inspection does not create the ledger. With no ledger rows,
the whole declared plan is pending. `up` initializes the ledger and applies the complete
plan.

`verify` is stricter than `status`: every pending migration is a verification issue. A new
artifact therefore normally fails strict verification before deployment with its reviewed
pending suffix, then succeeds after `up`.

## Verification reports a checksum mismatch

The stored SHA-256 checksum does not match the exact bytes now embedded for that migration.
Even changing whitespace or comments changes the checksum.

Determine which reviewed artifact applied the stored row and compare its source with the
current file. Restore the original applied bytes and append a new corrective migration.
Do not update the ledger checksum, delete the row, or add a bypass flag.

## Verification reports a position, kind, or mode mismatch

- A position mismatch usually means an applied migration was inserted, removed, or
  reordered within its component.
- A kind mismatch means SQL and Haskell implementations were exchanged under one identity.
- A transaction-mode mismatch means the `no-transaction` directive or constructor changed.

Restore the applied definition and append a new migration. These fields are durable
history, not mutable plan metadata.

## Verification reports an unknown stored migration

The database contains a migration identity absent from the current plan. Common causes are
deploying the wrong service artifact, removing a component, changing a component name, or
pointing at the wrong database or ledger schema.

Confirm the artifact, database, role, and configured `LedgerConfig`. `status` can use
`AllowUnknownMigrations` for diagnostic visibility, but strict verification and execution
still reject unknown history. Do not delete the unknown row to make the command pass.

## A migration is `Running` or `Failed`

Transactional migrations do not persist these states: their SQL and ledger state commit or
roll back together. A `Running` or `Failed` row identifies a nontransactional migration.

Stop automated retries. Inspect the intended database effect, PostgreSQL catalogs, server
logs, and deployment logs. A lost connection or timeout may have occurred after all, some,
or none of the effect. Then follow the
[nontransactional repair runbook](../operations/nontransactional-repair.md) to choose an
explicit confirmed `--mark-applied` or `--retry` with an audit reason.

Never infer safety from the ledger state alone.

## The advisory lock is unavailable or times out

Another migration, repair, or import using the same lock key may be active. Identify that
operation before retrying. Do not change the lock key merely to bypass a legitimate holder;
that would allow plans targeting the same ledger to run concurrently.

Use `--no-wait` for fail-fast automation or `--lock-timeout MILLISECONDS` for a bounded
wait. The default is to wait indefinitely. See
[locking and timeouts](../operations/locking-and-timeouts.md) for cleanup and statement
timeout behavior.

## PostgreSQL is rejected

`UnsupportedPostgresVersion` means the connected server major is outside the tested range.
Check that the command points to the intended instance, then consult the
[compatibility table](../reference/compatibility.md). Do not bypass the check: PostgreSQL
DDL, transaction, locking, and protocol behavior are part of the release acceptance
matrix.

## The CLI exits without enough context

Capture the complete output and rerun with `--json` where automation is involved. Preserve
the command name, release artifact, database identity, role, timestamps, and any cleanup
issues. `ExitVerificationFailed`, `ExitUsageFailed`, and `ExitExecutionFailed` deliberately
describe different classes of failure; map them to distinct application exit codes if your
deployment platform supports it.

For production incidents, continue with the relevant
[operations runbook](../operations/deployment.md) rather than editing ledger tables by
hand.
