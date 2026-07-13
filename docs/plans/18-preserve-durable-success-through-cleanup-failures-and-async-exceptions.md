---
id: 18
slug: preserve-durable-success-through-cleanup-failures-and-async-exceptions
title: "Preserve durable success through cleanup failures and async exceptions"
kind: exec-plan
created_at: 2026-07-13T15:44:36Z
intention: intention_01kxe7gddde44r2d42xyh45c2c
master_plan: "docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md"
---

# Preserve durable success through cleanup failures and async exceptions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

pg-migrate's runner brackets every operation (run, repair, history import) in a lifecycle:
set a temporary PostgreSQL statement timeout, acquire a session advisory lock, do the work,
release the lock, restore the timeout. Before this plan, if the work succeeded — every
migration committed durably — but a cleanup step then fails (the unlock statement errors
because the connection dropped, or the timeout restore fails), the entire operation returns
`Left (CleanupFailed Nothing …)` and the successful `MigrationReport` is discarded. An
operator cannot tell from the result that their migrations actually applied. The
2026-07-13 audit flagged this in the core runner
(`pg-migrate/src/Database/PostgreSQL/Migrate/Runner.hs`, `attachCleanup`) and found the
same pattern independently in `pg-migrate-test-support` (a successful test callback's value
is replaced by `MigratedDatabaseCallbackCleanupFailed` when only the connection release
fails). The test-support package has a second, related defect: it catches `SomeException`
around the user callback, so asynchronous exceptions (Ctrl-C, tasty timeouts) are swallowed
into an ordinary `Left` instead of propagating, defeating cancellation.

Now a caller of `runMigrationPlan`, `repairMigration`, or
`importMigrationHistory` always receives the durable outcome: success reports carry any
cleanup issues as data instead of being replaced by an error, `CleanupFailed` always
carries the primary error (its `Maybe` becomes mandatory), the CLI renders the new shape,
and test-support rethrows async exceptions and preserves callback results. The
documentation contract in `docs/reference/errors-and-events.md` now distinguishes cleanup
after durable success from cleanup after a primary failure.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-13T18:26:56Z) Milestone 1: core lifecycle returns cleanup issues as data; reports gain `cleanupIssues`; `CleanupFailed` reshaped; 103 unit and 26 integration tests pass.
- [x] (2026-07-13T18:29:04Z) Milestone 2: CLI JSON/text rendering, goldens, and `docs/reference/json-v1.md` updated; 43 unit/golden and 3 integration tests pass.
- [x] (2026-07-13T18:30:29Z) Milestone 3: test-support rethrows async exceptions, preserves callback values, closes the unmasked acquire window; all 5 tests pass.
- [x] (2026-07-13T18:36:22Z) Docs, public Haddocks, and three package changelogs updated; `nix fmt`, `cabal test all`, production-closure validation, and `just acceptance` pass across all 15 test groups on PostgreSQL 17.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Report types previously derived `Eq`, while the original plan described `CleanupIssue`
  as deliberately Eq-free. Hasql 1.10's `SessionError` does derive `Eq`, so deriving `Eq`
  for `CleanupIssue` preserves the reports' existing `Eq` API instead of removing useful
  instances. Evidence: the first `cabal build pg-migrate` failed at `MigrationReport`'s
  derived `Eq`; `Hasql.Engine.Errors.SessionError` in the mori-resolved Hasql source derives
  `Show, Eq`.

- A fake `ConnectionProvider` cannot exercise `withRunLifecycle` without a real Hasql
  connection because the lifecycle first queries the server version and applies session
  resources. The planned fake-provider unit test was therefore replaced by a PostgreSQL
  integration test that releases the actual advisory lock from a committed migration.
  Evidence: `unlock failure preserves the migration report` passes and observes
  `[AdvisoryUnlockReturnedFalse]` while the ledger row remains `Applied`.


## Decision Log

- Decision: Cleanup issues after a successful operation travel inside the success report
  (a new `cleanupIssues :: [CleanupIssue]` field on `MigrationReport`, `RepairReport`, and
  `HistoryImportReport`) rather than in a new error constructor or a widened return type.
  Rationale: `MigrationError` cannot carry the polymorphic `value` that
  `withRunLifecycle` threads, and changing every public signature to a triple would be far
  more invasive; a report field keeps `Either error report` signatures stable and makes the
  issues impossible to lose.
  Date: 2026-07-13

