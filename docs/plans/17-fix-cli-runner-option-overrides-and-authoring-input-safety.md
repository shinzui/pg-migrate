---
id: 17
slug: fix-cli-runner-option-overrides-and-authoring-input-safety
title: "Fix CLI runner-option overrides and authoring input safety"
kind: exec-plan
created_at: 2026-07-13T15:44:36Z
intention: intention_01kxe7gddde44r2d42xyh45c2c
master_plan: "docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md"
---

# Fix CLI runner-option overrides and authoring input safety

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`pg-migrate-cli` is a library of optparse-applicative parsers and command handlers that an
application embeds to get a migration executable. The application constructs a
`CliEnvironment` carrying its plan, its connection configuration, and — critically — its
own `RunOptions` (advisory-lock wait policy, statement timeout, verification policy, event
handler). Today that promise is broken: when a user runs `myapp up` or `myapp repair`
without passing `--no-wait`, `--lock-timeout`, or `--statement-timeout`, the CLI parser's
fallback values (`WaitIndefinitely` and "no timeout") are applied over the application's
configured options, silently removing, for example, a 30-second statement timeout and a
no-wait lock policy the application deliberately set. This is the highest-severity finding
of the 2026-07-13 audit. Separately, `myapp new --description` writes its argument into the
first line of a fresh migration file behind `-- `, so a description containing a newline
produces uncommented, executable SQL in the generated file.

After this plan, absent CLI flags mean "keep the application's configuration", present
flags override it explicitly (including a new explicit way to request an indefinite wait or
no timeout), and `--description` rejects embedded line breaks and control characters at
parse time. A batch of smaller CLI findings from the same audit is fixed alongside because
it touches the same modules and test suites: exit-class misclassification of IO failures,
the `ExitSuccess` name collision with `System.Exit`, inspection filters that silently match
nothing, the filtered-payload/`issues` inconsistency, the `check`/`new` manifest-argument
inconsistency, misleading "target-aware" parser haddocks, and the duplicated checksum
renderer.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: `ExecutionOptions` fields made optional; parser and `applyExecution` updated; regression tests added. (2026-07-13 10:57 PDT)
- [x] Milestone 2: `--description` input validation; authoring exit-class fixes. (2026-07-13 11:00 PDT)
- [ ] Milestone 3: Remaining CLI polish (exit-class rename, filter validation, payload/issue consistency, manifest flag unification, haddocks, checksum renderer dedup, prelude exposure).
- [ ] All test suites pass (`cabal test all`); changelog updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: `applyExecution` lives in the library's hidden `Handler` module, so importing
  it from the external unit-test component would require exposing an implementation detail
  as public API. Parser unit tests instead cover every optional override shape, and the
  integration lifecycle now proves the handler preserves an application-configured
  `NoWait` policy and five-second statement timeout. Evidence: all 36 unit/golden tests
  passed and `cabal build pg-migrate-cli:pg-migrate-cli-integration` compiled the new
  regression scenario on 2026-07-13.

- Observation: `NewOptions` is publicly constructible, so parser-only description
  validation would leave direct library callers able to write multiline SQL. The handler
  now repeats the same pure validation before calling the embed authoring API. Evidence:
  `new rejects control characters before writing files` verifies that neither the SQL file
  nor manifest changes when a direct command contains a newline.


## Decision Log

- Decision: Absent flags preserve application `RunOptions`; explicit flags `--wait`
  (indefinite) and `--no-statement-timeout` are added so every runner setting remains
  reachable from the command line.
  Rationale: Flag-absence must be distinguishable from an explicit request for the default,
  otherwise the application's configuration is unreachable dead code on `up`/`repair`.
  Date: 2026-07-13

- Decision: `--description` rejects newlines and other control characters instead of
  commenting each line.
  Rationale: The description is a one-line title written into a `-- ` comment; multi-line
  input is almost certainly an accident, and rejecting is safer than silently rewriting.
  Date: 2026-07-13

- Decision: Rename the `ExitClass` constructor `ExitSuccess` to `ExitSucceeded`.
  Rationale: Every consumer must also import `System.Exit` (the library deliberately leaves
  process exit to the application), and `System.Exit.ExitSuccess` collides. Pre-release
  breaking change, recorded in the changelog.
  Date: 2026-07-13

