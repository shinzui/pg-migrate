# Errors and events

Definition and plan errors are pure and occur before acquisition. Migration errors preserve
connection, session, server-version, lock, ledger initialization/verification, action,
nontransactional transition, callback, and cleanup distinctions. A cleanup failure after a
primary runner failure is `CleanupFailed primary issues`; the primary error is mandatory.
A cleanup failure after durable success does not replace that success: `MigrationReport`,
`RepairReport`, and `HistoryImportReport` carry the observed `cleanupIssues`. Repair and
history import add their own validation,
conflict, and audit-write errors. Source adapters keep catalog, duplicate, missing,
checksum, partial, strictness, source lock, and target-import failures distinct.

Events are observational and follow durable boundaries: lock wait started/acquired, plan
validated, migration started/completed/failure observed, and plan completed. Event handler
failure is returned with the primary migration error when applicable; callbacks never
decide database commit/rollback semantics.

Test-support callback exceptions are classified before they become structured failures.
Synchronous exceptions are returned as `MigratedDatabaseCallbackFailed` (with a simultaneous
release failure retained by `MigratedDatabaseCallbackAndCleanupFailed`); asynchronous
exceptions such as cancellation and `UserInterrupt` are rethrown after the connection is
released. A successful callback value wins if only release fails because the containing
ephemeral database is torn down immediately afterward.

Do not parse `Show` output as a machine protocol. Use constructors in Haskell and JSON v1
error types at CLI boundaries. Operators should retain the complete diagnostic and cleanup
issues, especially after nontransactional interruption.
