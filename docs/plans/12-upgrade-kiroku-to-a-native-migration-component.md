---
id: 12
slug: upgrade-kiroku-to-a-native-migration-component
title: "Upgrade Kiroku to a native migration component"
kind: exec-plan
created_at: 2026-07-10T15:50:25Z
intention: "intention_01kx6bkt8decx81jm8zbbjmgjk"
master_plan: "docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md"
---

# Upgrade Kiroku to a native migration component

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, `kiroku-store-migrations` exports one native component named `kiroku`
instead of Codd migration actions and runner wrappers. Its seven SQL files are ordered by a
tracked manifest and embedded with `pg-migrate-embed`; a checked-in mapping imports the
existing Codd ledger without replay. The executable mounts `pg-migrate-cli`, runtime
library dependencies no longer include Codd or `postgresql-simple`, and current schema
snapshot checks remain isolated in test-only legacy targets. Fresh and imported ephemeral
databases both pass strict plan verification and Kiroku store behavior tests.


## Progress

- [ ] (2026-07-11T00:28:25Z) Milestone 1: update package dependencies and establish the
  native manifest/source layout while preserving legacy evidence.
- [ ] Milestone 2: expose the native Kiroku component and authoring path.
- [ ] Milestone 3: add the checked-in Codd history mapping and import proofs.
- [ ] Milestone 4: migrate the executable and database behavior tests.
- [ ] Milestone 5: update documentation, remove predecessor runtime dependencies, and run
  final validation.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Rename the target history to `0001` through `0007` while retaining old Codd
  filenames only as source-evidence keys.
  Rationale: Native identity is component-local and manifest-ordered; explicit mapping
  preserves already-applied history without imposing timestamp names on future entries.
  Date: 2026-07-10

- Decision: Retain Codd expected-schema support only in a separately buildable test/tool
  target during transition.
  Rationale: Snapshot drift checks are useful but orthogonal to runtime migration execution
  and must not keep Codd in the primary library closure.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Complete `docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md` first.
Execute this plan in the `mori` project `shinzui/kiroku`, currently located at
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Run `mori show --full` there before
editing and preserve unrelated worktree changes. The repository has no `AGENTS.md` at plan
creation. Its `mori.dhall` is stale with respect to the existing
`kiroku-store-migrations` package, so trust the checked-in Cabal project and update Mori
metadata as a separate, explicit maintenance edit if needed.

`kiroku-store-migrations/src/Kiroku/Store/Migrations.hs` currently embeds the entire
`sql-migrations/` directory with `file-embed`, exposes Codd parsed actions, ledger/status
wrappers, and a `MigrationSet`. `app/Main.hs` mounts `Codd.Extras.Cli`. The package contains
seven timestamped SQL files, `migrations.lock` with SHA-256, Codd expected-schema data for
PostgreSQL 18, and Hspec integration tests using `ephemeral-pg`. Runtime build-depends
currently include `codd`, `codd-extras`, `file-embed`, and `postgresql-simple`.

The old-to-new mapping is fixed as follows: bootstrap becomes
`0001-kiroku-bootstrap.sql`; dead letters becomes
`0002-add-subscription-dead-letters.sql`; append guard becomes
`0003-notify-trigger-append-guard.sql`; dead-letter index becomes
`0004-dead-letters-event-id-index.sql`; index hygiene becomes
`0005-index-hygiene-and-streams-fillfactor.sql`; stream length becomes
`0006-stream-name-length-check.sql`; and truncate-before becomes
`0007-stream-truncate-before.sql`. Preserve each file's exact bytes.


## Plan of Work

Milestone 1 updates package dependencies and native source layout. Add bounded released
dependencies on `pg-migrate`, `pg-migrate-embed`, `pg-migrate-cli`,
`pg-migrate-import-codd`, and test support only where used. Under
`kiroku-store-migrations/migrations/`, create `manifest` and the seven native basenames in
the exact order above, preserving SQL bytes. Keep legacy names and their SHA-256 manifest
as import fixtures or mapping data; do not make two runtime copies authoritative. Add a
test that native bytes equal selected legacy source bytes and the existing lock hashes.