- Decision: Keep `applyExecution` internal and test its public effect in the PostgreSQL
  integration lifecycle rather than exporting the helper solely for a unit test.
  Rationale: The parser unit tests fully cover absent and explicit values; the integration
  migration fails unless both non-default application settings survive dispatch, without
  widening the stable CLI facade.
  Date: 2026-07-13

- Decision: Add `CliInputError` and validate descriptions in both the parser and handler.
  Rationale: Parser validation gives immediate command-line feedback, while handler
  validation protects applications that construct the exported command algebra directly;
  the dedicated error preserves a clear usage-level diagnostic without misclassifying the
  problem as an embed-package authoring error.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

`pg-migrate-cli` lives in `pg-migrate-cli/` and exposes one public facade,
`Database.PostgreSQL.Migrate.CLI` (`pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI.hs`),
which re-exports from these internal modules (all under
`pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI/`):

- `Types.hs` — `CliEnvironment` (application-supplied plan, default connection, and
  `runnerOptions :: RunOptions`), `MigrationCommand`, `ConnectionOptions`,
  `ExecutionOptions { lockWait :: LockWait, statementTimeout :: Maybe NominalDiffTime }`,
  `InspectionOptions`, `OutputOptions`.
- `Parser.hs` — `migrationCommandParser :: MigrationPlan -> Parser MigrationCommand` and the
  per-option parsers. The defect: `lockWaitParser` (around line 175) ends with
  `<|> pure WaitIndefinitely`, and `--statement-timeout` is wrapped in `optional`, so both
  always produce a value even when no flag was given.
- `Handler.hs` — `runMigrationCommand` dispatches to `runStatus`, `runVerify`, `runUp`,
  `runRepair`, `runList`, `runCheck`, `runNew`. The defect: `applyExecution` (line 201)
  does `withStatementTimeout statementTimeout . withLockWait lockWait` unconditionally, so
  `runUp` (line 143) and `runRepair` (line 154) clobber `runnerOptions`. `runStatus` and
  `runVerify` use `runnerOptions environment` untouched — the inconsistency users observe.
  `runNew` (line 178) builds `initialSql = Text.Encoding.encodeUtf8 ("-- " <> description
  <> "\n\n")` — the multi-line hazard. `authoringExitClass` (line 210) sends
  `AuthoringManifestError (ManifestIoError …)` to the `_ -> ExitUsageFailed` catch-all, and
  `runCheck` maps every `ManifestError` (including IO errors) to `ExitUsageFailed`.
  `filterStatus`/`filterVerification` (lines 242-256) filter the `applied`/`pending`/
  `unknown` lists but pass `issues` through unfiltered.
- `Outcome.hs` — `ExitClass` with constructors `ExitSuccess`, `ExitVerificationFailed`,
  `ExitUsageFailed`, `ExitExecutionFailed`, plus `exitCodeFor`.
- `Text.hs` and `Json.hs` — human and JSON renderers. Each contains an identical private
  `checksumText` hex renderer (Text.hs around line 134, Json.hs around line 277).

"RunOptions" is the core runner configuration record from
`pg-migrate/src/Database/PostgreSQL/Migrate/Runner/Types.hs`; the modifiers `withLockWait`,
`withStatementTimeout` are re-exported by `Database.PostgreSQL.Migrate`. `LockWait` has
constructors `WaitIndefinitely`, `WaitFor NominalDiffTime`, `NoWait`.

Tests: unit tests in `pg-migrate-cli/test/unit/` (`Test/Parser.hs`, `Test/Handler.hs`,
`Test/Json.hs`), JSON goldens under `pg-migrate-cli/test/golden/json`, a help-text fixture
executable in `pg-migrate-cli/test/help-fixture/`, and an integration suite in
`pg-migrate-cli/test/integration/Main.hs` that needs a running PostgreSQL (start it with
`process-compose up` per `process-compose.yaml`, or rely on `cabal test all` in an
environment where `PG_CONNECTION_STRING` points at a PostgreSQL 17/18).

