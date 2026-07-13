# hasql-migration import

Configure a validated qualified source table, defaulting to
`public.schema_migrations`; the adapter never relies on `search_path`. It accepts only the
`filename`, `checksum`, `executed_at` column sequence, reads deterministic local timestamps,
and rejects duplicate filenames because the predecessor table has no uniqueness constraint.

For every selected filename, supply the exact legacy payload bytes. The adapter recomputes
the predecessor's base64 MD5 and compares it with the stored value before creating
`SourceLedgerChecksumVerified` evidence. It separately records SHA-256 of those exact bytes;
the generic importer compares that SHA-256 with a SQL target for `SamePayload`. The local
`timestamp without time zone` remains explicitly unzoned in audit JSON. Each evidence
detail also records `source_table` using the adapter's quoted schema-qualified rendering,
so audits distinguish imports from different configured predecessor tables.

Alternative histories require evidence requirements naming all relevant legacy rows plus a
domain-specific `StateValidator`. The validator runs inside the target lock in a read-only
transaction, and the operator must enable equivalent history. Names and MD5 alone never
prove equivalent state. Quiesce the predecessor, use strict source for a complete cutover,
record a reason, retain audit output, and finish with strict verification.
