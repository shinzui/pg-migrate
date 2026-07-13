---
id: 19
slug: harden-import-adapter-parsing-audit-evidence-and-internal-totality
title: "Harden import adapter parsing, audit evidence, and internal totality"
kind: exec-plan
created_at: 2026-07-13T15:44:36Z
intention: intention_01kxe7gddde44r2d42xyh45c2c
master_plan: "docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md"
---

# Harden import adapter parsing, audit evidence, and internal totality

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

pg-migrate ships two "history import adapters" — optional packages that read a legacy
migration ledger (Codd's `sql_migrations` table, or hasql-migration's `schema_migrations`
table) and record those already-applied migrations in pg-migrate's own ledger without
re-executing them. The 2026-07-13 audit verified the adapters' checksum and verification
logic against the real predecessor sources and found no false-positive path, but it did
find one real operational bug and a cluster of audit-quality and robustness gaps.

The bug: the Codd adapter's `--source-lock-key` command-line reader parses hexadecimal and
decimal input directly at `Int64`, where Haskell's `fromInteger` silently wraps out-of-range
values (`0xFFFFFFFFFFFFFFFF` becomes `-1`), and its range guard compares an `Int64` against
`maxBound :: Int64` — a tautology. A mistyped key is accepted, the adapter "locks" an
unrelated advisory key, and the mutual exclusion against a still-running legacy Codd
wrapper — the entire purpose of the flag — is silently lost. After this plan, out-of-range
keys are rejected at parse time with a clear message.

The rest: the hasql-migration adapter's audit JSON omits which source table evidence came
from; `--strict-source` rejects unexpected manifest entries but silently accepts a selected
row missing from the manifest (downgrading it to weaker evidence); three error constructors
are dead code that misleads API consumers; two `Map.!` partial lookups in publicly reachable
internal paths can throw imprecise exceptions; the Codd no-manifest path attaches an
unverified checksum to `LedgerOnly` evidence that only an adapter-level gate keeps away from
payload verification; and the Codd unlock path discards a committed import report the same
way the core runner did (fixed for the core in
`docs/plans/18-preserve-durable-success-through-cleanup-failures-and-async-exceptions.md`).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-13 11:43 PDT) Milestone 1 implementation: lock-key reader parses through `Integer`, bounds-checks before conversion, and has boundary-value regression tests.
- [x] (2026-07-13 11:44 PDT) Milestone 1 validation: `cabal test pg-migrate-import-codd:pg-migrate-import-codd-test` passed all 23 tests, including all new bounds cases.
- [x] (2026-07-13 11:51 PDT) Milestone 2: audit details record the rendered source table; strict Codd manifests reject missing selected rows; dead constructors are removed; manifest/parser Haddocks are accurate; and Codd exposes `--allow-equivalent` parity. Both adapter unit and PostgreSQL integration suites pass (25 + 11 Codd tests; 14 + 6 hasql-migration tests).
- [x] (2026-07-13 11:58 PDT) Milestone 3: adapter source trees contain no `Map.!`; Codd ledger-only evidence carries no unverified checksum; and core rejects `SamePayload` evidence weaker than `SourceManifestVerified` with `HistoryPayloadEvidenceTooWeak`. Sequential validation passed 104 core, 25 Codd, and 14 hasql-migration unit tests.
- [x] (2026-07-13 12:08 PDT) Milestone 4: Codd source unlock observations append to `HistoryImportReport.cleanupIssues` after target cleanup observations, while primary failures retain `CoddUnlockFailed`. The 12-case PostgreSQL suite proves a committed report survives `pg_advisory_unlock` returning false.
- [x] (2026-07-13 12:14 PDT) Runbooks and all three affected package changelogs updated; `nix fmt` changed no files; `just acceptance` passed all 15 test groups, production dependency closure, and the PostgreSQL 17 version gate.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Observation: The Concrete Steps named non-existent `pg-migrate-import-codd-unit` and
  `pg-migrate-import-hasql-migration-unit` Cabal components; the package files expose
  `pg-migrate-import-codd-test` and `pg-migrate-import-hasql-migration-test`.
  Evidence: Cabal reported `[Cabal-7131] Unknown target` and suggested the real component;
  `rg '^test-suite'` in both package files confirmed the names.

