---
id: 13
slug: upgrade-keiro-and-compose-its-kiroku-dependency
title: "Upgrade Keiro and compose its Kiroku dependency"
kind: exec-plan
created_at: 2026-07-10T15:50:25Z
intention: "intention_01kx6bkt8decx81jm8zbbjmgjk"
master_plan: "docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md"
---

# Upgrade Keiro and compose its Kiroku dependency

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, `keiro-migrations` exports a native component named `keiro` whose declared
dependency is `kiroku`; it no longer re-embeds Kiroku SQL or exposes a combined Codd
migration-set API. The final executable composes concrete Kiroku and Keiro components in
that order. Sixteen native manifest entries and explicit Codd mappings import the existing
shared ledger without replay. Fresh and imported tests prove both schemas, dependency
validation, strict verification, and existing Keiro behavior while runtime migration
stanzas shed Codd and `postgresql-simple`.


## Progress

- [x] (2026-07-10 18:23 PDT) Verified EP-12 complete, selected EP-13 as the next
  implementable child plan, located Keiro and Kiroku through `mori`, and preserved the
  pre-existing `.seihou/manifest.json` and `docs/assets/` worktree changes.
- [x] (2026-07-10 18:52 PDT) Milestone 1: Preserved all sixteen SQL payloads byte for
  byte under `keiro-migrations/migrations/manifest` and exported component `keiro` with
  dependency set `{kiroku}`.
- [x] (2026-07-10 18:52 PDT) Milestone 2: Added `frameworkMigrationPlan`, rejected
  missing/reversed Kiroku composition in tests, and replaced the executable with the
  standard `pg-migrate` command surface.
- [x] (2026-07-10 18:52 PDT) Milestone 3: Added one combined source config and 23 exact
  Kiroku/Keiro mappings; V5 and legacy-ledger imports, idempotency, strict extras,
  partial rows, verification, and no-replay behavior pass.
- [x] (2026-07-10 18:52 PDT) Milestone 4: Rewired Keiro's shared template fixture to the
  native plan, passed fresh/rerun/concurrency tests, and retained all 19 Codd snapshot,
  remediation, and fixup examples behind `legacy-codd-tools`.
- [x] (2026-07-10 18:52 PDT) Milestone 5: Released the source package version as
  `0.2.0.0`, updated API and operator documentation, removed predecessor packages from
  normal stanzas, passed `cabal check`, `nix fmt`, the full enabled Cabal test matrix,
  and committed Keiro as `f8fcea7`.


## Surprises & Discoveries