- Decision: `CleanupFailed !(Maybe MigrationError) !(NonEmpty CleanupIssue)` becomes
  `CleanupFailed !MigrationError !(NonEmpty CleanupIssue)`.
  Rationale: After Milestone 1 the success-with-cleanup-issues case never constructs
  `CleanupFailed`, so the `Nothing` case is unrepresentable and should be removed from the
  type (pre-release breaking change, recorded in the changelog).
  Date: 2026-07-13

- Decision: In test-support, a connection-release failure after a successful callback is
  discarded (the callback value wins) rather than reported.
  Rationale: The connection belongs to an ephemeral database that `ephemeral-pg` tears down
  wholesale; failing a green test over an unreleasable connection inverts the tool's
  purpose. Recorded in the haddock so the trade-off is visible.
  Date: 2026-07-13

- Decision: Derive `Eq` for `CleanupIssue` so adding cleanup observations does not remove
  the existing `Eq` instances from `MigrationReport`, `RepairReport`, and
  `HistoryImportReport`.
  Rationale: Every `CleanupIssue` payload is equality-comparable in the pinned Hasql 1.10
  API, and preserving report equality is less disruptive than silently dropping three
  public instances.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-2 is complete. Migration, repair, and history-import success reports now retain ordered
cleanup observations; a real integration scenario proves an advisory-unlock failure no
longer erases a durably committed `MigrationReport`. `CleanupFailed` has a mandatory
primary error, and the CLI exposes cleanup observations in both text and additive JSON v1
fields. Test-support closes the callback-connection acquisition window, lets a successful
callback value win over release failure, and propagates `UserInterrupt` after cleanup.

The final verification passed all 15 workspace test groups, including 103 core unit tests,
26 core PostgreSQL integration tests, 43 CLI unit/golden tests, 3 CLI integration tests,
and 5 test-support tests. `just acceptance` also passed the production dependency-closure
check on PostgreSQL 17. The implementation kept the JSON schema and ledger schema at v1;
the Haskell constructor changes are documented as PVP-major changes for the eventual
`1.1.0.0` package releases.


## Context and Orientation

The core runner lives in `pg-migrate/src/Database/PostgreSQL/Migrate/Runner.hs`. The
lifecycle is: `runMigrationPlanWith` → `withRunLifecycle` → `runOnConnection`, which nests
`withStatementTimeoutResource` (applies/restores the PostgreSQL `statement_timeout`
setting) around `withAdvisoryLockResource` (acquires/releases a session advisory lock via
`pg_try_advisory_lock`/`pg_advisory_unlock`, statements in
`pg-migrate/src/Database/PostgreSQL/Migrate/Runner/Lock.hs`). Both resource brackets run
the inner action under `Control.Exception.try @SomeException`, perform cleanup (which
returns `Either CleanupIssue ()`), and return the primary result paired with ordered cleanup
issues. `attachCleanup` now wraps only a `Left` primary error; a `Right` report receives the
issues in its `cleanupIssues` field. Asynchronous exceptions are rethrown only after both
resource cleanups have run.

The relevant types are in `pg-migrate/src/Database/PostgreSQL/Migrate/Runner/Types.hs`:
`CleanupIssue` (constructors `AdvisoryUnlockReturnedFalse`, `AdvisoryUnlockFailed`,
`StatementTimeoutRestoreFailed`), `MigrationError` (including `CleanupFailed
!MigrationError !(NonEmpty CleanupIssue)`), and `MigrationReport { startedAt, finishedAt,
results, cleanupIssues }`. `RepairReport` is in
`pg-migrate/src/Database/PostgreSQL/Migrate/Repair/Types.hs`; `HistoryImportReport` is in
`pg-migrate/src/Database/PostgreSQL/Migrate/History/Types.hs`. Repair and history import
reuse the same lifecycle via `withRunLifecycle` (see `repairMigration` in
`pg-migrate/src/Database/PostgreSQL/Migrate/Repair.hs` and `importMigrationHistory` in
`pg-migrate/src/Database/PostgreSQL/Migrate/History.hs`); for them the lifecycle's `value`
type is itself an `Either <domain error> <report>`, which is why the fix must happen where
the cleanup issues are known (the lifecycle) but be attached where the report type is known
(each entry point).

The CLI renders `MigrationError` and reports as JSON and text in
`pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI/Json.hs` and `.../CLI/Text.hs`, with
golden files under `pg-migrate-cli/test/golden/json` and the contract documented in
`docs/reference/json-v1.md`. `CleanupFailed` and each `CleanupIssue` constructor already
have renderings there that must follow the type change, and the report payloads gain a
`cleanup_issues` array (additive JSON change; schema version stays 1 per the versioning
rules in `docs/reference/release-policy.md`).

