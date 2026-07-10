# PostgreSQL v1 acceptance matrix

`just acceptance` is the release-blocking aggregate command. It builds every package,
runs every unit, golden, recompilation, live PostgreSQL, adapter, and ephemeral-database
suite, checks production dependency closures, and verifies that the active server is
PostgreSQL 17 or 18. CI runs the same command once for each explicit major.

| # | Acceptance group | Executable owner |
|---|------------------|------------------|
| 1 | Duplicate, missing-dependency, invalid-order, and cycle plan validation | `pg-migrate-unit` / `Test.Plan` |
| 2 | Append, removal, insertion, and reorder prefix validation | `pg-migrate-unit` / `Test.Ledger` |
| 3 | Exact-byte checksum mismatch detection | `pg-migrate-unit` / `Test.Definition`, `Test.Ledger` |
| 4 | Transactional SQL and ledger rollback | `pg-migrate-integration` / transactional rollback |
| 5 | Single `CREATE INDEX CONCURRENTLY` execution | `pg-migrate-integration` / nontransactional success |
| 6 | Multiple nontransactional statement rejection | `pg-migrate-unit` / `Test.Sql` |
| 7 | Crash leaves `Running`; observed failure leaves `Failed` | `pg-migrate-integration` / crash and failure cases |
| 8 | Two runners apply each effect once | `pg-migrate-integration` / concurrent runners |
| 9 | Lock no-wait and finite timeout | `pg-migrate-integration` / lock lifecycle |
| 10 | Generic import prefix, conflict, idempotency, and audit | `pg-migrate-unit` and `pg-migrate-integration` / history import |
| 11 | Codd legacy/current fixtures and partial rejection | `pg-migrate-import-codd-*` |
| 12 | Valid and invalid `hasql-migration` MD5 | `pg-migrate-import-hasql-migration-*` |
| 13 | Alternative history requires a domain validator | core and `hasql-migration` integration suites |
| 14 | Manifest validation and compile-time recompilation | `pg-migrate-embed-test`, `pg-migrate-embed-recompilation` |
| 15 | Versioned JSON contracts for plan, status, verify, execution, repair, and import audit evidence | `pg-migrate-cli-test` goldens plus both adapter integration audit assertions |

The production-closure check walks dependency edges from each library root in Cabal's
generated `plan.json`; unrelated project packages present elsewhere in the plan do not
count as dependencies. Set `CHECK_PRODUCTION_CLOSURE_EXTRA_FORBIDDEN=base` to exercise its
negative path: the command must fail, while the normal invocation must pass.
