---
id: 4
slug: remediate-pg-migrate-v1-audit-findings
title: "Remediate pg-migrate v1 audit findings"
kind: master-plan
created_at: 2026-07-13T15:44:27Z
intention: intention_01kxe7gddde44r2d42xyh45c2c
---

# Remediate pg-migrate v1 audit findings

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

A full API-and-bug audit of the pg-migrate workspace (2026-07-13) reviewed every source
module of the six packages and produced a ranked findings list: one high-severity API bug,
six medium bugs, and roughly twenty low-severity correctness, diagnostic, and polish items.
This initiative fixes all of them. When it is complete: a CLI built on `pg-migrate-cli`
never silently discards the runner options its host application configured; an operator can
never lose the report of a migration run, import, or test callback that durably succeeded;
a fat-fingered Codd advisory-lock key is rejected instead of silently wrapping to an
unrelated key; the embed authoring and Template Haskell pipeline cannot paint itself into a
corner or miss a recompilation; SQL validation rejects byte-order marks and misplaced
directives at definition time with accurate line numbers; and repair/import policy handling
is consistent with the runner and documented.

The scope boundary is remediation of the audit findings only. Explicitly excluded: any new
feature work, the actual Hackage/release mechanics (each plan updates changelogs and notes
its PVP impact, but cutting version numbers and publishing is a separate release activity
governed by `docs/reference/release-policy.md` and `agents/skills/release/SKILL.md`), and
any change to the v1 ledger database schema (`ledgerSchemaVersion == 1` stays untouched —
every fix here is in Haskell code, documentation, or the JSON rendering layer).

Several fixes change public API shapes (`ExecutionOptions` fields become `Maybe`, successful
reports gain `cleanupIssues`, `CleanupFailed` requires a primary error, and dead error
constructors are removed). These are acceptable because the packages are pre-Hackage
internal releases; each child plan records the exact API delta in its own Decision Log and
changelog entry so the eventual release notes can be assembled mechanically.


## Decomposition Strategy

The audit findings were grouped by functional concern, not by severity, so that each child
plan touches one coherent subsystem, is independently verifiable with that subsystem's
existing test suite, and can be implemented without reading the other plans. Severity
instead drives the recommended implementation order (the high-severity CLI fix first).

Six work streams emerged. First, the CLI option-handling layer (`pg-migrate-cli`), where
the high-severity finding lives: parsed flag fallbacks unconditionally overwrite
application-supplied `RunOptions`, and the `new --description` text is written into
migration files without line-wise commenting; the CLI's exit-class and parser polish items
ride along because they touch the same modules and tests. Second, a cross-package
behavioral invariant — "cleanup failure or a late async exception must never discard a
durable success" — which appears in three independent implementations (core runner unlock,
Codd source-lock unlock, test-support connection release) and is fixed once as a shared API
decision then applied in each place. Third, the two history-import adapters, whose findings
(lock-key integer wrap, missing audit fields, dead constructors, partial `Map.!` lookups)
are all about adapter input validation and audit completeness. Fourth, the embed package's
authoring and Template Haskell pipeline (numbering rollover, missing directory dependency
tracking, per-byte AST embedding, BOM diagnostics, non-atomic manifest append). Fifth, the
core SQL scanner's definition-time validation gaps (BOM acceptance, silently ignored
misplaced directives, wrong `PsqlMetaCommand` line numbers, the `statement_timeout = 0`
footgun). Sixth, core engine policy-and-performance alignment (repair/import ignoring
`withUnknownMigrationsPolicy`, the O(n²) full-ledger reload per transactional migration and
per-mapping map rebuilds, and the mixed native/imported prefix design question).