Test-support is one module, `pg-migrate-test-support/src/Database/PostgreSQL/Migrate/Test.hs`.
`withMigratedDatabase` starts an ephemeral PostgreSQL (`ephemeral-pg`), runs the plan,
acquires a Hasql callback connection inside `Exception.mask`, runs the callback under
`restore`, releases the connection while masked, and then classifies the result. A caught
`SomeAsyncException` is rethrown; a synchronous callback exception remains structured, and
a successful callback value wins when only release fails.

Integration tests for the core runner live in `pg-migrate/test/integration/Main.hs` (needs
PostgreSQL; `process-compose up` or `cabal test all` in a prepared environment; see
`process-compose.yaml`). Unit tests: `pg-migrate/test/unit/Test/Runner.hs`,
`pg-migrate-test-support/test/Main.hs`.


## Plan of Work

Milestone 1 — core. Change the two resource brackets so cleanup issues are returned as
data instead of being folded into the result: give `finishResource` (and the brackets) the
type `IO (Either SomeException (Either MigrationError value)) -> [Either CleanupIssue ()]
-> IO (Either MigrationError value, [CleanupIssue])` (or introduce a tiny internal record;
keep it local to `Runner.hs`). `runOnConnection` concatenates issues from both brackets and
`withRunLifecycle` returns them to its caller: change `withRunLifecycle` to
`RunOptions -> ConnectionProvider -> (Connection -> IO (Either MigrationError value)) ->
IO (Either MigrationError value, [CleanupIssue])`. Each public entry point then attaches:
`runMigrationPlanWith` puts issues into the new `cleanupIssues` field of `MigrationReport`
on success, or wraps `CleanupFailed primary issues` on failure; `repairMigration` and
`importMigrationHistory` do the same for `RepairReport`/`HistoryImportReport` and their
error types (both already wrap `MigrationError` via `RepairRunnerError` /
`HistoryImportRunnerError`, so the failure path needs no new constructors). Update
`CleanupFailed` to carry a mandatory primary error. Add `cleanupIssues :: ![CleanupIssue]`
to the three report records and update every construction site. Derive `Eq` for
`CleanupIssue` because the pinned Hasql `SessionError` supports equality, preserving the
reports' existing `Eq` instances. Exercise the pair-return with an integration scenario
that makes unlock fail deliberately (a fake provider cannot pass the lifecycle's server
version and resource checks without a real connection). For
example, release the advisory lock inside a session migration via
`SELECT pg_advisory_unlock_all()` so the runner's own unlock returns false) and asserts the
run result is `Right report` with `cleanupIssues == [AdvisoryUnlockReturnedFalse]` and all
migrations recorded applied in the ledger.

Milestone 2 — CLI cascade. Update `Json.hs`/`Text.hs` for the reshaped `CleanupFailed`
(primary error now mandatory) and render the reports' `cleanup_issues` (empty array when
none). Update the goldens under `pg-migrate-cli/test/golden/json` and the field tables in
`docs/reference/json-v1.md`, noting the addition is backward-compatible for JSON consumers
(new field, unchanged existing fields). Coordinate with
`docs/plans/17-fix-cli-runner-option-overrides-and-authoring-input-safety.md` per the
master plan's Integration Points: plan 17 is complete, so preserve its `ExitSucceeded`
constructor, `CliInputError`, and parser behavior. This plan owns every rendering change
for `CleanupFailed`/reports and must append its release notes to the existing `Unreleased`
section in `pg-migrate-cli/CHANGELOG.md`.

Milestone 3 — test-support. In `runCallback`, catch only synchronous exceptions: after
`Exception.try`, inspect the exception with
`Exception.fromException @Exception.SomeAsyncException` (this also covers
`AsyncException`) and rethrow when it matches, mirroring `isAsyncException` in
`Runner.hs:634`. Restructure `withMigratedDatabase` so `Connection.acquire` and the
callback run under one `Exception.mask`/`restore` bracket (acquire inside the mask,
callback under `restore`, release in the exit path) closing the leak window at line ~62.
Change the result mapping so `(Right value, Left _releaseError)` yields `Right value`
(decision above), delete `MigratedDatabaseCallbackCleanupFailed` and
`MigratedDatabaseCallbackAndCleanupFailed`'s success-clobbering role (the latter remains
for callback-failed-and-release-failed), and update the haddocks. Extend
`pg-migrate-test-support/test/Main.hs`: a callback that throws `Exception.AsyncException
Exception.UserInterrupt` (thrown asynchronously via `throwTo` from a helper thread, or
directly via `throwIO` wrapped in `SomeAsyncException`) must propagate out of
`withMigratedDatabase` rather than return `Left`.