- Observation: Independent `cabal test` processes cannot safely rebuild the same local
  package in parallel against one `dist-newstyle` directory.
  Evidence: concurrent core, Codd, and hasql-migration runs raced while renaming
  `History/Types.o.tmp`; the hasql-migration run completed, while the other two exited with
  `[Cabal-7125]`. Validation runs are therefore sequential for the remainder of this plan.

- Observation: `pg-migrate-cli` has no history-import error renderer or error golden. It
  renders only successful `HistoryImportReport` values; adapter applications own their
  `CoddImportError` or `HasqlMigrationImportError` failure output.
  Evidence: `renderHistoryImportJson` accepts a report rather than an `Either`, and the
  only history-import golden is the successful `test/golden/json/import.json` fixture.

- Observation: A Codd-compatible PostgreSQL view can deterministically exercise the
  lost-report branch by calling `pg_advisory_unlock` while its `applied_at` column is read.
  Evidence: the integration run emits PostgreSQL's expected "you don't own a lock"
  warning on wrapper cleanup, then returns `Right HistoryImportReport` with
  `[AdvisoryUnlockReturnedFalse]`; all 12 Codd integration cases pass.


## Decision Log

- Decision: Repurpose the currently-dead `CoddManifestEntryMissing` constructor for the
  strict-source gap (selected row absent from a provided manifest) instead of deleting it.
  Rationale: The constructor's name describes exactly the missing check; `--strict-source`'s
  help text ("Reject … unexpected manifest entry") already promises symmetry.
  Date: 2026-07-13

- Decision: Delete `EmptyCoddSelection` and `EmptyHasqlMigrationSelection` (never
  constructed anywhere in the workspace).
  Rationale: Dead error constructors force consumers to handle impossible cases;
  pre-release breaking change recorded in the changelogs.
  Date: 2026-07-13

- Decision: Enforce in core `validatePayload` that `SamePayload` checksums must come from
  evidence of strength `SourceManifestVerified` or stronger, with a new
  `HistoryValidationError` constructor, in addition to dropping the unverified checksum
  from the Codd no-manifest path.
  Rationale: Defense in depth — today only the adapter's `--confirm`/manifest gate stands
  between an unverified local file checksum and a `SamePayload` import; anyone composing
  `Database.PostgreSQL.Migrate.Internal.buildCoddEvidence`-style pieces bypasses it.
  Date: 2026-07-13

- Decision: Store hasql-migration's `source_table` audit detail using the same quoted
  schema-qualified rendering used to query the predecessor ledger.
  Rationale: The quoted form is unambiguous for identifiers containing spaces, dots, or
  quotes and proves exactly which validated relation supplied the evidence.
  Date: 2026-07-13

- Decision: Do not invent a new CLI history-error rendering API or golden for
  `HistoryPayloadEvidenceTooWeak`; rely on the existing derived `Show` representation at
  adapter-owned text boundaries.
  Rationale: The plan's request to update CLI JSON/text error tables assumed a contract
  that does not exist. Adding one would be new feature/API work outside this audit
  remediation and could not render the adapter-specific outer error types without
  reversing package dependencies.
  Date: 2026-07-13

- Decision: Reuse `HistoryImportReport.cleanupIssues` for Codd source-lock cleanup and
  append source observations after any target-runner observations.
  Rationale: EP-2 deliberately made successful import reports the common carrier for
  cleanup facts. Reuse preserves the public import return type, gives callers one ordered
  list, and avoids an adapter-only report wrapper.
  Date: 2026-07-13

- Decision: Retain the public positional shape of `CoddUnlockFailed`, but document both
  optional error slots and construct it only when no successful import report can carry
  cleanup data.
  Rationale: The first slot preserves a primary source/import failure; the second
  distinguishes a session error from `pg_advisory_unlock` returning false. This is the
  smallest compatible application of EP-2's success-versus-failure contract.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