An alternative decomposition by severity tier (one plan for the high finding, one for all
mediums, one for all lows) was rejected because the medium findings span five packages —
such plans would not be independently verifiable and every plan would touch every test
suite. A single monolithic plan was rejected because the work spans six packages and more
than five milestones, the threshold at which `agents/skills/master-plan/MASTERPLAN.md`
prescribes decomposition. Merging the scanner plan (EP-5) into the core policy plan (EP-6)
was considered — both touch only the core package — but the scanner work is pure
lexer/validation logic with pure unit tests while the policy work changes runner/repair
behavior against a live database, so they verify differently and stay separate.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Fix CLI runner-option overrides and authoring input safety | docs/plans/17-fix-cli-runner-option-overrides-and-authoring-input-safety.md | None | None | Complete |
| 2 | Preserve durable success through cleanup failures and async exceptions | docs/plans/18-preserve-durable-success-through-cleanup-failures-and-async-exceptions.md | None | EP-1 | Complete |
| 3 | Harden import adapter parsing, audit evidence, and internal totality | docs/plans/19-harden-import-adapter-parsing-audit-evidence-and-internal-totality.md | None | EP-2 | Complete |
| 4 | Fix embed authoring numbering, recompilation tracking, and byte embedding | docs/plans/20-fix-embed-authoring-numbering-recompilation-tracking-and-byte-embedding.md | None | None | Complete |
| 5 | Harden SQL validation against BOM, misplaced directives, and wrong diagnostics | docs/plans/21-harden-sql-validation-against-bom-misplaced-directives-and-wrong-diagnostics.md | None | None | Complete |
| 6 | Align verification policy handling and remove quadratic ledger scans | docs/plans/22-align-verification-policy-handling-and-remove-quadratic-ledger-scans.md | None | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

There are no hard dependencies: every plan compiles and verifies against the current tree
without any other plan's artifacts, so all six can proceed in parallel across sessions.

Two soft dependencies order the work when done serially. EP-2 changes the payload of the
core `CleanupFailed` constructor and adds cleanup observations to successful reports, which
`pg-migrate-cli`'s JSON error rendering in
`pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI/Json.hs` must render; implementing EP-1
first means the CLI test suite (unit, golden, integration) is already trustworthy when EP-2
cascades into it. EP-3 removes the Codd adapter's own copy of the lost-success-on-unlock
defect by adopting whatever success-preserving shape EP-2 establishes; if EP-3 runs first,
it should fix the lock-key reader and audit items and leave the `CoddUnlockFailed` reshaping
to a follow-up noted in its plan.

EP-4 (embed), EP-5 (scanner), and EP-6 (core policy/perf) are fully independent of the
others and of each other. EP-5 and EP-6 both edit the core `pg-migrate` package but in
disjoint modules (`Sql/Scanner.hs`+`Sql.hs`+`Runner/Lock.hs` versus
`Repair.hs`+`History.hs`+`Runner.hs`+`Ledger.hs`), so they can run in parallel with at most
a trivial changelog merge conflict.

Recommended serial order by severity and risk: EP-1, EP-2, EP-3, EP-4, EP-5, EP-6.


## Integration Points

`MigrationError` / `CleanupFailed` (defined in
`pg-migrate/src/Database/PostgreSQL/Migrate/Runner/Types.hs`, rendered in
`pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI/Json.hs` and
`pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI/Text.hs`): EP-2 owns the redefinition
(`CleanupFailed` retains a mandatory primary error while successful reports carry
`cleanupIssues`); EP-1 must not change the JSON error rendering
beyond its own findings so that EP-2's cascade is a clean, single-purpose diff. The JSON v1
contract in `docs/reference/json-v1.md` and the goldens in `pg-migrate-cli/test/golden/json`
are updated only by EP-2 for this constructor. Whichever plan lands second resolves the
changelog merge in `pg-migrate-cli/CHANGELOG.md`.

