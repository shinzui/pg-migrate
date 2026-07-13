---
id: 20
slug: fix-embed-authoring-numbering-recompilation-tracking-and-byte-embedding
title: "Fix embed authoring numbering, recompilation tracking, and byte embedding"
kind: exec-plan
created_at: 2026-07-13T15:44:36Z
intention: intention_01kxe7gddde44r2d42xyh45c2c
master_plan: "docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md"
---

# Fix embed authoring numbering, recompilation tracking, and byte embedding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`pg-migrate-embed` compiles a component's ordered SQL migration files into the application
binary. A "manifest" is a plain-text file (one `.sql` filename per line) that fixes the
order; the Template Haskell splice `embedMigrationManifest` reads it at compile time and
embeds the exact bytes of every listed file. An "authoring" helper, `newMigration`, creates
the next numbered SQL file and appends it to the manifest. The 2026-07-13 audit found three
medium/low defects that undermine this package's core promises:

First, automatic numbering paints itself into a corner: `renderNextMigrationName` accepts a
rendered number whose digit count equals the zero-padded width (so after `09.sql` it
creates `10.sql`, without a leading zero), but `numericPrefix` — the inference that finds
the next number — requires a leading zero, so the very file the tool just created makes all
future automatic naming fail with `ExplicitMigrationNameRequired`, permanently. Second, the
splice registers the manifest and each listed file with `addDependentFile`, but nothing
watches the directory, so dropping a new `.sql` file in without editing the manifest does
not trigger recompilation — the `UnlistedSqlFiles` strictness check that exists precisely
for this mistake cannot fire, and a deployed binary silently lacks the migration. Third,
embedded bytes are spliced as one integer literal per byte (`ListE (LitE . IntegerL …)`),
which makes a multi-megabyte migration blow up compile time and memory. Two smaller items
ride along: a UTF-8 byte-order mark (BOM) at the start of a manifest produces the baffling
diagnostic `UnlistedSqlFiles ["0001.sql"]` for a file plainly listed on line 1, and
`newMigration`'s haddock claims an "atomic append" that is actually an unlocked
read-then-rename, unsafe under concurrent authoring.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1: numbering rollover fixed (`MigrationSequenceExhausted` at width boundary); regression tests. (2026-07-13T19:13:42Z)
- [x] Milestone 2: GHC 9.12 module-local recompilation plugin; add/remove regression plus independent listed-file tracking probe. (2026-07-13T19:56:50Z)
- [x] Milestone 3: byte embedding via `bytesPrimL`; equality test on embedded bytes; compile-time sanity check on a large fixture. (2026-07-13T19:21:55Z)
- [x] Milestone 4: BOM diagnostic, haddock honesty, clobber detection, platform note in docs. (2026-07-13T19:26:02Z)
- [x] Changelog updated with PVP impact and the GHC 9.12 plugin requirement. (2026-07-13T19:56:50Z)
- [x] `cabal test all` green (11 suites) after the completed recompilation fallback. (2026-07-13T19:59:22Z)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- GHC 9.12.4 ships `template-haskell-2.23.0.0`, where `bytesPrimL` and `mkBytes`
  live in `Language.Haskell.TH.Lib`, but `addDependentDirectory` does not exist.
  Registering the manifest directory with `addDependentFile` fails while hashing it with
  `withBinaryFile: inappropriate type (is a directory)`. Recursively registering the
  directory's current files cannot observe a future filename, and a Cabal
  `extra-source-files` glob did not invalidate the compiled consumer module. A Core plugin
  added from inside the splice was also too late for the next recompilation check; loading
  the same plugin from a module-local `OPTIONS_GHC -fplugin=...` pragma made GHC report
  `[Impure plugin forced recompilation]` and the real downstream harness rejected a newly
  added unlisted SQL file without any source or manifest edit.

- The old one-expression-per-byte representation could not compile the new 1,048,577-byte
  sanity fixture within 106.59 seconds and was interrupted. The `BytesPrimL` implementation
  compiled the entire forced unit build, including the same fixture, in 10.21 seconds; all
  31 tests then passed.


## Decision Log

- Decision: Keep the fixed-width, leading-zero naming convention and report
  `MigrationSequenceExhausted` when the next number no longer fits (boundary `>= width`),
  rather than relaxing `numericPrefix` to accept unpadded numbers.
  Rationale: Lexicographic filename order must equal numeric order for the embedded
  manifest to stay reviewable; unpadded names break that invariant.
  Date: 2026-07-13