All four milestones are complete. Codd lock keys now reject signed-64-bit overflow before
conversion. Strict Codd selections and manifests agree symmetrically, while partial
manifests remain available for state-equivalent imports. Both adapter parsers accurately
describe their reserved plan argument, Codd exposes equivalent-history opt-in parity, and
impossible selection errors are gone. Hasql-migration evidence identifies its exact quoted
source table and all adapter source paths use total payload lookups.

Core `SamePayload` validation now requires evidence at least as strong as
`SourceManifestVerified`; Codd ledger-only evidence carries no unverified checksum. A real
PostgreSQL regression proves that a source unlock failure after target commit returns the
complete `HistoryImportReport` with an ordered cleanup observation instead of discarding
it. The implementation deliberately did not add a new CLI history-error API because the
existing CLI contract renders only successful import reports and adapter applications own
their outer error types.

Validation passed `nix fmt`, all 15 acceptance groups, production dependency closure, and
the PostgreSQL 17 gate. The main implementation lesson is operational: run Cabal commands
sequentially when they rebuild a shared local package, because independent processes race
inside one `dist-newstyle` tree.


## Context and Orientation

The two adapters are separate cabal packages. `pg-migrate-import-codd` has modules under
`pg-migrate-import-codd/src/Database/PostgreSQL/Migrate/History/Codd/`: `Types.hs`
(commands, errors, `CoddManifest`), `Parser.hs` (optparse-applicative parser including
`lockKeyReader`, lines 46-56), `Manifest.hs` (migrations.lock parsing), `Ledger.hs` (source
table detection, column-shape validation against Codd schema versions V1–V5, source
advisory lock via `withLockedCoddHistory`, lines 46-56 for unlock), and `Import.hs`
(evidence building; the no-manifest checksum at lines 132-149, strict-source checks at
117-124). `pg-migrate-import-hasql-migration` mirrors this layout under
`pg-migrate-import-hasql-migration/src/Database/PostgreSQL/Migrate/History/HasqlMigration/`
(`Types.hs`, `Parser.hs`, `Ledger.hs` — MD5/Base64 checksum verification and a `Map.!` at
line ~72 — and `Import.hs`, whose `rowDetails` at lines 103-104 binds its `QualifiedTable`
argument as `_`, and which has `Map.!`-equivalent partial lookups at lines ~67 and ~98).
Each package also exposes a small `…/Internal.hs` facade.

"Evidence" is the core import model from
`pg-migrate/src/Database/PostgreSQL/Migrate/History/Types.hs`: an `ImportEvidence` record
with an `EvidenceStrength` (`LedgerOnly < SourceManifestVerified <
SourceLedgerChecksumVerified < StateVerified`) and an optional `payloadChecksum`. A
`HistoryMapping` declares, per target migration, a `PayloadRelation`: `SamePayload key`
(the source bytes are byte-identical to the target migration, proven by checksum equality
in `validatePayload`, `pg-migrate/src/Database/PostgreSQL/Migrate/History/Validation.hs`
lines 186-214) or `EquivalentState`. `HistoryValidationError` (History/Types.hs lines
167-178) is where a new strength-gate constructor goes.

Integration tests: `pg-migrate-import-codd/test/integration/Main.hs` and
`pg-migrate-import-hasql-migration/test/integration/Main.hs` (need PostgreSQL via
`process-compose up`); unit tests under each package's `test/unit/`. The operations
runbooks are `docs/operations/codd-import.md` and
`docs/operations/hasql-migration-import.md`.


## Plan of Work