Unlock-failure result shape for the Codd adapter (`CoddUnlockFailed` in
`pg-migrate-import-codd/src/Database/PostgreSQL/Migrate/History/Codd/Types.hs`): EP-2
defines the pattern (success value preserved alongside cleanup issues); EP-3 applies it by
appending source observations to `HistoryImportReport.cleanupIssues` after target
observations. `CoddUnlockFailed` remains for source-read and primary-failure paths, and its
two `Maybe` fields now document the optional primary error and optional unlock session
error (a missing latter value means unlock returned false).

Evidence-strength gate for `SamePayload` (`validatePayload` in
`pg-migrate/src/Database/PostgreSQL/Migrate/History/Validation.hs`): EP-3 adds the core
enforcement that `SamePayload` checksums must come from evidence of at least
`SourceManifestVerified` strength, closing the `Internal`-bypass hazard it found in the
Codd adapter. EP-6 also edits core history code (`History.hs` map rebuilds) but not
`validatePayload`; both plans note the shared package so the changelog entries merge
cleanly.

Shared test infrastructure: EP-2 modifies `pg-migrate-test-support`, which the integration
suites used by EP-3 and EP-6 depend on. The change (rethrowing async exceptions, preserving
callback results) is strictly behavior-preserving for passing tests, so no coordination is
needed beyond running `cabal test all` after each plan.

Conventions that apply to every plan: commits follow Conventional Commits with the
`MasterPlan:` trailer naming this file and the `ExecPlan:` trailer naming the child plan;
every plan updates its package `CHANGELOG.md`; formatting is `nix fmt` (fourmolu); the
standard verification commands are `just unit` (core unit tests), `cabal test all` (needs
the process-compose PostgreSQL from `process-compose.yaml`), and `just acceptance` for the
full matrix.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: Optional execution flags no longer clobber application `RunOptions`
- [x] EP-1: `new --description` is line-safe; CLI exit-class and parser polish landed
- [x] EP-2: Core runner returns preserved success alongside cleanup issues
- [x] EP-2: CLI JSON/text render the new `CleanupFailed` shape; goldens updated
- [x] EP-2: Test-support rethrows async exceptions and preserves callback results
- [x] EP-3: Codd lock-key reader rejects out-of-range keys
- [x] EP-3: Audit evidence completeness (source table recorded, strict-source symmetry, dead constructors removed)
- [x] EP-3: Internal totality and core `SamePayload` strength gate
- [x] EP-3: Committed Codd import reports survive source-lock cleanup failures
- [x] EP-4: Numbering rollover fixed with regression tests
- [x] EP-4: GHC 9.12 directory-membership revalidation via a module-local compiler plugin
- [x] EP-4: Efficient byte embedding and authoring/diagnostic polish
- [x] EP-5: BOM rejected at definition time in scanner and embed manifest
- [x] EP-5: Misplaced directives rejected; line numbers corrected
- [x] EP-5: `statement_timeout` zero semantics resolved and documented
- [x] EP-6: Repair/import unknown-migrations policy decision implemented and documented
- [x] EP-6: Quadratic ledger reload and map rebuilds removed
- [x] EP-6: Mixed native/imported prefix semantics tested and documented


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- EP-1 established `ExitSucceeded` as the CLI success constructor, added
  `CliInputError`, changed `check` to `--manifest`, and created an existing `Unreleased`
  changelog section. Later plans touching `pg-migrate-cli` must preserve those public API
  and parser changes and append their release notes to that section. Evidence: EP-1's
  workspace-wide `cabal test all` rebuilt both import adapters successfully against the
  changed CLI facade.

- EP-2 established the cleanup contract EP-3 must copy for the Codd source lock: durable
  successes retain ordered cleanup observations as report data, while cleanup after a
  failure retains a mandatory primary error. The core reports expose
  `cleanupIssues :: [CleanupIssue]`, JSON v1 exposes additive `cleanup_issues`, and
  `CleanupIssue` now derives `Eq`. Evidence: the real PostgreSQL regression releases the
  lock from a committed migration and receives `Right MigrationReport` with
  `AdvisoryUnlockReturnedFalse`; all 15 acceptance groups pass.