- Decision: Reject a manifest BOM with a dedicated error rather than stripping it.
  Rationale: The package's contract is "exact bytes"; silently normalizing input
  contradicts the strictness the manifest checker enforces everywhere else.
  Date: 2026-07-13

- Decision: Correct the `newMigration` haddock to "exclusively creates the SQL file and
  atomically replaces the manifest; concurrent authoring is not supported", and add a
  post-rename re-read that fails with a new `AuthoringConcurrentModification` error when
  the just-appended entry is missing.
  Rationale: True multi-writer safety needs file locking, which is not worth the
  portability cost for a dev-time authoring tool; detecting the lost update converts silent
  corruption into a loud error.
  Date: 2026-07-13

- Decision: Reconstruct primitive byte literals with
  `Data.ByteString.Internal.unsafePackLenLiteral` rather than `fromForeignPtr`.
  Rationale: `BytesPrimL` compiles to a static `Addr#` literal, and
  `unsafePackLenLiteral :: Int -> Addr# -> ByteString` is the bytestring-0.12.2.0 API that
  preserves that storage without a per-byte AST or runtime copy. `fromForeignPtr` consumes
  a runtime `ForeignPtr` and therefore does not accept the generated literal.
  Date: 2026-07-13

- Decision: Support directory membership changes on GHC 9.12 with the exposed
  `Database.PostgreSQL.Migrate.Embed.RecompilePlugin` and require a module-local
  `OPTIONS_GHC -fplugin=...` pragma in embedding modules.
  Rationale: GHC 9.12 cannot fingerprint directories through Template Haskell, while the
  pragma loads the plugin early enough for `pluginRecompile = ForceRecompile` to rerun the
  strict membership audit. The cost is confined to the usually small module containing the
  splice. This protects real downstream builds, unlike forcing only the test command.
  Date: 2026-07-13


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Automatic authoring now stops at the fixed-width leading-zero boundary, primitive literals
make large exact-byte embedding practical, BOM-prefixed manifests have a named diagnostic,
and a simulated post-rename clobber is detected and cleaned up. GHC 9.12 embedding modules
can load the new module-local recompilation plugin so additions and removals rerun the
manifest audit; the real harness tests that path separately from ordinary listed-file
dependencies. The unit suite passes 33 tests, including all-byte and >1 MiB payload
coverage. All 11 workspace test suites, including PostgreSQL integration and the real
recompilation harness, pass with the implemented changes.


## Context and Orientation

Everything lives in `pg-migrate-embed/`:

- `src/Database/PostgreSQL/Migrate/Embed/Manifest.hs` — manifest parsing
  (`validateManifestLine` around lines 95-112), sibling-file strictness
  (`checkManifestFiles`, `UnlistedSqlFiles` around line 143), the TH splice
  `embedMigrationManifest` (lines 64-76, where `addDependentFile` calls live), and
  `entryExpression` (lines 171-180, the per-byte `ListE` embedding).
- `src/Database/PostgreSQL/Migrate/Embed/Authoring.hs` — `newMigration` (haddock at lines
  65-67), `renderNextMigrationName` (lines 109-117, the `>` vs `>=` boundary defect),
  `numericPrefix` (lines 119-128, the `'0' : _ : _` leading-zero requirement), the
  exclusive file creation via `System.Posix.IO` (lines ~170-177), and the manifest
  read/rename update (lines ~146-164, ~224).
- `src/Database/PostgreSQL/Migrate/Embed.hs` — the public facade;
  `src/Database/PostgreSQL/Migrate/Embed/Internal.hs` — internal re-exports.
- `src/Database/PostgreSQL/Migrate/Embed/RecompilePlugin.hs` — the GHC 9.12 no-op Core
  plugin whose recompilation policy reruns an embedding module's membership audit.
- Tests: `test/unit/` (`Test/Manifest.hs`, `Test/Authoring.hs`, `Test/Component.hs`) and a
  recompilation harness `test/recompilation/Main.hs` that builds the fixture app in
  `test/recompilation/fixture/` twice and asserts when rebuilds happen.

