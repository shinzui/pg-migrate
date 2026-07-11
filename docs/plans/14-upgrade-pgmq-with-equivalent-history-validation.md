---
id: 14
slug: upgrade-pgmq-with-equivalent-history-validation
title: "Upgrade PGMQ with equivalent-history validation"
kind: exec-plan
created_at: 2026-07-10T15:50:25Z
intention: "intention_01kx6bkt8decx81jm8zbbjmgjk"
master_plan: "docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md"
---

# Upgrade PGMQ with equivalent-history validation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, `pgmq-migration` exports a native component named `pgmq` with one baseline
`0001-install-v1.11.0` migration and no `Hasql.Migration.MigrationCommand` surface. A fresh
database applies the exact vendored PGMQ 1.11 payload. An existing `schema_migrations`
ledger imports either the direct full-install row by exact payload or the two-step upgrade
route only after a read-only PGMQ 1.11 schema-contract validator succeeds. All PGMQ test
fixtures and consumers use the new plan, and runtime dependencies no longer include
`hasql-migration`.


## Progress

- [x] (2026-07-10 18:55 PDT) Selected EP-14 after EP-13 completion, resolved pgmq-hs and
  hasql-migration through `mori`, and confirmed the pgmq-hs worktree is clean.
- [ ] Milestone 1: Preserve the vendored PGMQ 1.11 payload in a one-entry native
  `pgmq` component.
- [ ] Milestone 2: Import the direct full-install hasql-migration row by verified MD5 and
  exact payload.
- [ ] Milestone 3: Prove the two-step equivalent route only with explicit opt-in and a
  read-only PGMQ 1.11 schema contract.
- [ ] Milestone 4: Rewire every fixture and consumer, remove runtime predecessor
  dependencies, update documentation, and pass the full validation matrix.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use one native v1.11 baseline rather than reproduce the predecessor's two
  upgrade scripts as target migrations.
  Rationale: Both historical routes establish the same supported schema; one target
  baseline gives fresh installs a simple append-only future while import handles evidence.
  Date: 2026-07-10

- Decision: Compare a checked native baseline copy byte-for-byte with vendored `pgmq.sql`.
  Rationale: The manifest requires a local basename, while the vendored upstream subtree
  remains the upstream source of truth; an equality guard prevents silent divergence.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Complete `docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md` first.
Execute in `mori` project `shinzui/pgmq-hs`, currently
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`. Run `mori show --full`
and preserve unrelated changes. The worktree was clean at plan creation and has no
`AGENTS.md`.

`pgmq-migration/src/Pgmq/Migration.hs` currently exposes `migrate`, `upgrade`, `validate`,
raw `MigrationCommand` lists, and predecessor result types. The fresh route embeds
`vendor/pgmq/pgmq-extension/sql/pgmq.sql` as `pgmq_v1.11.0`. The incremental route embeds
`pgmq--1.10.0--1.10.1.sql` and `pgmq--1.10.1--1.11.0.sql` under two legacy names.
`hasql-migration` stores base64 MD5 in public `schema_migrations`. Tests and several
pgmq-hs packages call `Migration.migrate` through Hasql pools/connections.

The direct target is `pgmq/0001-install-v1.11.0`. Its SQL bytes must equal the vendored
`pgmq.sql`. Direct history key is `pgmq_v1.11.0`. Alternative history requires both
`pgmq_v1.10.0_to_v1.10.1` and `pgmq_v1.10.1_to_v1.11.0` plus evidence key
`pgmq_schema_contract_v1.11`. Names alone never prove the alternative route.


## Plan of Work

Milestone 1 creates `pgmq-migration/migrations/manifest` containing
`0001-install-v1.11.0.sql` and a checked copy of the vendored SQL. Add a test comparing
bytes and SHA-256 with `vendor/.../pgmq.sql`; the vendoring/update procedure must refresh
the copy deliberately. Rewrite `Pgmq.Migration` to expose
`pgmqMigrations :: Either DefinitionError MigrationComponent`, component name `pgmq`, no
dependencies, and the manifest embedding. Remove public predecessor commands/types after
consumers migrate.

Milestone 2 adds `Pgmq.Migration.History.HasqlMigration`. Direct mapping selects exact
`pgmq_v1.11.0` source bytes, requires the adapter to verify stored base64 MD5, then uses
`SamePayload` against the native baseline SHA-256. Test correct MD5, altered bytes, altered
stored checksum, duplicate legacy rows, import idempotency, and no target action execution.

Milestone 3 implements `Pgmq.Migration.SchemaContract`. Create a read-only Hasql
transaction that inspects `pg_catalog` with fully qualified names and proves the PGMQ 1.11
contract required by this library: schema `pgmq`; tables `meta` and `topic_bindings` with
expected key columns/constraints; composite types `message_record`, `queue_record`, and
`metrics_result`; and the set/signatures of public functions consumed by pgmq-hs, including
queue CRUD/read/send/archive/delete, visibility, notification throttle, topic binding,
routing, and batch topic functions. Store the expected contract as checked Haskell data
derived/reviewed against vendored 1.11 SQL. Do not create queues or mutate data.

The alternative mapping uses `AllOf` for both verified MD5 rows and the successful
`StateVerified` contract evidence, then `EquivalentState` with explicit operator opt-in.
A missing function/type/table or failed MD5 rejects. This is focused compatibility
validation, not generic whole-database snapshot equality.

Milestone 4 rewires `pgmq-migration/test/Main.hs`, `pgmq-hasql/test/EphemeralDb.hs`,
`pgmq-effectful/test/EphemeralDb.hs`, `pgmq-config/test/EphemeralDb.hs`, and
`pgmq-bench/bench/BenchSetup.hs` to build a one-component plan and use the runner or test
support. Preserve all behavioral PGMQ tests. Remove predecessor wrapper modules and Cabal
dependencies only after `rg` finds no consumer. Update changelog and docs to explain fresh,
direct import, and alternative import routes.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`:

