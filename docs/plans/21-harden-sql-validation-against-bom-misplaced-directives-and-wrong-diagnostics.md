---
id: 21
slug: harden-sql-validation-against-bom-misplaced-directives-and-wrong-diagnostics
title: "Harden SQL validation against BOM, misplaced directives, and wrong diagnostics"
kind: exec-plan
created_at: 2026-07-13T15:44:36Z
intention: intention_01kxe7gddde44r2d42xyh45c2c
master_plan: "docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md"
---

# Harden SQL validation against BOM, misplaced directives, and wrong diagnostics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Every SQL migration passes through a definition-time validator before it can enter a plan:
`validateSql` checks UTF-8, then a scanner (`scanSql`) splits statements, rejects psql
meta-commands, `COPY FROM STDIN`, and explicit transaction-control commands, and recognizes
exactly one directive — a leading comment `-- pg-migrate: no-transaction` — which marks the
migration nontransactional (required for statements like `CREATE INDEX CONCURRENTLY` that
cannot run inside a transaction). The point of this front door is that authoring mistakes
fail at definition time with a precise `SqlError`, never at deploy time against production.

The 2026-07-13 audit found three gaps where mistakes slip through to run time or produce
wrong diagnostics, plus one adjacent runtime footgun. A UTF-8 byte-order mark (BOM,
bytes `EF BB BF`) is valid UTF-8, so a BOM-prefixed file passes validation — but the BOM
defeats directive detection (the leading-comment scan sees a non-space, non-comment
character and stops) and then lands inside the first statement, where PostgreSQL fails at
run time with an inscrutable syntax error. A `-- pg-migrate: no-transaction` comment placed
after the first statement is silently dropped — the typo-guard (`UnknownDirective`) only
protects the leading region, so a misplaced directive gives the author no signal at all.
The `PsqlMetaCommand` error's line number is computed after the leading comments are
stripped, so it points at the wrong line whenever a file starts with comments. Finally, in
the runner's timeout layer, `withStatementTimeout (Just 0)` formats as `0ms` — which
PostgreSQL interprets as *disabling* the statement timeout, the opposite of the strictest
possible value a caller could plausibly intend.

After this plan, all four are definition-time (or option-validation-time) errors with
accurate positions, covered by unit tests and documented.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-13T20:05:39Z) Milestone 1: leading BOM rejected by `validateSql` with a dedicated `SqlError`; all 107 core unit tests pass, including ordinary SQL, hidden-directive, and mid-file U+FEFF coverage.
- [x] (2026-07-13T20:07:17Z) Milestone 2: misplaced `pg-migrate:` line comments are rejected with their file-absolute line; leading-region line accounting also makes psql meta-command diagnostics file-absolute, and all 109 core unit tests pass.
- [ ] Milestone 3: non-positive statement timeouts rejected; timeout semantics documented.
- [ ] Docs (`manifest-authoring.md`, `locking-and-timeouts.md`, `errors-and-events.md` if error tables are listed) and core changelog updated; `cabal test all` green.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Reject a leading BOM rather than stripping it.
  Rationale: The checksum contract is "exact payload bytes"; silently altering bytes would
  change fingerprints depending on library version. Rejection with a named error tells the
  author to fix the file once.
  Date: 2026-07-13

- Decision: A `pg-migrate:`-prefixed line comment anywhere outside the leading region is an
  error (new `MisplacedDirective` constructor), not just unknown directives in the leading
  region.
  Rationale: Today a misplaced `no-transaction` directive silently yields a transactional
  migration; the failure then happens at deploy time (e.g. `CREATE INDEX CONCURRENTLY
  cannot run inside a transaction block`). Loud and early beats silent and late.
  Date: 2026-07-13

- Decision: `withStatementTimeout (Just t)` requires `t > 0`; zero and negative values are
  rejected by option validation (`InvalidStatementTimeout`). "No temporary timeout" remains
  expressible as `Nothing`.
  Rationale: PostgreSQL treats `statement_timeout = 0` as "disabled", which inverts the
  caller's plausible intent; there is no use case for explicitly setting 0 that `Nothing`
  does not cover.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

All code is in the core package `pg-migrate/`:

- `src/Database/PostgreSQL/Migrate/Sql.hs` — `validateSql :: ByteString -> Either SqlError
  SqlScan` runs a hand-rolled UTF-8 validator (`validateUtf8`) and then `scanSql` on the
  decoded text.
- `src/Database/PostgreSQL/Migrate/Sql/Scanner.hs` — the scanner. `SqlError` (lines 17-39)
  is the error type to extend. `scanSql` (line 67) first calls `scanLeadingRegion` (lines
  79-89), which consumes leading whitespace, line comments (inspecting them for directives
  via `inspectLeadingComment`, lines 91-102), and block comments; everything after is the
  "body", scanned by `scanStatements` (lines 114-166). Two defects live here:
  `scanStatements` starts its line counter at 1 even though the leading region may have
  consumed many lines (so `PsqlMetaCommand { lineNumber }` is wrong), and its line-comment
  branch (line 125-126) drops comments via `dropLineComment` without inspecting them for a
  `pg-migrate:` prefix.
- `src/Database/PostgreSQL/Migrate/Runner.hs` — `validateOptions` (lines 620-627) currently
  rejects only negative timeouts; `src/Database/PostgreSQL/Migrate/Runner/Lock.hs` —
  `applyStatementTimeout` (lines 77-92, same negative-only guard) and
  `formatStatementTimeout` (lines 125-131, where `0` becomes `"0ms"`).

The directive grammar: only line comments (`-- …`) in the leading region participate;
`inspectLeadingComment` strips the comment text and matches the exact string
`pg-migrate: no-transaction`, errors on any other `pg-migrate:` prefix
(`UnknownDirective`), and errors on duplicates. A "leading region" means everything before
the first non-comment, non-whitespace character of the file.

Unit tests for the scanner are in `pg-migrate/test/unit/Test/Sql.hs`; runner option tests
in `pg-migrate/test/unit/Test/Runner.hs`. The SQL authoring rules users read are in
`docs/user/manifest-authoring.md` and `docs/user/component-authoring.md`; timeout behavior
is documented in `docs/operations/locking-and-timeouts.md`.


## Plan of Work

