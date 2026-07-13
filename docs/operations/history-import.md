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

History import verifies the target plan with the `UnknownMigrationsPolicy` inside its
configured `RunOptions`, matching normal execution and repair. The default
`RejectUnknownMigrations` blocks an import when the ledger contains another application's
component. For an intentionally shared ledger, pass run options with
`AllowUnknownMigrations` through `withImportRunOptions`; unknown rows are retained and
reported without weakening mapping, evidence, prefix, or conflict validation.

## Order import before native application

For each affected component, import mappings must cover a gap-free prefix beginning at
position 1. Existing target rows do not fill gaps in the mapping set: mapping only position
2 fails with `HistoryComponentPrefixGap` even if position 1 already exists in the target
ledger.

Perform the history import before applying any migration from that component natively. A
natively applied row has no matching history-import audit record, so a later import that
targets it fails with `HistoryImportConflict` even when its migration metadata matches.
This prevents an import from silently adopting a target row without source evidence.

The supported sequence is to import the legacy prefix into a fresh target component, then
run the full plan normally. The runner reports the imported prefix as `AlreadyApplied` and
executes only later native migrations. Re-importing the same prefix is idempotent only when
the source, reason, resolved target metadata, and complete evidence JSON are identical; an
altered value is a conflict rather than an update.