Milestone 1 — lock-key parsing. Rewrite `lockKeyReader` in
`pg-migrate-import-codd/src/Database/PostgreSQL/Migrate/History/Codd/Parser.hs` to parse at
`Integer` and bounds-check before converting: read the hexadecimal branch with
`Numeric.readHex :: [(Integer, String)]` and the decimal branch with
`Read.readMaybe :: Maybe Integer`, accept only values within
`[toInteger (minBound :: Int64), toInteger (maxBound :: Int64)]`, then `fromInteger`.
Extend `pg-migrate-import-codd/test/unit/Test/Parser.hs` with: max bound accepted
(`0x7FFFFFFFFFFFFFFF`), one past max rejected (`0x8000000000000000`), the wrap poster-child
rejected (`0xFFFFFFFFFFFFFFFF`, currently accepted as `-1`), negative decimal accepted
(advisory keys are signed), and out-of-range decimal (`18446744073709551615`) rejected.

Milestone 2 — audit completeness and symmetry. In the hasql-migration adapter's
`Import.hs`, make `rowDetails` use its `QualifiedTable` argument: add a
`"source_table"` field (schema-qualified text) to the details object so audits from
different `--source-table` values are distinguishable; update the evidence-shape assertions
in `test/unit/Test/Evidence.hs` and the integration goldens if any. In the Codd adapter's
`Import.hs`, add the strict-source symmetry check: when `--strict-source` is set and a
manifest is provided, every selected source row must appear in the manifest, otherwise fail
with `CoddManifestEntryMissing <filename>` (constructor exists in `Types.hs` line ~103,
currently never constructed). Delete `EmptyCoddSelection` and
`EmptyHasqlMigrationSelection` from the two `Types.hs` files and fix all compile fallout.
Fix the `CoddManifest` haddock (`Types.hs` lines 44-47) to say it is an unordered map from
filename to expected checksum, distinct from the selection. Fix both adapters' parser
haddocks that claim "target-aware" while ignoring the plan parameter (state the parameter
is reserved). Add `--allow-equivalent` to `CoddImportCommand` (`Types.hs` lines 114-124 and
`Parser.hs`), plumbed to the core `EquivalentHistoryPolicy` exactly as the hasql-migration
parser already does, so both CLIs expose the same policy surface.

Milestone 3 — totality and evidence strength. Replace the `Map.!` lookups
(hasql-migration `Ledger.hs` line ~72, `Import.hs` lines ~67 and ~98) with total lookups
returning the existing `MissingHasqlMigrationPayload` error. In the Codd adapter's
`Import.hs` no-manifest branch (lines 132-149), stop attaching the locally computed,
unverified checksum to `LedgerOnly` evidence — set `payloadChecksum = Nothing` there and
keep checksums only on manifest-verified evidence. In core
`pg-migrate/src/Database/PostgreSQL/Migrate/History/Validation.hs` `validatePayload`,
after resolving the `SamePayload` evidence, reject evidence whose `strength` is
`LedgerOnly` with a new `HistoryValidationError` constructor
`HistoryPayloadEvidenceTooWeak !MigrationId !EvidenceKey` (add to
`pg-migrate/src/Database/PostgreSQL/Migrate/History/Types.hs`, export via
`Database.PostgreSQL.Migrate` and `Database.PostgreSQL.Migrate.History`). The CLI has no
history-import error renderer; adapter-owned failure output receives the constructor
through `HistoryImportValidationFailed`. Add a core unit test in
`pg-migrate/test/unit/Test/History.hs`: a `SamePayload` mapping whose only satisfying
evidence is `ledgerOnlyEvidence` with a matching checksum must now fail with the new error
instead of importing.

Milestone 4 — unlock preserves success. The Codd source-lock bracket in `Ledger.hs`
returns its typed primary result separately from internal source-unlock observations. On a
successful target import, `Import.hs` maps those observations to core `CleanupIssue`
values and appends them to `HistoryImportReport.cleanupIssues`. On a primary failure,
`CoddUnlockFailed` retains the original error and the unlock diagnostic. Plain source reads
retain their prior behavior of treating unlock failure as `CoddUnlockFailed`, because they
have no successful report capable of carrying cleanup data.