- Observation: The completed EP-12 Kiroku revision `15e6fe2` is one commit ahead of its
  GitHub remote. Keiro pins that exact revision but local validation must temporarily
  omit the source-repository stanza and use the ignored `cabal.project.local` override.
  Evidence: Cabal's remote fetch failed with `upload-pack: not our ref
  15e6fe27c18f6fe6e7eaa72470611dda9dd36821`; the same build and full tests passed against
  the `mori`-resolved local checkout.

- Observation: The old Codd transition suite can remain executable without copying
  Kiroku SQL. Its opt-in module reconstructs the legacy Kiroku migration set from
  `kirokuLegacyMigrationNames` and `kirokuCoddSourcePayloads`, the evidence boundary EP-12
  intentionally exported.

- Observation: Keiro's compile-failure replay-safety probe imported transitive packages
  directly and failed early once multiple Kiroku package instances were present. Reducing
  the type-only fixture to import only `Keiro` restored its intended assertion on
  `ValidatedEventStream`; the targeted three-example suite and the full 280-example Keiro
  suite then passed.


## Decision Log

- Decision: Make `keiro` depend on component name `kiroku` and import Kiroku's exported
  component rather than its SQL files.
  Rationale: Package ownership and component-level dependencies are the central design
  rule; copying Kiroku history would recreate the coupling being removed.
  Date: 2026-07-10

- Decision: Import a combined Kiroku/Keiro Codd ledger with one combined generic import.
  Rationale: Every selected shared-ledger row must participate in one mapping, and target
  prefixes for both components should commit atomically.
  Date: 2026-07-10

- Decision: Keep Codd snapshot, remediation, fixup, and timestamp-scaffolding code behind
  the manual `legacy-codd-tools` flag while leaving exact Codd history import in the
  normal native library.
  Rationale: Operators still need transition evidence, but normal migration execution and
  shared test provisioning must not pull Codd, `codd-extras`, or `file-embed`; the Hasql
  adapter itself has no dependency on those predecessor runners.
  Date: 2026-07-10

- Decision: Pin Keiro to the exact EP-12 Kiroku commit and record remote publication as an
  EP-15 staging prerequisite instead of weakening the dependency to the old remote
  revision.
  Rationale: The old revision does not export the native component/evidence API, while a
  local path in committed project metadata would not be portable.
  Date: 2026-07-10


## Outcomes & Retrospective

Keiro now owns a sixteen-entry native component and composes the concrete seven-entry
Kiroku component before it. All 23 historical Codd rows import atomically into the
`pgmigrate` ledger from both supported shared-ledger schema names; strict verification and
subsequent `up` prove that no legacy SQL replays. Fresh and concurrent native applies,
the full Keiro framework matrix, the Jitsurei behavior suite, and every other enabled
workspace test pass.

The normal library, executable, and test-support stanzas no longer depend on `codd`,
`codd-extras`, `file-embed`, or `postgresql-simple`. The checked expected-schema,
remediation, and sentinel-fixup path remains demonstrably usable through a separately
enabled 19-example suite. Before EP-15 stages exact artifacts, publish the already
committed Kiroku revision so Keiro's immutable source pin is fetchable outside this local
workspace.


## Context and Orientation

Complete `docs/plans/12-upgrade-kiroku-to-a-native-migration-component.md` first. Execute
this plan in `mori` project `shinzui/keiro`, currently
`/Users/shinzui/Keikaku/bokuno/keiro`. Run `mori show --full` and preserve the existing
user modification to `.seihou/manifest.json`. No `AGENTS.md` was present at plan creation.

`keiro-migrations/src/Keiro/Migrations.hs` currently embeds sixteen timestamped SQL files,
constructs `frameworkMigrationSets` containing copied Kiroku and Keiro `MigrationSet`s,
and exposes combined Codd runners/status. `app/Main.hs` uses `Codd.Extras.Cli`; tests use
`ephemeral-pg`, Codd expected-schema snapshots, the shared Codd ledger, and legacy
remediation/fixup scripts. The primary package depends on Codd, `codd-extras`, file-embed,
and `kiroku-store-migrations`.

Map timestamps in current order to: `0001-keiro-bootstrap`, `0002-keiro-outbox`,
`0003-keiro-inbox`, `0004-keiro-timer-recovery`, `0005-keiro-workflow-steps`,
`0006-keiro-awakeables`, `0007-keiro-workflow-children`,
`0008-keiro-workflow-generation`, `0009-keiro-subscription-shards`,
`0010-keiro-messaging-crash-recovery`, `0011-keiro-workflows-instances`,
`0012-keiro-workflow-gc-index`, `0013-keiro-workflows-wake-after`,
`0014-keiro-projection-dedup`, `0015-keiro-outbox-claim-order-index`, and
`0016-keiro-inbox-drop-received-idx`, each with `.sql`. The manifest owns this order.


## Plan of Work

Milestone 1 creates `keiro-migrations/migrations/manifest` and the sixteen names above,
preserving exact SQL bytes and retaining timestamp names/`migrations.lock` only as legacy
evidence. Rewrite `Keiro.Migrations` so
`keiroMigrations :: Either DefinitionError MigrationComponent` calls
`migrationComponentFromEmbeddedSql "keiro" (Set.singleton "kiroku")` over the embedded
manifest. Remove `allKeiroMigrations`, `frameworkMigrationSets`, copied
`kirokuMigrationSet`, and Codd run/status wrappers from the primary API.

Milestone 2 provides explicit composition. Add
`frameworkMigrationPlan :: MigrationComponent -> MigrationComponent -> Either PlanError
MigrationPlan`, implemented with `migrationPlan (kiroku :| [keiro])`. The executable obtains
`kirokuMigrations` from the released Kiroku package, obtains `keiroMigrations`, fails
definition/plan errors structurally, and mounts the standard CLI. Tests prove missing
Kiroku and reversed order fail, while the correct plan preserves two component blocks.

Milestone 3 adds `Keiro.Migrations.History.Codd` with mappings for all sixteen old names.
Combine those mappings with `kirokuCoddHistoryMappings` delivered by
`docs/plans/12-upgrade-kiroku-to-a-native-migration-component.md` when importing a shared
ledger. Verify exact payloads against Keiro's lock file, select all relevant Kiroku/Keiro
rows, and use one Codd adapter call/HistoryImport so both target prefixes and audit rows
commit atomically. Test V5 and supported legacy shapes, partial failures, unselected rows,
idempotency, and no target action execution.

Milestone 4 rewires the existing test suite. Use native fresh plans and
`pg-migrate-test-support` for table placement, Kiroku-before-Keiro behavior, strict plan
verification, concurrency, and schema functionality. Keep checked Codd expected-schema,
remediation, and sentinel-ledger fixup tests behind a legacy transition target until a
separate decision retires them; normal runtime code does not import those modules. Confirm
the native manifests match all legacy payload bytes before removing file-embed.

Milestone 5 updates Cabal bounds, `cabal.project`, README, migration docs, changelog, and
all references found by `rg`. Remove Codd, `codd-extras`, file-embed, and
`postgresql-simple` from normal library/executable dependencies. Keep Kiroku as a package
dependency because plan composition consumes its component, not because Keiro embeds its
files. Run all Keiro migration and framework tests.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/keiro`:

