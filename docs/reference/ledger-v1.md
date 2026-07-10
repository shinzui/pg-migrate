# Ledger schema v1

`ledgerSchemaVersion == 1`. The default schema is `pgmigrate`; callers may supply another
validated PostgreSQL identifier and advisory-lock key. Initialization is idempotent and
future schema versions are refused without mutation.

`ledger_metadata` is a singleton with positive `schema_version`, update time, and runner
version. `migrations` has primary key `(component, migration)` and unique
`(component, position)`. Its checksum is exactly 32 SHA-256 bytes; kind is `sql` or
`haskell`; transaction mode is `transactional` or `nontransactional`; status is `running`,
`applied`, or `failed`. Transactional rows can only be `applied`. State constraints require:

- running: no finish time and no error;
- applied: finish time and no error;
- failed: finish time and an error.

`history_imports` has one row per imported migration, references `migrations`, and records
source, JSONB evidence/mapping, non-empty reason, import time/role, and runner version.
`repairs` is append-only with an identity key, referenced migration, `mark-applied` or
`retry`, old/new statuses, reason, repair time/role, and runner version.

Normal compatibility is append-only ledger upgrade code. A binary refuses a database newer
than its supported version. Published v1 never asks operators to edit these tables or
downgrade them manually.
