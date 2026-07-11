# Staging rehearsal evidence: SCENARIO_ID / PASS_NUMBER

Copy this file to a non-secret name such as
`docs/rollout/evidence/pgmq-direct-pass-1.md`. Redact database settings, paths containing
sensitive identifiers, credentials, and data values. Link the matching row in
`docs/rollout/staging-inventory.md`.

## Identity

- Scenario: REQUIRED
- Pass: REQUIRED (`1` or `2`, each from a separately restored copy)
- Opaque database ID: REQUIRED
- Snapshot/backup reference: REQUIRED
- Restoration proof reference: REQUIRED
- Copy creation time (UTC): REQUIRED
- PostgreSQL server major: REQUIRED
- Database role: REQUIRED
- Application/library artifact versions: REQUIRED
- Migration binary digest/version: REQUIRED
- Operator/reviewer: REQUIRED

## Declared plan and predecessor evidence

- Component plan summary: REQUIRED
- Predecessor ledger table and shape: REQUIRED
- Selected rows and checksums: REQUIRED
- Unselected rows: REQUIRED (`none` is expected)
- Import mapping summary: REQUIRED
- Source inspection/dry-validation command: REQUIRED (redacted)
- Source inspection result hash: REQUIRED

## Rehearsal results

- Quiescence start/end: REQUIRED
- Import command and explicit reason: REQUIRED (redacted)
- Import report hash: REQUIRED
- Historical target actions not executed proof: REQUIRED
- Repeated import outcome: REQUIRED (`AlreadyImported` expected)
- Strict verify after import: REQUIRED
- Native `up` result: REQUIRED (only the component canary/canaries are `AppliedNow`)
- Observable canary state: REQUIRED
- Repeated `up` result: REQUIRED (`AlreadyApplied` expected)
- Strict verify after `up`: REQUIRED
- Behavior/schema tests: REQUIRED
- Total duration and lock wait/hold observations: REQUIRED

## Recovery and review

- Failure/recovery observations: REQUIRED (`none` if clean)
- Unknown rows or manual repairs: REQUIRED (`none` is required for go)
- Fresh-path comparison result: REQUIRED
- Reviewer decision: REQUIRED (`pass`, `repeat`, or `no-go`)
- Follow-up links: REQUIRED

Do not edit a failed record into a pass. Preserve it, fix the owning code or mapping, restore
a new copy, and create a new evidence file.