"Width" means the digit count of the numeric filename prefix: in a manifest whose entries
are `01-init.sql`, `02-users.sql`, the width is 2 and the sequence is exhausted at 99.
The toolchain is GHC 9.12.4 (see `docs/reference/compatibility.md`) with
`template-haskell-2.23.0.0`. `Language.Haskell.TH.Lib` provides
`bytesPrimL :: Bytes -> Lit` and `mkBytes :: ForeignPtr Word8 -> Word -> Word -> Bytes`; a
strict `ByteString`'s payload is reachable via `Data.ByteString.Internal.toForeignPtr`.
This compiler does not provide `addDependentDirectory`; its `addDependentFile` hashes file
contents and rejects a directory path. The documented manifest contract is
`docs/reference/manifest-v1.md`; the authoring guide is
`docs/user/manifest-authoring.md`.


## Plan of Work

Milestone 1 — numbering rollover. In `Authoring.hs` change `renderNextMigrationName`'s
boundary from `length rendered > width` to `length rendered >= width`, so the first number
that cannot keep a leading zero reports `MigrationSequenceExhausted width` instead of
creating a file the inference cannot read. Add unit tests in `test/unit/Test/Authoring.hs`:
with entries `01.sql` … `08.sql` the next automatic name is `09.sql`; with `09.sql` present
the result is `MigrationSequenceExhausted 2`; with width 4 and `0999.sql` present the
successor `1000` has four digits, loses its leading zero, and must be rejected with
`MigrationSequenceExhausted 4`. (The general rule: the last automatic name for width n is
the largest n-digit number that keeps a leading zero, e.g. `0999.sql` for width 4.) Also add the round-trip property: any
name produced by automatic numbering must itself be accepted by `numericPrefix`.

Milestone 2 — recompilation tracking. The supported GHC 9.12.4 toolchain lacks
`Language.Haskell.TH.Syntax.addDependentDirectory` and rejects directories passed to
`addDependentFile`. Provide an exposed no-op Core plugin whose `pluginRecompile` returns
`ForceRecompile`, and document a module-local `OPTIONS_GHC -fplugin=...` pragma beside each
embedding splice. Extend `test/recompilation/Main.hs` with two independent probes: the
plugin-enabled module must rebuild and reject a new unlisted `.sql` file without touching
another tracked file, while the plugin-free module must continue proving that edits to
listed files and the manifest are tracked by `addDependentFile`.

Milestone 3 — byte embedding. Replace `entryExpression`'s per-byte list with a
`bytesPrimL` literal: obtain the `ForeignPtr`, offset, and length from
`Data.ByteString.Internal.toForeignPtr`, build `LitE (bytesPrimL (mkBytes fptr (fromIntegral
off) (fromIntegral len)))`, and reconstruct at run time with
`Data.ByteString.Internal.fromForeignPtr` (or `unsafePackAddressLen` if the primitive
route proves simpler — pick one, record it in the Decision Log). The observable contract is
unchanged: the embedded `ByteString` is byte-identical to the file. Add a unit test
embedding a fixture containing NUL bytes, non-ASCII UTF-8, and all byte values 0-255,
asserting equality with a runtime file read. As a sanity check, add a >1 MB generated SQL
fixture to the recompilation harness (or a dedicated compile-time test) and note the
before/after compile time in Surprises & Discoveries.

Milestone 4 — polish. In `Manifest.hs`, detect a leading BOM (bytes `EF BB BF`, or
decoded `\xFEFF`) on the manifest's first line and fail with a new dedicated
`ManifestError` constructor (`ManifestByteOrderMark FilePath`) whose name identifies the
invisible character — replacing today's misleading `UnlistedSqlFiles`. (SQL file BOMs are
handled by the core scanner in
`docs/plans/21-harden-sql-validation-against-bom-misplaced-directives-and-wrong-diagnostics.md`;
this plan touches only the manifest.) In `Authoring.hs`, fix the `newMigration` haddock per
the Decision Log, add the post-rename verification that the appended entry is present
(new `AuthoringConcurrentModification` error), and note in `docs/user/manifest-authoring.md`
that authoring requires a POSIX platform (`System.Posix.IO`) while embedding itself is
portable. Update `pg-migrate-embed/CHANGELOG.md`, marking new error constructors and the
numbering boundary change.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/pg-migrate`.

```bash
cabal build pg-migrate-embed
cabal test pg-migrate-embed:pg-migrate-embed-test

