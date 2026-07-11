# Staging migration inventory

This inventory is the non-secret gate for EP-15. Fill it only with opaque database and
snapshot identifiers; never store credentials, connection strings, customer names, or
customer data here. Every scenario must begin from a newly restored, operator-controlled
copy with the predecessor runner disabled.

## Required scenarios

| Scenario | Opaque database ID | Snapshot/backup reference | Copy created (UTC) | PostgreSQL major | Database role | Application/library version | Predecessor ledger | Expected components | Old runner disabled by | Restore proof | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Kiroku seven-row Codd history | REQUIRED | REQUIRED | REQUIRED | REQUIRED | REQUIRED | REQUIRED | 7 selected Codd rows; record deployed schema generation | `kiroku/0001..0008` | REQUIRED | REQUIRED | Awaiting operator input |
| Combined Keiro/Kiroku Codd history | REQUIRED | REQUIRED | REQUIRED | REQUIRED | REQUIRED | REQUIRED | 23 selected rows in one Codd ledger | `kiroku/0001..0008`, then `keiro/0001..0017` | REQUIRED | REQUIRED | Awaiting operator input |
| PGMQ direct full-install history | REQUIRED | REQUIRED | REQUIRED | REQUIRED | REQUIRED | REQUIRED | `pgmq_v1.11.0` | `pgmq/0001..0002` | REQUIRED | REQUIRED | Awaiting operator input |
| PGMQ two-step history | REQUIRED | REQUIRED | REQUIRED | REQUIRED | REQUIRED | REQUIRED | `pgmq_v1.10.0_to_v1.10.1`, `pgmq_v1.10.1_to_v1.11.0` | `pgmq/0001..0002` | REQUIRED | REQUIRED | Awaiting operator input |

Add rows for every other deployed predecessor shape. An unknown or unselected ledger row
is a no-go until its origin and disposition are reviewed.

## Restoration proof

For each row, record an approved restoration log or ticket reference and confirm:

- the copy was restored from the named artifact rather than repaired in place;
- the PostgreSQL major matches the source environment;
- source ledger row counts and checksums match the captured predecessor evidence;
- the old runner cannot start on the copy;
- application writes are quiesced for the import rehearsal;
- credentials and protected data remain outside this repository.

The operator signs the row by replacing `REQUIRED` fields and setting status to `Ready`.
Repository-local ephemeral databases are useful implementation evidence but do not satisfy
this restoration gate.