- EP-3 reused `HistoryImportReport.cleanupIssues` for Codd source-lock cleanup rather than
  introducing an adapter-specific report. Target-runner cleanup observations come first;
  source unlock observations are appended. Evidence: a real PostgreSQL view releases the
  source lock while being read, after which the committed import returns `Right` with
  `[AdvisoryUnlockReturnedFalse]` and the full 15-group acceptance suite passes.

- EP-3 added the public `HistoryPayloadEvidenceTooWeak` validation constructor and made
  `SamePayload` require `SourceManifestVerified` strength or better. EP-6 touches nearby
  history-import code and must preserve this gate when optimizing map construction, though
  its planned `History.hs` edits do not overlap `Validation.hs`.

- EP-4 found that the declared GHC 9.12.4 toolchain ships
  `template-haskell-2.23.0.0`, which has no `addDependentDirectory` API. Using
  `addDependentFile` on the manifest directory fails with `withBinaryFile: inappropriate
  type (is a directory)`, and recursively registering current files cannot observe a future
  filename. A module-local GHC plugin pragma loads early enough to force just the embedding
  module through the membership audit; the downstream harness now proves add/remove
  behavior separately from ordinary listed-file tracking.

- EP-4's primitive literal removed the per-byte Template Haskell AST blow-up. A
  1,048,577-byte forced unit build did not finish with the old representation after 106.59
  seconds; the `BytesPrimL` implementation completed the full forced unit build in 10.21
  seconds and preserved all 256 byte values.

- EP-5 added the public `ByteOrderMarkFound` and `MisplacedDirective` `SqlError`
  constructors, made scanner line diagnostics file-absolute, and rejected non-positive
  temporary statement timeouts before connection acquisition. EP-6 shares the core
  changelog and must preserve these major-release notes when adding its entries. Evidence:
  `nix fmt` changed no files and all 11 Cabal test suites passed.

- EP-6 found that the pure allow/reject comparator already had direct unit coverage; the
  audited defect was entirely in the repair and import callers. Entry-point PostgreSQL
  regressions now prove both the strict default and explicit shared-ledger behavior. The
  final implementation also replaces per-transaction full-ledger reloads with keyed
  existence checks and builds import classification maps once. Evidence: `just acceptance`
  passed all 11 Cabal suites, the production-closure check, and all 15 PostgreSQL 17 groups.


## Decision Log

- Decision: Decompose by functional subsystem (six plans) rather than by severity tier.
  Rationale: Severity tiers would make every plan span five packages and defeat independent
  verifiability; subsystems map one-to-one onto package test suites.
  Date: 2026-07-13

- Decision: Model the cross-package "never discard durable success" invariant as a single
  plan (EP-2) covering core, CLI rendering, and test-support, with the Codd adapter copy
  delegated to EP-3 via an integration point.
  Rationale: The API decision (how a preserved success travels inside an error) must be
  made once; the Codd adapter fix is mechanical application of that decision and belongs
  with the other adapter work.
  Date: 2026-07-13

- Decision: No hard dependencies between plans; EP-1 before EP-2 and EP-2 before EP-3 are
  soft, severity-driven orderings only.
  Rationale: Each plan compiles and verifies standalone today; serializing would only slow
  the initiative down.
  Date: 2026-07-13

- Decision: Release mechanics (version bumps, publishing) are out of scope; each plan
  records its PVP impact in its changelog instead.
  Rationale: The release checklist (`docs/release-checklist.md`) is its own process and the
  audit remediation should not block on it.
  Date: 2026-07-13

- Decision: EP-2 represents cleanup after durable success in the three public success
  reports and reserves `CleanupFailed` for cleanup accompanying a primary
  `MigrationError`; EP-3 should apply the same success-versus-primary distinction to
  `CoddUnlockFailed`.
  Rationale: A polymorphic lifecycle error cannot contain every possible success value,
  whereas report fields preserve the existing `Either error report` operation signatures
  and prevent successful audit evidence from being discarded.
  Date: 2026-07-13