The JSON v1 contract is documented in `docs/reference/json-v1.md`; the CLI user guide is
`docs/user/cli-integration.md`. Both must be updated where behavior changes.


## Plan of Work

Milestone 1 — optional execution overrides. In `Types.hs`, change `ExecutionOptions` to
`ExecutionOptions { lockWait :: Maybe LockWait, statementTimeout :: Maybe (Maybe
NominalDiffTime) }`. The outer `Maybe` on both fields means "was a flag given at all";
the inner `Maybe NominalDiffTime` retains the core meaning where `Nothing` disables the
temporary timeout. In `Parser.hs`, rewrite `executionOptionsParser`: `lockWait` becomes
`optional (flag' NoWait (long "no-wait" …) <|> WaitFor <$> option positiveMillisecondsReader
(long "lock-timeout" …) <|> flag' WaitIndefinitely (long "wait" <> help "Wait indefinitely
for the advisory lock"))` — note the removal of the terminal `pure WaitIndefinitely`.
`statementTimeout` becomes `optional (Just <$> option positiveMillisecondsReader (long
"statement-timeout" …) <|> flag' Nothing (long "no-statement-timeout" <> help "Run without
a temporary statement timeout"))`. In `Handler.hs`, rewrite `applyExecution` as
`maybe id withStatementTimeout statementTimeout . maybe id withLockWait lockWait`. Update
the help-fixture golden output and `docs/user/cli-integration.md` to describe the new flags
and the "absent flag keeps application configuration" rule. Add unit tests in
`Test/Parser.hs` asserting that parsing `["up"]` yields `ExecutionOptions Nothing Nothing`
and that each flag yields the corresponding `Just`; add a `Test/Handler.hs` test asserting
`applyExecution (ExecutionOptions Nothing Nothing) options == options` for a non-default
`options` (compare via the accessor functions `runLockWait`/`runStatementTimeout`, since
`RunOptions` has no `Eq`).

Milestone 2 — authoring input safety and exit classes. In `Handler.hs` (or `Parser.hs` if
the validation fits better as a `ReadM`), reject any `--description` containing `\n`, `\r`,
or other `Char.isControl` characters with a usage-level failure whose message names the
offending character; only then build `initialSql`. Fix `authoringExitClass` so
`AuthoringManifestError (ManifestIoError …)` maps to `ExitExecutionFailed`, and split
`runCheck`'s error mapping: `ManifestIoError` → `ExitExecutionFailed`, all other manifest
errors remain `ExitUsageFailed`. Add unit tests for both classifications and for the
rejected description.

Milestone 3 — polish. Rename `ExitClass`'s `ExitSuccess` constructor to `ExitSucceeded`
across `Outcome.hs`, `Handler.hs`, `Text.hs`, `Json.hs`, and tests (the rendered JSON
string and exit codes do not change — verify against the goldens). Make `runStatus`/
`runVerify`/`runList` fail with a usage error when `--component` or `--migration` names
nothing in the environment's plan (the plan is available in `CliEnvironment`), so typos are
loud; also filter `issues` in `filterStatus`/`filterVerification` down to the selected
component/migration while still computing the exit class from the unfiltered report (a
filtered view must not mask failures — keep the existing `verificationExitClass report`
call on the full report). Change `check` to take the manifest via `--manifest` like `new`
(update parser, help fixture, docs). Fix the haddocks on `migrationCommandParser`,
`coddImportCommandParser`-style claims inside this package (`Parser.hs` line 26) to state
the plan parameter is reserved for future target-aware completion rather than claiming it
is used. Move the duplicated `checksumText` into a single definition in `Types.hs` (already
imported by both renderers) and delete the copies. Finally, grep the workspace for external
importers of `PgMigrate.CLI.Prelude`; if only `pg-migrate-cli` modules import it, move it
from `exposed-modules` to `other-modules` in `pg-migrate-cli/pg-migrate-cli.cabal`.

Record every one of these behavior changes in `pg-migrate-cli/CHANGELOG.md` under an
"Unreleased" heading, marking the `ExecutionOptions` and `ExitClass` changes as breaking.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/pg-migrate`.

```bash
# fast feedback while editing
cabal build pg-migrate-cli
cabal test pg-migrate-cli:pg-migrate-cli-unit

