# Codd import

The Codd adapter supports exact V1–V4 `codd_schema.sql_migrations` shapes and the exact V5
`codd.sql_migrations` shape. It rejects both schemas together, unknown columns, duplicate
filenames, missing selections, and partial/nontransactional failures. It never creates,
updates, renames, or drops Codd objects.

Quiesce every Codd process. Configure the cooperating legacy lock (default
`0x6B69726F6B754D67`) if wrappers used another key. The adapter acquires that source lock
before the target `pg-migrate` lock, but uncoordinated Codd processes still require a
maintenance window. `--source-lock-key` accepts signed 64-bit decimal or `0x` hexadecimal
values. Values outside the signed 64-bit range are rejected rather than wrapped to another
key.

Codd stores no historical SQL checksum. A lowercase SHA-256 manifest plus caller-supplied
exact source bytes proves current repository integrity, not which bytes Codd executed.
Consequently every `SamePayload` mapping requires manifest verification and explicit
confirmation. Without a manifest, evidence is ledger-only and cannot satisfy the adapter's
same-payload policy. `--strict-source` makes the selection and manifest agree exactly: it
rejects unselected ledger rows, selected rows missing from the manifest, and manifest
entries outside the selection. Without strict mode, a partial manifest is valid; selected
rows absent from it produce ledger-only evidence suitable for an `EquivalentState`
mapping, not `SamePayload`.

Alternative histories additionally require read-only `StateValidator` evidence and the
explicit `--allow-equivalent` opt-in. If the target import commits but releasing the Codd
source lock fails, the successful `HistoryImportReport` is retained and the source failure
is appended to `cleanupIssues` after any target cleanup observations. Record a reason,
retain the complete report as audit output, and finish with strict target verification.
