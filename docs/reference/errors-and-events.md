# Errors and events

Definition and plan errors are pure and occur before acquisition. Migration errors preserve
connection, session, server-version, lock, ledger initialization/verification, action,
nontransactional transition, callback, and cleanup distinctions. Cleanup failure retains
the primary failure when one exists. Repair and history import add their own validation,
conflict, and audit-write errors. Source adapters keep catalog, duplicate, missing,
checksum, partial, strictness, source lock, and target-import failures distinct.

Events are observational and follow durable boundaries: lock wait started/acquired, plan
validated, migration started/completed/failure observed, and plan completed. Event handler
failure is returned with the primary migration error when applicable; callbacks never
decide database commit/rollback semantics.

Do not parse `Show` output as a machine protocol. Use constructors in Haskell and JSON v1
error types at CLI boundaries. Operators should retain the complete diagnostic and cleanup
issues, especially after nontransactional interruption.
