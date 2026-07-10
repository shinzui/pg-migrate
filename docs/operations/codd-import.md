# Codd import

The Codd adapter supports exact V1–V4 `codd_schema.sql_migrations` shapes and the exact V5
`codd.sql_migrations` shape. It rejects both schemas together, unknown columns, duplicate
filenames, missing selections, and partial/nontransactional failures. It never creates,
updates, renames, or drops Codd objects.

Quiesce every Codd process. Configure the cooperating legacy lock (default
`0x6B69726F6B754D67`) if wrappers used another key. The adapter acquires that source lock
before the target `pg-migrate` lock, but uncoordinated Codd processes still require a
maintenance window.

Codd stores no historical SQL checksum. A lowercase SHA-256 manifest plus caller-supplied
exact source bytes proves current repository integrity, not which bytes Codd executed.
Consequently every `SamePayload` mapping requires manifest verification and explicit
confirmation. Without a manifest, evidence is ledger-only and cannot satisfy the adapter's
same-payload policy. Use strict source when importing the complete shared ledger, record a
reason, retain audit output, and finish with strict target verification.