# the recompilation harness drives real cabal builds of the fixture app
cabal test pg-migrate-embed:pg-migrate-embed-recompilation

cabal test all
nix fmt
```

Expected new test fragments:

```text
pg-migrate-embed-unit
  Authoring
    next name after 08 is 09:                        OK
    successor of 09 at width 2 is exhausted:         OK
    automatic names round-trip through numericPrefix: OK
  Manifest
    manifest BOM is rejected with a named error:      OK
    embedded bytes equal file bytes (0-255 fixture):  OK

pg-migrate-embed-recompilation
  new unlisted sql file forces rebuild and fails strictness: OK
```

Commit message shape:

```text
fix(embed): stop auto-numbering from exhausting its own inference

MasterPlan: docs/masterplans/4-remediate-pg-migrate-v1-audit-findings.md
ExecPlan: docs/plans/20-fix-embed-authoring-numbering-recompilation-tracking-and-byte-embedding.md
```


## Validation and Acceptance

Milestone 1: the three authoring tests pass; before the fix, the width-2 scenario creates
`10.sql` and the follow-up `newMigration` fails with `ExplicitMigrationNameRequired` — the
regression test must encode exactly that end-to-end sequence (create through `09`, then
observe `MigrationSequenceExhausted`). Milestone 2: the new recompilation case fails before
the change (build succeeds despite the unlisted file) and passes after (build fails with
`UnlistedSqlFiles`). Milestone 3: the byte-equality test passes and a full workspace build
(`cabal build all`) shows no regression; record the large-fixture compile-time comparison.
Milestone 4: a BOM-prefixed manifest fails with the new named error; two racing
`newMigration` calls (simulated in a unit test by mutating the manifest between read and
rename via a hook, or accepted as untestable and covered by the post-rename check's unit
test) surface `AuthoringConcurrentModification` instead of silently losing an entry.
Final: `cabal test all` passes, `nix fmt` clean, docs updated.


## Idempotence and Recovery

All edits are compile- and test-guarded and safe to repeat. The recompilation harness
creates and deletes files inside its own fixture copy; if a run is interrupted, delete the
fixture's scratch build directory and re-run. If `bytesPrimL` misbehaves on this GHC
(wrong bytes, linker issues), fall back to `StringPrimL` + `unsafePackAddressLen` (the
file-embed approach), record the evidence in Surprises & Discoveries, and keep the
byte-equality test as the arbiter.


## Interfaces and Dependencies

Adds the compiler's `ghc` library for the recompilation plugin alongside the existing
`template-haskell` and `bytestring` dependencies. End-state interface deltas in
`pg-migrate-embed`:

```haskell
-- Database.PostgreSQL.Migrate.Embed.Manifest
data ManifestError = ... | ManifestByteOrderMark !FilePath  -- new, first-line BOM

-- Database.PostgreSQL.Migrate.Embed.Authoring
data AuthoringError = ... | AuthoringConcurrentModification !FilePath  -- new

renderNextMigrationName :: Int -> Int -> Either AuthoringError Text
-- boundary: rendered length >= width  ==>  MigrationSequenceExhausted

-- Database.PostgreSQL.Migrate.Embed.RecompilePlugin
plugin :: GHC.Plugins.Plugin
```

`embedMigrationManifest` keeps its public signature and continues to register the manifest
and listed files. GHC 9.12 users add the documented module-local plugin pragma to make
untracked additions and removals rerun the splice. No other plan touches this package (see
the master plan's Dependency Graph).


Revision note (2026-07-13): Corrected the Template Haskell API assumptions after testing
against GHC 9.12.4, recorded the unsupported directory-dependency milestone, selected
`unsafePackLenLiteral` for static primitive bytes, and replaced the unit-suite target with
the repository's actual Cabal component name.

Revision note (2026-07-13): Recorded completion of the BOM, authoring-clobber, platform
documentation, and changelog work; updated the concrete public constructor shape and
captured the partial outcome while directory tracking remains open.

Revision note (2026-07-13): Recorded the passing 11-suite workspace validation. EP-4
remains In Progress solely because directory dependencies are unavailable on the supported
compiler.

Revision note (2026-07-13): Adopted and verified the GHC 9.12 module-local recompilation
plugin fallback, documented why recursive current-file registration is insufficient, and
completed the directory-membership milestone without raising the supported compiler.
