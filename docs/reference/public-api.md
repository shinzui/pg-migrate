# Public API 1.0

The supported common facade is `Database.PostgreSQL.Migrate`. It exposes opaque validated
identifiers, migrations, components, plans, providers, run/import options, repair requests,
and evidence values through smart constructors and functional option updates. Immutable
status, verification, event, result, report, audit-outcome, and structured error values are
inspectable.

Primary operations are `migrationStatus`, `verifyMigrationPlan`, `runMigrationPlan`,
`repairMigration`, and `importMigrationHistory`, with provider-aware variants where
applicable. `ledgerSchemaVersion == 1` is the supported database contract.

Optional stable facades are:

- `Database.PostgreSQL.Migrate.Embed` (`manifestFormatVersion == 1`);
- `Database.PostgreSQL.Migrate.Embed.RecompilePlugin` (a GHC 9.12 build-time plugin loaded
  by embedding modules; application code does not call its `plugin` value);
- `Database.PostgreSQL.Migrate.CLI` (`jsonSchemaVersion == 1`);
- `Database.PostgreSQL.Migrate.History.Codd`;
- `Database.PostgreSQL.Migrate.History.HasqlMigration`;
- `Database.PostgreSQL.Migrate.Test`.

Modules named `Internal` are implementation surfaces for this package family. They are not
part of the semantic-versioning compatibility promise and applications must not import
them. Public constructors deliberately prevent invalid names, invalid SQL, invalid plans,
unconfirmed repairs, malformed evidence graphs, unsafe source identifiers, and arbitrary
connection reuse.

Runner operations hold one dedicated connection through their session lock and cleanup.
Transactional SQL plus ledger state is atomic. Nontransactional state is durable but may
remain ambiguous after interruption. History import writes target ledger and audit rows
atomically without executing target actions.

`withUnknownMigrationsPolicy` applies consistently to execution, repair, and history import.
The default rejects ledger rows outside the active plan; applications that intentionally
share a ledger may explicitly allow those rows without relaxing verification of rows owned
by the active plan.

The successful `MigrationReport`, `RepairReport`, and `HistoryImportReport` records expose
`cleanupIssues :: [CleanupIssue]`. An empty list means lock release and timeout restoration
completed normally. A non-empty list means the primary operation completed durably and the
caller must retain the report while investigating cleanup. `CleanupFailed` is reserved for
the failure-plus-cleanup case and always contains both a primary `MigrationError` and a
non-empty issue list.