# goldens and help fixture (regenerate only after reviewing diffs)
cabal test pg-migrate-cli

# full check before committing (integration needs PostgreSQL from process-compose)
process-compose up --detached   # if no database is already running
cabal test all
nix fmt
```

Expected shape of the unit-test run after Milestone 1:

```text
pg-migrate-cli-unit
  Parser
    up with no flags leaves execution options empty:        OK
    --wait selects an explicit indefinite wait:             OK
    --no-statement-timeout disables the timeout explicitly: OK
  Handler
    absent flags preserve application run options:          OK
```

Commit after each milestone with Conventional Commits and both trailers, for example:

```text
fix(cli)!: stop overriding application RunOptions with parser fallbacks

Absent --no-wait/--lock-timeout/--statement-timeout now preserve the
application-configured lock wait and statement timeout; new --wait and
--no-statement-timeout flags make the previous fallbacks explicit.

MasterPlan: docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md
ExecPlan: docs/plans/17-fix-cli-runner-option-overrides-and-authoring-input-safety.md
```


## Validation and Acceptance

Acceptance for Milestone 1 is behavioral: construct `defaultRunOptions` modified with
`withLockWait NoWait` and `withStatementTimeout (Just 30)` in a test, parse `["up"]` with
no execution flags, apply the handler's option application, and observe via `runLockWait`/
`runStatementTimeout` that both configured values survive; parse `["up", "--wait"]` and
observe `WaitIndefinitely`; parse `["up", "--no-statement-timeout"]` and observe `Nothing`.
Before the fix the first test fails (values become `WaitIndefinitely`/`Nothing`); after the
fix all pass.

Acceptance for Milestone 2: `runNew` invoked with a description containing `"\nDROP TABLE
accounts;"` returns a usage-class failure and creates no file; a single-line description
still produces a file beginning with `-- <description>` followed by a blank line. A
simulated `ManifestIoError` from `check` yields `ExitExecutionFailed`.

Acceptance for Milestone 3: `verify --component nope` fails with a usage error naming the
unknown component; `verify --component <real>` output contains only issues for that
component while a mismatch in another component still yields the verification exit class;
JSON goldens are byte-identical except where a golden deliberately covers changed behavior;
`grep -rn "ExitSuccess" pg-migrate-cli/src` returns no hits outside comments.

Final acceptance: `cabal test all` passes, `nix fmt` produces no diff, and
`docs/user/cli-integration.md` plus `docs/reference/json-v1.md` describe the new flag
semantics.


## Idempotence and Recovery

Every step is a source edit guarded by the test suite; re-running builds and tests is
always safe. If golden tests fail unexpectedly, inspect the diff before regenerating —
goldens encode the public JSON v1 contract, and only deliberate changes from this plan
(none to JSON payload shapes; only help-fixture text) may be accepted. If the
`ExitSucceeded` rename causes churn beyond this package, revert the rename commit
(`git revert`) and record the discovery here before retrying.


## Interfaces and Dependencies

No new dependencies. At the end of Milestone 1 the following must exist in
`Database.PostgreSQL.Migrate.CLI` (re-exported from `CLI/Types.hs`):

```haskell
data ExecutionOptions = ExecutionOptions
  { lockWait :: !(Maybe LockWait),
    statementTimeout :: !(Maybe (Maybe NominalDiffTime))
  }
```

and in `CLI/Handler.hs`:

```haskell
applyExecution :: ExecutionOptions -> RunOptions -> RunOptions
-- absent fields are identity; present fields delegate to
-- Database.PostgreSQL.Migrate.withLockWait / withStatementTimeout
```

At the end of Milestone 3, `Database.PostgreSQL.Migrate.CLI.Outcome.ExitClass` has
constructors `ExitSucceeded`, `ExitVerificationFailed`, `ExitUsageFailed`,
`ExitExecutionFailed`, and exactly one `checksumText :: MigrationChecksum -> Text` exists
in the package. This plan must not alter the JSON rendering of core `MigrationError`
constructors — that surface is owned by
`docs/plans/18-preserve-durable-success-through-cleanup-failures-and-async-exceptions.md`
(see the master plan's Integration Points).