Update `docs/operations/codd-import.md` (new flag, strict-source symmetry, lock-key
validation) and `docs/operations/hasql-migration-import.md` (source-table audit field), and
both package changelogs, marking constructor deletions as breaking.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/pg-migrate`.

```bash
cabal build pg-migrate-import-codd pg-migrate-import-hasql-migration
cabal test pg-migrate-import-codd:pg-migrate-import-codd-test
cabal test pg-migrate-import-hasql-migration:pg-migrate-import-hasql-migration-test

# integration (requires PostgreSQL 17/18)
process-compose up --detached
cabal test pg-migrate-import-codd
cabal test pg-migrate-import-hasql-migration

cabal test all
nix fmt
```

Expected new unit-test fragment after Milestone 1:

```text
pg-migrate-import-codd-test
  Parser
    accepts 0x7FFFFFFFFFFFFFFF:               OK
    rejects 0x8000000000000000:               OK
    rejects 0xFFFFFFFFFFFFFFFF (wrap guard):  OK
    rejects out-of-range decimal:             OK
```

Commit message shape:

```text
fix(import-codd): reject out-of-range source lock keys at parse time

MasterPlan: docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md
ExecPlan: docs/plans/19-harden-import-adapter-parsing-audit-evidence-and-internal-totality.md
Intention: intention_01kxe7gddde44r2d42xyh45c2c
```


## Validation and Acceptance

Milestone 1: the five boundary-value parser tests pass; before the fix,
`0xFFFFFFFFFFFFFFFF` parses to `-1` (reproduce in `cabal repl pg-migrate-import-codd` with
`Numeric.readHex "FFFFFFFFFFFFFFFF" :: [(Int64, String)]` → `[(-1,"")]`). Milestone 2: the
hasql-migration integration test's stored audit evidence contains `"source_table"`; a
strict-source Codd import whose manifest omits a selected file fails with
`CoddManifestEntryMissing` naming that file (new integration case), while the same import
without `--strict-source` still succeeds with ledger-only evidence (existing mixed-evidence
case must keep passing). Milestone 3: the new core unit test proves a `LedgerOnly`
`SamePayload` import fails with `HistoryPayloadEvidenceTooWeak`; grep confirms no `Map.!`
remains under either adapter's `src/`. Milestone 4: an integration case that releases the
source lock while its row is read, forcing wrapper cleanup to return false after target
commit, still returns the import report. Full
acceptance: `cabal test all` passes and both runbooks document the new behavior.


## Idempotence and Recovery

All edits are compile-guarded; constructor deletions surface every consumer as a compile
error. Integration tests run against disposable databases (ephemeral-pg or the
process-compose instance) and are safe to re-run. The core change in Milestone 3 is
compile-guarded across every downstream package. The CLI has no history-import error
renderer, so no golden regeneration is expected or required for the new validation
constructor.


## Interfaces and Dependencies

No new dependencies. End-state interface deltas:

```haskell
-- pg-migrate-import-codd .../Codd/Parser.hs
lockKeyReader :: ReadM Int64   -- parses via Integer, rejects out-of-range

-- pg-migrate .../History/Types.hs (re-exported by Database.PostgreSQL.Migrate)
data HistoryValidationError
  = ...
  | HistoryPayloadEvidenceTooWeak !MigrationId !EvidenceKey

-- pg-migrate-import-hasql-migration .../HasqlMigration/Import.hs
rowDetails :: QualifiedTable -> HasqlMigrationRow -> Aeson.Value  -- table now recorded
```

`CoddImportCommand` gains an `allowEquivalent` field mirroring the hasql-migration command.
This plan consumes (but does not define) the success-preserving cleanup pattern from
`docs/plans/18-preserve-durable-success-through-cleanup-failures-and-async-exceptions.md`.

Internally, `withLockedCoddHistory` returns the primary result and source-unlock
observations separately. `importCoddHistoryWithValidators` appends mapped observations to
the existing report's `cleanupIssues`; no adapter-specific report wrapper is introduced.


Revision note (2026-07-13): Recorded completed implementation, corrected stale Cabal
component names, aligned the milestone prose with the landed cleanup and CLI contracts,
and captured full acceptance evidence.