```bash
mori show --full
mori registry show shinzui/kiroku --full
git status --short --branch
nix develop
cabal test keiro-migrations:keiro-migrations-test
cabal test all
```

Inspect the normal migration closure with any legacy snapshot/tool flag disabled as defined
by the implementation:

```bash
cabal build keiro-migrations --dry-run
```

Expected evidence:

```text
fresh Kiroku then Keiro native plan: PASS
combined Codd import then strict verify: PASS
missing/reversed Kiroku dependency rejected: PASS
normal closure excludes Codd/postgresql-simple: PASS
```

Commits use:

```text
MasterPlan: docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md
ExecPlan: docs/plans/13-upgrade-keiro-and-compose-its-kiroku-dependency.md
Intention: intention_01kx6bkt8decx81jm8zbbjmgjk
```


## Validation and Acceptance

The public Keiro component contains exactly sixteen ordered migrations and dependency set
`{kiroku}`. Building a plan without Kiroku or with Keiro first returns structured
`PlanError`; composing Kiroku then Keiro succeeds. Fresh apply creates both schemas and all
existing behavioral tests pass. Rerun reports all AlreadyApplied.

A combined Codd fixture imports seven Kiroku and sixteen Keiro rows atomically, strict
verify succeeds, and `up` runs no legacy target SQL. A single partial row or checksum/source
manifest mismatch leaves neither component imported. The main executable help uses standard
commands and no mandatory Codd environment. Normal closure excludes predecessor packages;
legacy snapshot tools remain separately selectable only.


## Idempotence and Recovery

All fresh/import tests use temporary databases. Preserve remediation and ledger-fixup
artifacts until production cutover proves no database needs them. Never rewrite one of the
sixteen applied payloads; append a native migration for corrections. Do not discard the
unrelated dirty `.seihou/manifest.json`. Use a local project override for unreleased
development packages rather than committing absolute paths.


## Interfaces and Dependencies

Consume native APIs from Kiroku and all released pg-migrate packages. Required interfaces:

```haskell
keiroMigrations :: Either DefinitionError MigrationComponent
keiroCoddHistoryMappings :: NonEmpty HistoryMapping
frameworkMigrationPlan :: MigrationComponent -> MigrationComponent -> Either PlanError MigrationPlan
```

The first argument is the concrete Kiroku component and the second is Keiro. Do not expose
a migration-set abstraction or accept parsed Codd actions.


## Revision Note

2026-07-10: Started implementation after proving EP-12 complete, resolving both consumer
repositories through `mori`, and recording the unrelated Keiro worktree paths that must be
preserved.

2026-07-10: Completed all five milestones in Keiro commit `f8fcea7`; recorded byte-level
manifest preservation, composed-plan and shared-ledger import evidence, normal and legacy
test results, predecessor-closure removal, documentation changes, and the Kiroku remote
publication gate for staging.
