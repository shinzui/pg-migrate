---
id: 3
slug: migrate-initial-ecosystem-to-pg-migrate
title: "Migrate initial ecosystem to pg-migrate"
kind: master-plan
created_at: 2026-07-10T15:50:25Z
intention: "intention_01kx6bkt8decx81jm8zbbjmgjk"
---

# Migrate initial ecosystem to pg-migrate

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, Kiroku, Keiro, and `pgmq-migration` export native
`MigrationComponent` values, their applications compose explicit plans, and existing
databases move to the `pgmigrate` ledger without replaying already-applied SQL. Fresh and
imported databases accept one new native append-only migration exactly once. Staging
copies pass strict verification, production cutovers happen in maintenance windows, and
the deployed runtime no longer depends on Codd, `codd-extras`, `hasql-migration`, or
`postgresql-simple` for migration execution.

This wave begins only after
`docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md` is complete. It
coordinates changes in the `mori`-registered projects `shinzui/kiroku`, `shinzui/keiro`,
and `shinzui/pgmq-hs`, plus staging and production operations owned by their consumers.
It includes checked-in native manifests and import mappings, legacy-fixture tests,
consumer API rewiring, staged evidence, one new native migration per component, cutover,
and predecessor removal. It does not add consumer-specific behavior to `pg-migrate`,
claim schema snapshot equality from `verify`, or alter production data without a reviewed
backup and maintenance-window runbook.


## Decomposition Strategy

EP-12 converts Kiroku and proves the direct Codd mapping for its seven migrations. EP-13
follows it because Keiro must depend on the concrete `kiroku` component instead of
re-embedding Kiroku SQL; it converts Keiro's sixteen migrations and shared-ledger history.
EP-14 proceeds independently for PGMQ because its source is `hasql-migration` and its
fresh and incremental routes require different evidence. EP-15 brings all three converted
libraries together on real staging copies and appends one new native migration to expose
any prefix, composition, or import defect. EP-16 is the intentionally separate,
operationally risky cutover and dependency-removal step.

A single cross-repository plan was rejected because the source layouts, predecessor
ledgers, and evidence proofs are materially different. Combining staging proof with
production cutover was rejected because repeatable read-only verification and destructive
deployment coordination have different recovery requirements. The consumer plans remain
in this repository so the migration program has one coordination source; each child names
the exact `mori` project and working directory needed to execute it.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 12 | Upgrade Kiroku to a native migration component | docs/plans/12-upgrade-kiroku-to-a-native-migration-component.md | None | None | Not Started |
| 13 | Upgrade Keiro and compose its Kiroku dependency | docs/plans/13-upgrade-keiro-and-compose-its-kiroku-dependency.md | EP-12 | None | Not Started |
| 14 | Upgrade PGMQ with equivalent-history validation | docs/plans/14-upgrade-pgmq-with-equivalent-history-validation.md | None | EP-12 | Not Started |
| 15 | Prove staged imports and native append-only upgrades | docs/plans/15-prove-staged-imports-and-native-append-only-upgrades.md | EP-12, EP-13, EP-14 | None | Not Started |
| 16 | Cut over production and retire predecessor runners | docs/plans/16-cut-over-production-and-retire-predecessor-runners.md | EP-15 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The completed integrations-and-release MasterPlan is an initiative-level prerequisite,
because every conversion needs released core, embed, CLI, adapter, and test-support APIs.
EP-12 and EP-14 can then proceed in parallel. EP-13 is hard-blocked by EP-12: its native
plan imports `kirokuMigrations`, its `MigrationComponent` declares dependency `kiroku`,
and its Codd import covers the combined historical ledger without copying Kiroku SQL.

EP-15 waits for all three libraries so it can test both fresh and imported histories with
the exact released artifacts. EP-16 waits for recorded staging proof because old runners
must not be disabled or dependencies removed while any database has an unverified import.
Within EP-15, staging work for the Kiroku/Keiro stack and PGMQ can run in parallel, but the
native append migration for Keiro must still run after Kiroku according to the plan.


## Integration Points

EP-12 owns the component name `kiroku`, `kirokuMigrations`, its ordered manifest, and the
old-Codd-name to new-`MigrationId` mapping. EP-13 consumes those exported values and must
not copy Kiroku bytes or introduce a combined migration-set wrapper. It owns component
name `keiro` with dependency set containing exactly `kiroku` for this relationship.

EP-12 and EP-13 both read Codd's shared ledger. Their import mapping must be combined into
one `HistoryImport` when a database contains both histories, and every selected Codd row
must participate in one satisfied mapping. The legacy `migrations.lock` SHA-256 files
remain source-manifest evidence; the target checksums come only from the validated native
plan.

EP-14 owns component name `pgmq`, the baseline `0001-install-v1.11.0`, and the checked-in
schema-contract validator. Direct `pgmq_v1.11.0` history uses `SamePayload`; the two-step
`pgmq_v1.10.0_to_v1.10.1` plus `pgmq_v1.10.1_to_v1.11.0` history uses
`EquivalentState` plus `StateVerified`. EP-15 and EP-16 consume these mappings unchanged.

EP-15 owns the staging evidence record and the exact new native canary migration added to
each component. EP-16 consumes that record as a gate, owns the maintenance-window runbook,
and removes predecessor dependencies only after strict verification succeeds for every
deployed database.


## Progress

(No implementation work has started.)


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Coordinate downstream repository changes in a separate MasterPlan after the
  reusable packages are released.
  Rationale: Consumer conversions must validate the architecture but must not shape core
  APIs through temporary source-specific shortcuts.
  Date: 2026-07-10

- Decision: Sequence Keiro after Kiroku while allowing PGMQ to proceed in parallel.
  Rationale: Keiro imports and composes Kiroku's component directly; PGMQ uses an unrelated
  predecessor ledger and has no code dependency on either component.
  Date: 2026-07-10

- Decision: Keep production cutover separate from code conversion and staging proof.
  Rationale: Disabling old runners and changing deployment jobs requires backups,
  quiescence, coordination, and an evidence gate that ordinary repository changes do not.
  Date: 2026-07-10

- Decision: Consume the corrected core default schema name `pgmigrate` in downstream
  import, staging, and cutover evidence.
  Rationale: PostgreSQL reserves the original draft's `pg_migrate` name for system use;
  downstream runbooks must name the schema the released core can actually create.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Note

2026-07-10: Replaced the impossible reserved `pg_migrate` schema name with the corrected
core default `pgmigrate` and recorded the downstream coordination decision.
