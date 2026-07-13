# Locking and timeouts

Every execution, repair, and generic import uses the configured PostgreSQL session
advisory-lock key. `WaitIndefinitely` is the conservative default. Operators may request
no-wait or a positive bounded wait; unavailable and timed-out locks are distinct failures.
The runner restores `statement_timeout` and releases the lock on success, ordinary failure,
callback failure, and asynchronous interruption. If the operation already succeeded
durably, any release or restoration problem appears in the successful report's
`cleanupIssues`; do not turn that report into a failed deployment or discard it. If the
operation failed first, `CleanupFailed` contains both the primary `MigrationError` and the
non-empty cleanup issue list. Asynchronous interruption is rethrown only after cleanup has
been attempted.

A statement timeout bounds PostgreSQL statements; it does not make a nontransactional
operation atomic. Choose it from observed operation time plus deployment margin. A timeout
or lost connection during a nontransactional action may leave database effects present
while the ledger remains `Running`.

The Codd adapter first acquires its configurable cooperating legacy lock on a dedicated
source connection, then lets the generic importer acquire the target lock on a second
connection. Codd itself may not honor that wrapper lock, so predecessor quiescence and a
maintenance window are still mandatory.
