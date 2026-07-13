---
id: 22
slug: align-verification-policy-handling-and-remove-quadratic-ledger-scans
title: "Align verification policy handling and remove quadratic ledger scans"
kind: exec-plan
created_at: 2026-07-13T15:44:36Z
intention: intention_01kxe7gddde44r2d42xyh45c2c
master_plan: "docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md"
---

# Align verification policy handling and remove quadratic ledger scans

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

pg-migrate lets several applications share one ledger schema: `UnknownMigrationsPolicy`
(configured with `withUnknownMigrationsPolicy` on `RunOptions`) decides whether ledger rows
that are not part of the current application's plan are tolerated
(`AllowUnknownMigrations`) or fatal (`RejectUnknownMigrations`). The 2026-07-13 audit found
that the runner honors this policy but `repairMigration` and `importMigrationHistory`
hardcode `RejectUnknownMigrations` — so in a shared-ledger deployment where `up` works
fine, `repair` and `import` are inexplicably blocked by rows the operator deliberately
allowed. The same `RunOptions` value behaves differently depending on which entry point
receives it, and nothing documents that.

The audit also flagged two quadratic hot spots: after every transactional migration the
runner reloads the *entire* ledger just to confirm one row exists (the condemned-transaction
check), and the history importer rebuilds two `Map`s from scratch for every mapping it
classifies. Both are invisible at dozens of migrations and painful at thousands. Finally,
the audit raised a design question worth pinning down with tests and documentation: history
import validates that mapping targets form a gap-free prefix per component *considering only
the mappings themselves*, and treats a natively-applied row without an audit record as a
conflict — so once any migration in a component has been applied by the runner, earlier
history for that component can no longer be imported. That conservatism is likely correct,
but today it is neither tested nor documented, and the failure surfaces as a generic
`HistoryImportConflict`.

After this plan: one policy, honored consistently and documented; the condemned-transaction
check is a single-row lookup; import classification is linear; and the mixed native/import
semantics are pinned by tests and explained in the operations runbook.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-13T20:20:42Z) Milestone 1: repair and import honor `runUnknownMigrationsPolicy`; strict and allow-policy entry-point tests pass, policy docs are updated, all 110 unit tests pass, and all 28 PostgreSQL integration tests pass.
- [x] (2026-07-13T20:22:26Z) Milestone 2: a keyed `SELECT EXISTS` replaces each post-transaction full-ledger reload, importer maps are built once before classification, and all 110 unit plus 28 PostgreSQL integration tests pass.
- [ ] Milestone 3: mixed native/import prefix semantics pinned by integration tests and documented.
- [ ] Core changelog updated; `cabal test all` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The pure `comparePlanWithLedger` allow/reject behavior already had direct unit coverage in
  `Test.Ledger.testUnknownPolicy`; duplicating that assertion would not prove the audited
  call sites use the configured value. Evidence: the new integration tests fail against
  the former hardcoded policy and pass through `repairMigration` and
  `importMigrationHistory` after the two call-site changes.


## Decision Log

- Decision: Repair and history import honor the `UnknownMigrationsPolicy` carried by the
  `RunOptions` they already receive, exactly like the runner, instead of hardcoding
  `RejectUnknownMigrations`.
  Rationale: The policy modifier lives on `RunOptions`; a modifier that silently applies to
  some entry points and not others is a trap. Operators who want strict repair keep the
  default (`RejectUnknownMigrations` is the `defaultRunOptions` value), so safety is
  unchanged for anyone who has not opted in.
  Date: 2026-07-13

- Decision: Keep the conservative mixed-state import semantics (prefix computed over
  mappings only; native row without matching audit is a conflict) and document them, rather
  than teaching the prefix validator about already-applied rows.
  Rationale: Relaxing it would let an import silently "adopt" rows it has no evidence for;
  the correct workflow (import history first, run natively after) is achievable today and
  just needs to be stated. Revisit only if a real migration scenario cannot be expressed.
  Date: 2026-07-13

- Decision: Keep the existing pure unknown-policy unit test and add the new regressions at
  the repair and import entry points instead of adding duplicate snapshot-only tests.
  Rationale: The defect was not in `comparePlanWithLedger`; it was that two callers ignored
  `RunOptions`. PostgreSQL entry-point tests are the smallest tests that distinguish the
  fixed code from the former hardcoded behavior while still asserting the strict default.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All code is in the core package `pg-migrate/`. Key sites:

- Policy: `src/Database/PostgreSQL/Migrate/Repair.hs`, `repairVerified` (around line 85)
  calls `comparePlanWithLedger RejectUnknownMigrations …` — hardcoded.
  `src/Database/PostgreSQL/Migrate/History.hs`, `importAgainstSnapshot` (line ~117) does
  the same. The runner's equivalent, `runVerified` in
  `src/Database/PostgreSQL/Migrate/Runner.hs` (line ~204), correctly uses
  `runUnknownMigrationsPolicy options`. `comparePlanWithLedger` itself lives in
  `src/Database/PostgreSQL/Migrate/Ledger.hs` and, under `AllowUnknownMigrations`, reports
  unknown rows in the report's `unknownMigrations` list without generating issues.
  `RunOptions`, the policy type, and `runUnknownMigrationsPolicy` are in
  `src/Database/PostgreSQL/Migrate/Runner/Types.hs`; import options wrap `RunOptions` as
  `importRunOptions` (`src/Database/PostgreSQL/Migrate/History/Types.hs`, line ~142).
- Quadratic reload: `executeTransactional` in `Runner.hs` (line ~307) — after a successful
  transaction it calls `loadLedger` (which selects every row of the migrations table, see
  `loadStoredMigrationsStatement` in `src/Database/PostgreSQL/Migrate/Ledger/Sql.hs`) and
  scans for the one just-inserted row; absence means the transaction was condemned (rolled
  back via hasql-transaction's `condemn`) and yields `TransactionCondemned`.
- Quadratic maps: `classifyImport` in `History.hs` (lines ~161-177) builds `migrationsById`
  and `auditsById` in a `where` clause evaluated per resolved mapping; the call site is the
  `traverse (classifyImport history snapshot storedAudits) resolved` in
  `importAgainstSnapshot`.
- Mixed-state semantics: `validatePrefixes` and `firstMissingPrefixPosition` in
  `src/Database/PostgreSQL/Migrate/History/Validation.hs` (lines ~103-121);
  `classifyImport`'s conflict cases in `History.hs`.

Tests: unit in `pg-migrate/test/unit/` (`Test/Ledger.hs`, `Test/History.hs`,
`Test/Runner.hs`), integration in `pg-migrate/test/integration/Main.hs` (needs PostgreSQL:
`process-compose up` per `process-compose.yaml`). Relevant docs:
`docs/operations/history-import.md`, `docs/operations/nontransactional-repair.md`,
`docs/reference/public-api.md`.


## Plan of Work

Milestone 1 — policy alignment. In `Repair.hs` `repairVerified`, replace the hardcoded
`RejectUnknownMigrations` with `runUnknownMigrationsPolicy options` (the `RunOptions` are
already in scope). In `History.hs` `importAgainstSnapshot`, use
`runUnknownMigrationsPolicy (importRunOptions options)`. Audit the downstream logic for
policy-dependence: under `AllowUnknownMigrations`, `comparePlanWithLedger` yields no
unknown-row issues, so repair's `RepairBlockedByVerification` filter and import's
verification gate behave correctly without further change — verify this by test, not
assumption. Add unit tests (snapshot-level, no database needed, via
`Database.PostgreSQL.Migrate.Internal.comparePlanWithLedger` plumbing as existing tests do)
plus one integration case each: a ledger containing a foreign component's rows, options
with `AllowUnknownMigrations`, then (a) `repairMigration` on a failed nontransactional row
succeeds, and (b) `importMigrationHistory` succeeds; with the default options both still
fail. Document the cross-entry-point behavior in
`docs/operations/nontransactional-repair.md`, `docs/operations/history-import.md`, and the
`withUnknownMigrationsPolicy` haddock in `Runner/Types.hs`.

Milestone 2 — quadratic scans. Add a parameterized single-row statement to
`Ledger/Sql.hs`, e.g. `storedMigrationExistsStatement :: LedgerConfig -> Statement
MigrationId Bool` (`SELECT EXISTS (SELECT 1 FROM <schema>."migrations" WHERE component =
$1 AND migration = $2)`, following the module's existing encoder/decoder style). In
`executeTransactional`, replace the `loadLedger` reload-and-scan with one
`Session.statement` against the new statement; `False` still maps to
`TransactionCondemned`. In `History.hs`, hoist `migrationsById` and `auditsById` out of
`classifyImport` into `importAgainstSnapshot` (build once, pass as arguments). Both changes
are behavior-preserving: the existing integration tests that exercise condemned
transactions and import classification (conflict, already-imported, pending) are the
acceptance gate; run them before and after. No public API changes.

Milestone 3 — mixed-state semantics. Add integration cases to
`pg-migrate/test/integration/Main.hs` that pin today's behavior: (a) apply a component's
position 1 natively with `runMigrationPlan`, then attempt an import whose mappings cover
positions 1 and 2 — expect `HistoryImportConflict` for position 1 (native row, no audit);
(b) attempt an import mapping only position 2 — expect
`HistoryImportValidationFailed (HistoryComponentPrefixGap …)`; (c) the supported order —
import positions 1-2 into a fresh ledger, then `runMigrationPlan` applies position 3
natively — succeeds end-to-end. Then document, in `docs/operations/history-import.md`, the
rule these tests encode: history import must happen before any native application of the
same component, imports must cover a gap-free prefix of the component, and re-imports must
present byte-identical evidence, source, and reason to classify as `AlreadyImported`.
Update `pg-migrate/CHANGELOG.md` (policy behavior change for repair/import — flag it
prominently since it changes behavior only for operators who opted into
`AllowUnknownMigrations`).


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/pg-migrate`.

```bash
cabal build pg-migrate
just unit                                    # fast policy-logic feedback

# integration (requires PostgreSQL 17/18)
process-compose up --detached
cabal test pg-migrate:pg-migrate-integration

cabal test all
nix fmt
```

Expected new test fragments:

```text
pg-migrate-unit
  History
    repair honors AllowUnknownMigrations:             OK
    import honors AllowUnknownMigrations:             OK

pg-migrate-integration
  history import
    native-then-import conflicts on the native row:   OK
    suffix-only import reports a prefix gap:          OK
    import-then-native applies the remainder:         OK
```

Commit message shape:

```text
fix(runner): honor UnknownMigrationsPolicy in repair and history import

MasterPlan: docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md
ExecPlan: docs/plans/22-align-verification-policy-handling-and-remove-quadratic-ledger-scans.md
```


## Validation and Acceptance

Milestone 1 acceptance: with a ledger seeded with an unrelated component's applied rows and
`withUnknownMigrationsPolicy AllowUnknownMigrations`, `repairMigration` on a failed
nontransactional target returns `Right RepairReport {..}` and `importMigrationHistory`
returns `Right` — both currently return `Left …PlanVerificationFailed…` /
`RepairBlockedByVerification`, so write the failing tests first. With
`defaultRunOptions` (reject policy) both still fail exactly as before. Milestone 2
acceptance: all existing runner and import integration tests pass unchanged (the
condemned-transaction test in particular — it is the only consumer of the replaced reload),
and reading `Runner.hs` shows no `loadLedger` call inside `executeTransactional`.
Milestone 3 acceptance: the three pinned scenarios above pass and the runbook section
exists. Final: `cabal test all` green, `nix fmt` clean.


## Idempotence and Recovery

All database-touching tests run against disposable databases and re-run safely. The policy
change is deliberately small (two call sites); if the allow-policy integration tests reveal
a downstream assumption that unknown rows never coexist with repair/import (for example, an
audit-table foreign key or a classification edge), stop, record the evidence in Surprises &
Discoveries, and either fix the revealed site or — if the semantics turn out to be
load-bearing — revert Milestone 1, document the strictness as intended behavior in the
haddock and runbooks instead, and record the reversal in the Decision Log and the master
plan. Milestones 2 and 3 are independent of that outcome.


## Interfaces and Dependencies

No new dependencies; no public signature changes. Internal deltas:

```haskell
-- Database.PostgreSQL.Migrate.Ledger.Sql (other-module)
storedMigrationExistsStatement :: LedgerConfig -> Statement MigrationId Bool

-- Database.PostgreSQL.Migrate.History (internal call shape)
classifyImport ::
  HistoryImport ->
  Map MigrationId StoredMigration ->   -- hoisted, built once
  Map MigrationId StoredHistoryImport ->
  ResolvedHistoryMapping ->
  Either HistoryImportError ClassifiedImport
```

This plan shares the core package with
`docs/plans/21-harden-sql-validation-against-bom-misplaced-directives-and-wrong-diagnostics.md`
but touches disjoint modules (`Repair.hs`, `History.hs`, `Runner.hs`'s execute path,
`Ledger/Sql.hs` versus the scanner and option validation); only the
`pg-migrate/CHANGELOG.md` may conflict. It is otherwise independent of all other plans in
`docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md`.


Revision note (2026-07-13): Recorded completion of policy alignment after the existing
pure comparator coverage, 110 unit tests, and 28 real entry-point integration tests passed;
documented why the new regressions live at the audited callers.

Revision note (2026-07-13): Recorded the behavior-preserving removal of per-transaction
full-ledger reloads and per-mapping map reconstruction after the core unit and integration
suites passed, including the condemned-transaction and import conflict cases.
