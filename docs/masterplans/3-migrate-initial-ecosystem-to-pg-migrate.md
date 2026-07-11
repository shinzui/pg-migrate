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
| 12 | Upgrade Kiroku to a native migration component | docs/plans/12-upgrade-kiroku-to-a-native-migration-component.md | None | None | Complete |
| 13 | Upgrade Keiro and compose its Kiroku dependency | docs/plans/13-upgrade-keiro-and-compose-its-kiroku-dependency.md | EP-12 | None | Complete |
| 14 | Upgrade PGMQ with equivalent-history validation | docs/plans/14-upgrade-pgmq-with-equivalent-history-validation.md | None | EP-12 | Complete |
| 15 | Prove staged imports and native append-only upgrades | docs/plans/15-prove-staged-imports-and-native-append-only-upgrades.md | EP-12, EP-13, EP-14 | None | In Progress |
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

- [x] EP-12: Upgraded Kiroku to a native component with seven byte-preserving manifest
  entries, composable Codd evidence, standard CLI, native test setup, clean production
  closure, and passing migration/store suites.
- [x] EP-13: Upgraded Keiro to a sixteen-entry native component, composed Kiroku first,
  proved atomic shared-ledger import and no replay, rewired framework fixtures, isolated
  Codd transition tools, and passed native, legacy, and full workspace test matrices.
- [x] EP-14: Completed. pgmq-hs and hasql-migration were resolved through `mori`, and
  Milestone 1 is complete at pgmq-hs commit `9637cbc`: one exact-byte PGMQ 1.11 native
  component with passing migration-package tests. Milestones 2 and 3 are complete at
  `cd37dc1`: exact direct-history import and explicitly opted-in equivalent two-step import
  guarded by the checked read-only PGMQ 1.11 contract. Commit `1b36244` rewires all
  fixtures, removes the predecessor surface and dependency, bumps pgmq-migration to
  0.4.0.0, and passes the full Cabal and standalone/Nix-packaged validation matrices.
- [ ] EP-15: In progress. All owner repositories are resolved and the repository-owned
  inventory/templates are checked in. Kiroku `0008`, Keiro `0017`, and PGMQ `0002`
  append-only canaries and their local fresh/imported proofs pass, along with all three
  repositories' behavior suites. Kiroku, Keiro, and PGMQ owner revisions are now remotely
  fetchable, and Keiro's full matrix passes from a clean worktree using only those
  published source revisions. Operator-controlled snapshot identifiers, restoration
  evidence, and two clean-copy passes per scenario remain required before the staging gate
  can complete.


## Surprises & Discoveries

- Observation: `pg-migrate` v1 is released as immutable Git tag `v1.0.0.0` but is not yet
  available from Hackage. EP-12 pins that tag in Cabal and Nix. EP-13 and EP-14 should use
  the same tag until publication rather than introducing different source revisions.

- Observation: Kiroku's test-support package now owns native test database migration, so
  all 234 store behavior examples exercise the `pgmigrate` plan. Keeping the migration
  package's test independent of the store library avoids a cross-package component cycle.

- Observation: EP-13 needs more than Kiroku's convenience Codd config to import a shared
  ledger. EP-12 therefore exports `kirokuLegacyMigrationNames`,
  `kirokuCoddSourcePayloads`, `kirokuCoddManifestText`, and
  `kirokuCoddHistoryMappings` so Keiro can combine both components into one atomic source
  selection and import.

- Observation: EP-12's Kiroku commit `15e6fe2` and EP-13's Keiro commit `f8fcea7` are
  local immutable revisions but the Kiroku revision is not yet available from its GitHub
  remote. EP-15 must publish or otherwise make the exact Kiroku pin fetchable before
  building staging artifacts; local validation passed through the ignored project
  override.

- Resolution: EP-15 published Kiroku through `22fe479`, Keiro through `0a1b5d6`, and PGMQ
  through `edb6273`. Keiro now pins Kiroku canary commit `6399844`; a clean worktree fetched
  it and pg-migrate `v1.0.0.0` from their remotes and passed `nix develop -c cabal test
  all` without the ignored local project override.

- Observation: EP-14's isolated Nix closure required the pg-migrate v1 bounds rather than
  pgmq-hs's older package-set defaults: `crypton` 1.1.4 and `optparse-applicative`
  0.19.0.0 are now pinned beside the immutable pg-migrate tag.

- Observation: An imported historical prefix verified against a canary-extended plan
  necessarily reports only the new canary as pending before `up`; strict verification is
  clean after `up`. EP-15 fixtures now assert that exact transition rather than accepting
  any other pending or drift issue.

- Observation: Keiro's 19-example Codd expected-schema/remediation suite remains green
  behind `legacy-codd-tools`, while its normal package and shared test fixture use the
  native plan. This gives EP-15 both strict transition evidence and a predecessor-free
  runtime path.


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

- Decision: Standardize unreleased-to-Hackage downstream resolution on the immutable
  `pg-migrate` `v1.0.0.0` Git tag.
  Rationale: Kiroku proved both Cabal source-package and fixed-output Nix resolution; the
  remaining consumer plans should not drift to local paths or different revisions.
  Date: 2026-07-10

- Decision: Treat the Kiroku shared-ledger evidence exports as the EP-13 integration
  boundary.
  Rationale: Keiro must union exact payload maps and manifest text before constructing one
  Codd source config; combining only `HistoryMapping` values would leave evidence
  unavailable.
  Date: 2026-07-10

- Decision: Preserve Keiro's Codd-only operational evidence behind a manual build flag
  and keep exact history import in the native library.
  Rationale: Staging still needs remediation and fixup proof, but the production migration
  closure must not retain predecessor runners.
  Date: 2026-07-10

- Decision: Publish all three EP-15 owner revisions and pin Keiro to Kiroku's published
  canary commit before accepting any staging artifact.
  Rationale: A local override cannot prove that operators can reproduce the composed
  25-entry Kiroku/Keiro plan from immutable remote sources.
  Date: 2026-07-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Note

2026-07-10: Replaced the impossible reserved `pg_migrate` schema name with the corrected
core default `pgmigrate` and recorded the downstream coordination decision.

2026-07-10: Started EP-12 after verifying that the integrations-and-release initiative is
complete and that Kiroku has no unmet child-plan dependencies.

2026-07-10: Marked EP-12 complete after byte-preserving source conversion, current and
legacy Codd import proofs, native CLI/test-support integration, full migration and store
tests, clean Cabal package checks and production closure, and a successful Nix build.

2026-07-10: Started EP-13 after confirming EP-12 complete, resolving the Keiro/Kiroku
integration sources through `mori`, and recording the unrelated Keiro worktree changes to
preserve.

2026-07-10: Marked EP-13 complete at Keiro commit `f8fcea7` after byte-preserving native
conversion, dependency-order and shared-ledger import proofs, standard CLI/test-fixture
rewiring, opt-in legacy evidence validation, clean package checks, and the full workspace
test matrix. Recorded Kiroku commit publication as an EP-15 staging prerequisite.

2026-07-10: Started EP-14 after EP-13 completion, resolving pgmq-hs and its
hasql-migration predecessor through `mori` and confirming a clean consumer worktree.

2026-07-11: Advanced EP-15 by publishing Kiroku, Keiro, and PGMQ owner revisions,
correcting Keiro's Kiroku dependency to the canary commit, and passing the full Keiro test
matrix from a clean remote-only worktree. The staging gate remains open for operator-owned
restoration inputs and two passes per clean-copy scenario.
