# CLI integration

`pg-migrate-cli` is a library, not a plan-discovering executable. The service owns the
embedded plan, configuration precedence, logging, stdout/stderr, and final exit code.

Mount `migrationCommandParser plan`, read the service's database URL, build a
`CliEnvironment`, call `runMigrationCommand`, and render the resulting immutable
`CliOutcome`. Commands are grouped by intent:

- inspect: `plan`, `list`, `check`, `status`, `verify`;
- execute: `up`, confirmed `repair`;
- author: `new`.

`up` deliberately has no selective component, count, or target filter: it applies the full
validated pending plan. Execution flags control lock waiting and statement timeout only.
Connection flags override application defaults only when explicitly present. Parser code
does not read environment variables.

Text is for operators. `--json` emits schema version 1 and stable command, success, data,
and error fields. Source adapters expose parsers that can be mounted under an
application-owned import group, and `renderHistoryImportJson` renders their generic import
report.