Throughout: update `docs/reference/errors-and-events.md` (cleanup issues now travel with
durable outcomes), `docs/reference/public-api.md` (report shapes), and the operations
runbooks that mention `CleanupFailed` (`docs/operations/locking-and-timeouts.md`). Update
`pg-migrate/CHANGELOG.md`, `pg-migrate-cli/CHANGELOG.md`, and
`pg-migrate-test-support/CHANGELOG.md`, marking the `CleanupFailed`/report changes as
breaking.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/pg-migrate`.

```bash
# core loop
cabal build pg-migrate
just unit                                  # cabal test pg-migrate:pg-migrate-unit

# integration (requires PostgreSQL 17/18)
process-compose up --detached
cabal test pg-migrate:pg-migrate-integration

# cascade and full check
cabal test pg-migrate-cli
cabal test pg-migrate-test-support
cabal test all
nix fmt
```

Expected new integration output fragment:

```text
  runner
    unlock failure preserves the migration report: OK
```

Commit message shape:

```text
fix(runner)!: return cleanup issues with durable outcomes

Success reports carry cleanupIssues instead of being replaced by
CleanupFailed; CleanupFailed now always carries its primary error.

MasterPlan: docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md
ExecPlan: docs/plans/18-preserve-durable-success-through-cleanup-failures-and-async-exceptions.md
```


## Validation and Acceptance

Acceptance is behavioral. Core: with a plan whose last session migration runs
`SELECT pg_advisory_unlock_all()`, `runMigrationPlan` returns `Right report`; `results`
lists every migration `AppliedNow`, `cleanupIssues` is non-empty, and re-running returns
`Right` with everything `AlreadyApplied` — before this plan the same scenario returns
`Left (CleanupFailed Nothing …)` with no report. Failure path: a failing migration plus a
broken cleanup still returns `Left (CleanupFailed primary issues)` where `primary` is the
migration failure. CLI: the `up` JSON payload for a clean run contains
`"cleanup_issues": []`, and the golden diff shows only additions. Test-support: the async
test propagates `UserInterrupt` (test asserts via `Exception.try` around
`withMigratedDatabase`), and the result mapping keeps a `Right value` regardless of a
release exception. Hasql's opaque connection API does not provide a safe way to synthesize
a release exception (double release is invalid), so the latter branch is compile-reviewed
while ordinary successful callbacks and async propagation are exercised end to end.
`cabal test all` passes.


## Idempotence and Recovery

All edits are compile-guarded; the type changes make every affected construction site a
compile error, which is the safety net — do not suppress warnings while working. The
integration scenario mutates only an ephemeral/dev database defined by
`process-compose.yaml` and can be re-run freely. If the report-field approach proves wrong
during implementation (for example, a consumer requires errors for any cleanup issue),
stop, record the evidence under Surprises & Discoveries, and add a Decision Log entry
before changing course; the fallback design is a `CleanupObserved` `MigrationEvent`
alongside the report field.


## Interfaces and Dependencies

No new dependencies. End-state signatures that must exist:

```haskell
-- Database.PostgreSQL.Migrate.Runner (internal)
withRunLifecycle ::
  RunOptions ->
  ConnectionProvider ->
  (Connection.Connection -> IO (Either MigrationError value)) ->
  IO (Either MigrationError value, [CleanupIssue])

-- Database.PostgreSQL.Migrate.Runner.Types (re-exported by Database.PostgreSQL.Migrate)
data MigrationError = ... | CleanupFailed !MigrationError !(NonEmpty CleanupIssue) | ...

data MigrationReport = MigrationReport
  { startedAt :: !UTCTime,
    finishedAt :: !UTCTime,
    results :: !(NonEmpty MigrationResult),
    cleanupIssues :: ![CleanupIssue]
  }
```

`RepairReport` (`Database.PostgreSQL.Migrate.Repair.Types`) and `HistoryImportReport`
(`Database.PostgreSQL.Migrate.History.Types`) gain the same `cleanupIssues` field. The Codd
adapter's `CoddUnlockFailed` is deliberately not touched here; it adopts this pattern in
`docs/plans/19-harden-import-adapter-parsing-audit-evidence-and-internal-totality.md` (see
the master plan's Integration Points).


Revision note (2026-07-13): Updated the CLI cascade instructions after EP-1 completed so
this plan preserves the renamed success constructor and existing unreleased changelog
instead of reasoning from the pre-EP-1 tree.

Revision note (2026-07-13): Recorded the completed implementation, verification evidence,
the `CleanupIssue` equality decision, and the real-connection integration-test substitution
so the living plan matches the final tree.