- Decision: Carry Codd source-unlock observations in the existing
  `HistoryImportReport.cleanupIssues` field, ordered after target-runner observations.
  Rationale: This applies EP-2's shared durable-success contract without a second report
  type and keeps the adapter's public operation signature unchanged.
  Date: 2026-07-13

- Decision: Complete EP-4 on GHC 9.12.4 with an exposed no-op Core plugin loaded by a
  module-local `OPTIONS_GHC -fplugin=...` pragma in each embedding module.
  Rationale: The pragma affects real downstream compilation and confines
  `ForceRecompile` to the small module containing the splice. It reruns strict membership
  validation for additions and removals without pretending that enumerating current files
  can track names that do not yet exist.
  Date: 2026-07-13

- Decision: Apply `UnknownMigrationsPolicy` consistently to execution, repair, and history
  import while retaining the conservative rule that import mappings alone form the legacy
  prefix and native rows without import audits remain conflicts.
  Rationale: Configuration must not change meaning between entry points, but importing may
  not silently adopt target rows for which it has no source evidence. The default remains
  strict, and the documented import-first workflow supports safe cutover.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

All six child plans are complete, and every finding in the 2026-07-13 audit is remediated
within the initiative's scope. The CLI preserves application runner options and safely
authors descriptions. Migration, repair, history-import, Codd-source, and test-support
cleanup paths retain durable success and correctly propagate asynchronous interruption.
Import adapters reject lock-key overflow, produce complete audit evidence, avoid partial
lookups, enforce verified `SamePayload` evidence, and preserve committed reports through
source cleanup.

Embed authoring now handles numbering exhaustion, exact primitive byte embedding,
byte-order marks, post-rename clobber detection, and GHC 9.12 directory membership changes.
Core SQL validation rejects leading BOMs and misplaced directives with file-absolute
diagnostics, and non-positive statement timeouts fail before connection acquisition.
Execution, repair, and history import now interpret unknown-migration policy consistently.
Transactional completion uses a keyed row lookup instead of repeatedly loading the whole
ledger, history classification maps are built once, and the conservative import-first
prefix contract is covered by real PostgreSQL scenarios and an operator runbook.

The final `nix fmt` run changed no files. `just acceptance` built every package, passed all
11 Cabal test suites, passed the production dependency-closure check, and passed all 15
PostgreSQL 17 acceptance groups. No ledger schema change was required. Version bumps and
Hackage publication remain deliberately outside this MasterPlan and can proceed through
the repository's release process using the accumulated changelog entries.


Revision note (2026-07-13): Marked EP-2 complete, recorded its report-based cleanup
contract for EP-3, and updated aggregate progress and outcomes after the full acceptance
matrix passed.

Revision note (2026-07-13): Marked EP-3 complete, recorded its core evidence-strength gate
and reuse of report cleanup observations, and updated aggregate outcomes after all 15
acceptance groups passed.

Revision note (2026-07-13): Recorded EP-4's completed numbering, byte-embedding, and polish
milestones plus its GHC 9.12 directory-dependency blocker; kept EP-4 In Progress after all
11 workspace test suites passed.

Revision note (2026-07-13): Completed EP-4 after verifying the GHC 9.12 module-local
recompilation plugin against a real add/remove downstream build while retaining a separate
probe for ordinary tracked-file dependencies.

Revision note (2026-07-13): Completed EP-5 after clean formatting and all 11 workspace test
suites passed; recorded its public `SqlError`, scanner diagnostic, and timeout-validation
contracts for the remaining core plan.

Revision note (2026-07-13): Completed EP-6 and the full audit-remediation initiative after
the full acceptance recipe passed; recorded consistent policy handling, linearized ledger
checks, conservative mixed-history semantics, and the final retrospective.