Milestone 1 — BOM. Add `ByteOrderMarkFound` to `SqlError` in `Scanner.hs`. In `Sql.hs`
`validateSql`, before UTF-8 validation, check whether the input starts with
`"\xEF\xBB\xBF"` (`Data.ByteString.isPrefixOf`) and fail with the new error. Do not strip.
Add tests in `Test/Sql.hs`: a BOM-prefixed `SELECT 1;` fails with `ByteOrderMarkFound`; a
BOM-prefixed directive file fails the same way (this is the scenario that today silently
produces a transactional scan); U+FEFF appearing mid-file is left to PostgreSQL (document
this choice in the test's comment — only the leading BOM is a known editor artifact).

Milestone 2 — misplaced directives and line numbers. In `Scanner.hs`, change
`scanLeadingRegion` to also count the newlines it consumes and return that count (extend
its result to carry the starting line for the body), and start `scanStatements`' counter
from it, so `PsqlMetaCommand` line numbers are file-absolute. Then extend the body scanner:
in the `'-' : '-' : rest` branch, capture the comment text (up to newline) instead of
blindly dropping it; if its stripped form begins with `pg-migrate:`, fail with a new
`SqlError` constructor `MisplacedDirective { directive :: Text, lineNumber :: Int }`; block
comments are unaffected (directives were never valid there — mention it in the haddock).
Tests: a file with two leading comment lines and `\copy` on line 4 reports `lineNumber = 4`
(currently reports a smaller number — write the failing assertion first); `SELECT 1;\n--
pg-migrate: no-transaction` fails with `MisplacedDirective` at line 2; an innocuous
trailing comment (`-- done`) still passes; the existing leading-region directive tests keep
passing unchanged.

Milestone 3 — timeout zero. Tighten `validateOptions` in `Runner.hs` and
`applyStatementTimeout` in `Runner/Lock.hs` from `timeout < 0` to `timeout <= 0`, so
`Just 0` yields `InvalidStatementTimeout 0` before any connection work. Keep
`formatStatementTimeout` as-is (it can no longer receive 0). Update
`docs/operations/locking-and-timeouts.md`: absent timeout (`Nothing`) leaves the session
default untouched; positive values are applied temporarily and restored; sub-millisecond
values round up to 1ms; zero/negative are rejected. Add unit tests in `Test/Runner.hs` for
the `Just 0` rejection.

Update `pg-migrate/CHANGELOG.md` (two new `SqlError` constructors — technically breaking
for exhaustive matchers — and the stricter timeout validation). If
`docs/reference/errors-and-events.md` or the CLI error tables enumerate `SqlError`
constructors, add the new ones; the CLI renders `DefinitionError`/`SqlError` only through
`Show` at authoring boundaries, so no golden changes are expected — verify with
`cabal test pg-migrate-cli`.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/pg-migrate`.

```bash
cabal build pg-migrate
just unit                    # cabal test pg-migrate:pg-migrate-unit

# confirm no downstream fallout
cabal test pg-migrate-cli
cabal test all
nix fmt
```

Expected new unit-test fragment:

```text
pg-migrate-unit
  Sql
    leading BOM is rejected:                          OK
    misplaced no-transaction directive is rejected:   OK
    psql meta-command line number is file-absolute:   OK
  Runner
    statement timeout of zero is rejected:            OK
```

Commit message shape:

```text
fix(sql): reject BOMs and misplaced directives at definition time

MasterPlan: docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md
ExecPlan: docs/plans/21-harden-sql-validation-against-bom-misplaced-directives-and-wrong-diagnostics.md
```


## Validation and Acceptance

Acceptance is expressed as validator behavior on concrete inputs. `validateSql
"\xEF\xBB\xBF-- pg-migrate: no-transaction\nCREATE INDEX CONCURRENTLY i ON t (c);"`
returns `Left ByteOrderMarkFound` — before this plan it returns `Right` with a
*transactional* scan, which is the silent hazard being closed. `validateSql "SELECT 1;\n--
pg-migrate: no-transaction\n"` returns `Left (MisplacedDirective …)` naming line 2.
`validateSql "-- a\n-- b\n\n\\copy t from stdin"` reports the meta-command on line 4.
`runMigrationPlan` with `withStatementTimeout (Just 0)` fails fast with
`InvalidStatementTimeout 0` without acquiring a connection (assert via a provider that
fails the test if used — `validateOptions` runs before acquisition in
`withRunLifecycle`). All existing scanner tests pass unchanged; `cabal test all` is green.


## Idempotence and Recovery

Pure validator changes guarded by pure tests — every step re-runs safely with no external
state. The only risk is over-rejection breaking existing in-tree migrations or fixtures:
run `cabal test all` (which compiles every embedded fixture in `pg-migrate-embed` and the
adapters) before committing each milestone; if a legitimate fixture trips a new error,
record it in Surprises & Discoveries and fix the fixture (not the validator) unless the
fixture reveals a real false positive.


## Interfaces and Dependencies

No new dependencies. End-state interface delta in
`Database.PostgreSQL.Migrate.Sql.Scanner` (surfaced through
`Database.PostgreSQL.Migrate.Sql` and the public `SqlError` re-export in
`Database.PostgreSQL.Migrate`):

```haskell
data SqlError
  = InvalidUtf8 { byteOffset :: !Int }
  | ByteOrderMarkFound                                         -- new
  | MisplacedDirective { directive :: !Text, lineNumber :: !Int } -- new
  | ...existing constructors unchanged...
```

`scanLeadingRegion` gains a line-count in its result type (internal only). Runner option
validation rejects `Just t` for `t <= 0` in both
`Database.PostgreSQL.Migrate.Runner.validateOptions` and
`Database.PostgreSQL.Migrate.Runner.Lock.applyStatementTimeout`. This plan is independent
of all other plans in the master plan; it shares the core package with
`docs/plans/22-align-verification-policy-handling-and-remove-quadratic-ledger-scans.md`
but touches disjoint modules.


Revision note (2026-07-13): Recorded completion of the leading-BOM milestone after the
core unit suite passed all 107 tests; the validator rejects only the editor-artifact byte
sequence at offset zero and preserves exact payload bytes.

Revision note (2026-07-13): Recorded completion of misplaced-directive rejection and
file-absolute scanner diagnostics after all 109 core unit tests passed; block comments and
ordinary trailing line comments remain unaffected.