```bash
mori show --full
mori registry show shinzui/hasql-migration --full
git status --short --branch
nix develop
cabal test pgmq-migration:pgmq-migration-test
cabal test all
cabal build pgmq-migration --dry-run
```

Expected evidence:

```text
native baseline equals vendored pgmq.sql: PASS
direct full-install import: PASS
two-step import requires schema contract: PASS
all pgmq-hs behavioral suites: PASS
runtime closure excludes hasql-migration: PASS
```

Commits use:

```text
MasterPlan: docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md
ExecPlan: docs/plans/14-upgrade-pgmq-with-equivalent-history-validation.md
Intention: intention_01kx6bkt8decx81jm8zbbjmgjk
```


## Validation and Acceptance

The public component is `pgmq`, has one migration, and its checksum equals SHA-256 of
vendored `pgmq.sql`. Fresh apply installs PGMQ 1.11 and all existing queue/topic decoder and
behavior tests pass; rerun is AlreadyApplied. A direct predecessor fixture imports only
when MD5 and exact payload match.

The two-step fixture rejects with names/MD5 alone, succeeds with an explicit equivalent
policy and passing read-only schema contract, and rejects after dropping or changing one
required catalog object. Both routes produce one target Applied row plus complete audit
evidence and never execute target SQL during import. `rg` finds no runtime use of
`Hasql.Migration`, and the normal Cabal plan excludes `hasql-migration`.


## Idempotence and Recovery

All tests use temporary databases. The native baseline copy is updated only alongside a
vendored PGMQ version upgrade and reviewed equality test. Never rewrite
`0001-install-v1.11.0` after release; append a new native migration for later versions.
Keep old incremental source bytes available for import evidence even after runtime wrappers
are removed. Use a local project override for unreleased dependencies rather than commit
absolute paths.


## Interfaces and Dependencies

Depend on released `pg-migrate`, embed, hasql-migration adapter, and test support packages,
plus Hasql. Required interfaces are:

```haskell
pgmqMigrations :: Either DefinitionError MigrationComponent
pgmqHasqlMigrationMappings :: AlternativeHistoryPolicy -> Either HistoryDefinitionError (NonEmpty HistoryMapping)
pgmqV1_11StateValidator :: StateValidator
```

The policy value must explicitly select direct/equivalent rules; no default silently
accepts equivalent history.


## Revision Note

2026-07-10: Started implementation after confirming the initiative prerequisite, locating
both the consumer and predecessor source through `mori`, and verifying a clean pgmq-hs
worktree.
