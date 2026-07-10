# History import runbook

History import records a verified legacy prefix without executing target actions. It is a
cutover operation, not normal migration execution.

1. Back up source and target and rehearse on a recent copy.
2. Disable the predecessor runner and establish a maintenance window.
3. Check in explicit source evidence selections and source-to-`MigrationId` mappings.
4. Run adapter read/strict validation and review every unselected row.
5. Choose `SamePayload` only with exact payload checksum evidence. Use
   `EquivalentState` only with a domain-specific read-only validator and explicit opt-in.
6. Supply a non-empty reason and any source-specific confirmation.
7. Import under the target advisory lock; retain the append-only audit JSON.
8. Run strict `verify`, then apply any new native append-only migration normally.

Mappings must form a prefix per affected component and cannot target unknown IDs. Duplicate,
missing, ambiguous, or conflicting evidence fails before writes. Target ledger and audit
rows commit atomically with current target metadata; action code is not run. An identical
second import is idempotent. Changed evidence is a conflict, never an update.
