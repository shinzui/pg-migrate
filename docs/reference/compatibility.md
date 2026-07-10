# Compatibility

| Surface | v1 support |
|---------|------------|
| GHC | 9.12.4 project toolchain |
| PostgreSQL | 17 and 18, each tested by the full acceptance matrix |
| Hasql | `>= 1.10 && < 1.11` |
| Ledger | schema version 1 |
| Manifest | format version 1 |
| JSON | schema version 1 |

PostgreSQL below 17 and stable majors newer than the tested maximum are rejected. A newer
stable major becomes supported only after its own release-blocking matrix job passes DDL,
protocol, transaction, lock, crash, repair, import, and adapter tests. Removing an
end-of-life major requires a compatibility-table update and at least one minor release of
advance notice.

Package public APIs follow the release policy. PostgreSQL patch releases within a supported
major are expected to remain compatible. Internal modules, test fixtures, and rendered
diagnostic prose are not stable APIs.