Milestone 2 rewrites `src/Kiroku/Store/Migrations.hs` to expose only safe native values,
chiefly `kirokuMigrations :: Either DefinitionError MigrationComponent`, constructed with
`migrationComponentFromEmbeddedSql "kiroku" mempty $(embedMigrationManifest
"migrations/manifest")`. Replace `Kiroku.Store.Migrations.New` with a thin use of the
native authoring helper. Remove Codd ledger/status/runner types from the primary public
surface. Update Cabal extra-source-files so sdists contain manifest and SQL.

Milestone 3 adds `src/Kiroku/Store/Migrations/History/Codd.hs`. Define explicit evidence
keys for all seven timestamped names and mappings to new IDs. Load exact old payload bytes
and `migrations.lock`, produce `SourceManifestVerified`, and require the adapter's Codd
confirmation policy. Export checked-in mapping data so Keiro can combine it with its own
shared-ledger mapping. Add current Codd V5 and legacy `codd_schema` fixtures, partial-row
rejection, idempotent import, and audit assertions.

Milestone 4 rewrites `app/Main.hs` as a thin consumer: obtain connection configuration
through Kiroku's chosen policy, build the single-component plan, mount
`migrationCommandParser`, dispatch through the CLI handler, render, and choose exit code.
No Codd environment variable becomes mandatory. Replace migration tests with
`withMigratedDatabase`; retain behavioral assertions for schema placement, UUID defaults,
triggers, indexes, stream length, append/read, rerun, and concurrency. Keep expected-schema
generation/checking behind a legacy test/tool flag whose dependencies cannot enter the
normal library/executable closure.

Milestone 5 updates `README.md`, `docs/user/schema-migrations.md`, changelog, and consumer
references. Remove runtime Codd, `codd-extras`, `file-embed`, and
`postgresql-simple` dependencies once no primary module imports them. Run full Kiroku tests,
build the normal package set with the legacy snapshot flag disabled, and inspect its Cabal
plan for forbidden migration dependencies.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`:

```bash
mori show --full
mori registry show shinzui/pg-migrate --full
git status --short --branch
nix develop
cabal test kiroku-store-migrations:kiroku-store-migrations-test
cabal test kiroku-store:kiroku-store-test
```

Run the normal closure without the legacy expected-schema tool flag and inspect it:

```bash
cabal build kiroku-store-migrations -f-expected-schema-tool --dry-run
```

Expected migration evidence:

```text
fresh native Kiroku plan: PASS
Codd V5 import then strict verify: PASS
native bytes match seven legacy payloads: PASS
normal closure excludes Codd/postgresql-simple: PASS
```

Commits in the Kiroku repository use Conventional Commits and the central coordination
trailers:

```text
MasterPlan: docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md
ExecPlan: docs/plans/12-upgrade-kiroku-to-a-native-migration-component.md
Intention: intention_01kx6bkt8decx81jm8zbbjmgjk
```


## Validation and Acceptance

The public `kirokuMigrations` builds component `kiroku` with no dependencies and seven
ordered targets. A fresh temporary database applies all seven, supports the existing
append/read scenario, and reports AlreadyApplied on rerun. A Codd V5 fixture containing the
old seven filenames imports to the native IDs, strict verify succeeds, and `up` executes no
legacy SQL. A partial Codd row rejects.

Changing one native byte causes the existing legacy-manifest equality test and imported
checksum verification to fail. The executable help shows the standard CLI groups and no
mandatory `CODD_*` variables. The normal library/executable Cabal plan excludes Codd,
`codd-extras`, `postgresql-simple`, and test support; an explicitly selected legacy
snapshot target may retain them temporarily.


## Idempotence and Recovery

Renaming/copying history is safe only because import mappings preserve old identities and
tests prove bytes. Do not delete the old evidence mapping or lock file. Re-running fresh
and import tests uses throwaway databases. If a released dependency is unavailable, use a
local `cabal.project.local` path for development and do not commit an unstable absolute
path. Do not rewrite an applied SQL payload to fix a test; append a new native migration.


## Interfaces and Dependencies

Consume released public APIs from the first two MasterPlans. Required Kiroku interfaces are:

```haskell
kirokuMigrations :: Either DefinitionError MigrationComponent
kirokuCoddHistoryMappings :: NonEmpty HistoryMapping
kirokuMigrationPlan :: Either PlanError MigrationPlan
```

If the plan helper is omitted as trivial, the executable must still compose with
`migrationPlan (component :| [])`. The history mapping module may expose source payload and
selection builders but must not leak Codd library types.
