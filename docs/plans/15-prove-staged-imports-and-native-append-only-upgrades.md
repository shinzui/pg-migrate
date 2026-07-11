---
id: 15
slug: prove-staged-imports-and-native-append-only-upgrades
title: "Prove staged imports and native append-only upgrades"
kind: exec-plan
created_at: 2026-07-10T15:50:26Z
intention: "intention_01kx6bkt8decx81jm8zbbjmgjk"
master_plan: "docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md"
---

# Prove staged imports and native append-only upgrades

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan proves the complete migration path on isolated copies of real databases before
production changes. For Kiroku, Keiro, and PGMQ, operators capture predecessor evidence,
run the maintained importer, pass strict `pg-migrate verify`, and then apply one new native
append-only migration exactly once. The same released artifacts also build fresh databases
to the identical declared plan. A checked staging evidence record captures database source,
server major, role, mappings, reports, timings, and recovery observations and becomes the
hard gate for production cutover.


## Progress

- [x] (2026-07-10 20:55 PDT) Confirmed EP-12, EP-13, and EP-14 complete; resolved all
  three owner repositories through `mori`; and started the repository-owned staging work.
- [ ] Milestone 1: Inventory/evidence templates are checked in and all three owner
  revisions are remotely fetchable; operator-owned snapshot references, PostgreSQL
  roles/majors, and restoration proof remain required.
- [ ] Milestone 2: Run import rehearsals on restored staging copies.
- [x] (2026-07-10 21:28 PDT) Milestone 3: Appended observable schema-comment canaries as
  Kiroku `0008` (`6399844`), Keiro `0017` (`49c6f2a`), and PGMQ `0002` (`edb6273`),
  without modifying historical payloads or mappings.
- [ ] Milestone 4: Repository-local fresh/imported proofs and all behavior suites pass.
  Keiro also passes its full matrix from a clean worktree using only published source
  revisions; the required repetitions on separately restored staging copies remain
  outstanding.
- [ ] Milestone 5: Record two clean-copy passes per scenario and make the go/no-go decision.


## Surprises & Discoveries

- Observation: Once a canary is appended, verification immediately after importing only
  the historical prefix correctly reports that canary as `PendingMigration`. Strict
  verification becomes clean after `up` applies exactly the canary; treating the pre-up
  pending result as an error would make the append-only proof impossible.

- Observation: The Kiroku conversion and canary commits remain local and are not available
  from the GitHub remote. Keiro's clean source-repository build therefore fails with
  `upload-pack: not our ref`; local validation temporarily omitted the tracked source pin
  and used the ignored local package override, then restored the tracked file unchanged.
  Released staging artifacts cannot be built until the exact Kiroku revision is published.

- Resolution: Kiroku `master` now publishes the conversion and canary through `22fe479`,
  including canary commit `6399844`. Keiro pins both Kiroku source packages to `6399844`
  at commit `0a1b5d6`, and a clean worktree fetched that revision from GitHub and passed
  `nix develop -c cabal test all` without `cabal.project.local`. Keiro and PGMQ `master`
  are published through `0a1b5d6` and `edb6273`, respectively.

- Observation: `mori registry dependents` identifies experimental Danwa as a concrete
  combined Kiroku/Keiro Codd consumer and MLS Service v2 as a deployed direct
  `pgmq-migration` consumer with a Kubernetes staging environment. The configured
  `tan-ng`/`sennari` control plane could not list namespaces, Cloud SQL instances, or
  backups because its Google credentials require interactive reauthentication. No live
  database, backup, cluster object, or credential was read or mutated.


## Decision Log

- Decision: Require both fresh and imported paths to reach one identical declared plan
  before cutover.
  Rationale: Import correctness alone does not prove new installs, and fresh correctness
  alone does not prove predecessor evidence mappings.
  Date: 2026-07-10

- Decision: Use reviewed, low-risk component-owned metadata changes as native canaries.
  Rationale: A real appended migration must change observable database state without
  introducing unrelated product behavior or disposable test tables.
  Date: 2026-07-10

- Decision: Use schema comments naming the owning component and terminal migration as all
  three canaries.
  Rationale: Comments are observable through `pg_catalog`, non-destructive, compatible
  with old and new application binaries, and do not create disposable product objects.
  Date: 2026-07-10

- Decision: Before `up`, require verification to report exactly the known canary entries
  as pending and no other issue; require strict clean verification immediately after `up`.
  Rationale: This distinguishes the intended append-only delta from drift while preserving
  the plan's final strict-verification gate.
  Date: 2026-07-10

- Decision: Pin Keiro's Kiroku source packages to the published canary commit `6399844`
  and validate from a clean worktree with no local package override.
  Rationale: Keiro's composed plan and tests require Kiroku `0008`; the pre-canary
  `15e6fe2` pin could not reproduce the declared 25-entry plan even after publication.
  Date: 2026-07-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Complete `docs/plans/12-upgrade-kiroku-to-a-native-migration-component.md`,
`docs/plans/13-upgrade-keiro-and-compose-its-kiroku-dependency.md`, and
`docs/plans/14-upgrade-pgmq-with-equivalent-history-validation.md` first. This plan spans
the three `mori` repositories and an operator-controlled staging environment. It does not
authorize access to or mutation of production; use sanitized copies or snapshots with the
same ledger/schema state and PostgreSQL major.

A representative set includes: Kiroku with its seven Codd rows; a combined Keiro database
with seven Kiroku and sixteen Keiro rows in one Codd ledger; PGMQ with direct
`pgmq_v1.11.0`; and PGMQ with both incremental rows plus a schema that should satisfy the
v1.11 contract. Include any supported legacy Codd schema generation actually deployed.
Record exact application/library versions and source-evidence artifacts.

Strict verify means plan versus new ledger: no pending required migrations, mismatches,
invalid prefix, Running/Failed, dependency errors, or unknown rows. It does not prove whole
schema equality. Existing focused Kiroku/Keiro snapshots and PGMQ contract validation may
supplement, but never replace, strict ledger verification.


## Plan of Work

Milestone 1 creates `docs/rollout/staging-inventory.md` and a non-secret evidence template.
For each source database, record an opaque identifier, backup/snapshot reference, copy
creation time, PostgreSQL major, predecessor ledger shape/row count, expected components,
application version, database role, and how the old runner is disabled on the copy. Store no
credentials or customer data. Verify backups/copies are restorable before migration work.

Milestone 2 runs import rehearsals with released binaries. On each copy, first run source
inspection and dry validation, capture selected/unselected rows and mapping report, then run
the import during simulated quiescence. Run strict verify immediately. For combined Codd
history import Kiroku and Keiro atomically; for PGMQ test both direct SamePayload and
two-step EquivalentState routes. Query audit tables and confirm no target action ran during
import. Repeat identical import and require idempotency.

Milestone 3 authors one new manifest-appended migration in each owner repository. Select a
reviewed additive metadata change—such as a non-destructive schema comment or similarly
low-risk owner-approved marker—that is observable and compatible with old/new application
versions; do not create disposable product tables. Give it the next local name (`0008` for
Kiroku, `0017` for Keiro, `0002` for PGMQ), append only, and update no historical bytes or
mapping. Add tests that inspect the new state and ledger position.

Milestone 4 proves both paths. Create fresh databases, apply full updated plans, assert
canary state and one ledger row each, then rerun for AlreadyApplied. Restore clean staging
copies, repeat import of historical prefix, run `up` so only canaries execute, assert state,
then rerun. For Keiro prove Kiroku's canary completes before Keiro's because of component
dependency. Run focused schema/behavior tests and strict verify after every run.

Milestone 5 writes one evidence file per scenario under `docs/rollout/evidence/` with
redacted commands, tool/release versions, plan summary, import report hash, verify result,
canary result, duration, lock behavior, and any discovery. Record failures in MasterPlan
Surprises and fix code/mappings in their owner plan before repeating from a restored copy.
Set production go/no-go criteria only when all scenarios pass twice from clean copies.


## Concrete Steps

Resolve current repositories and released commands first:

```bash
mori registry show shinzui/kiroku --full
mori registry show shinzui/keiro --full
mori registry show shinzui/pgmq-hs --full
```

For each isolated copy, use the consumer executable's mounted commands; exact binary names
are recorded by `docs/plans/12-upgrade-kiroku-to-a-native-migration-component.md`,
`docs/plans/13-upgrade-keiro-and-compose-its-kiroku-dependency.md`, and
`docs/plans/14-upgrade-pgmq-with-equivalent-history-validation.md`. The required sequence
is:

```bash
<consumer-migrate> import <source> --check --strict-source --json
<consumer-migrate> import <source> --reason "staging rehearsal" --confirm --strict-source --json
<consumer-migrate> verify --json  # exactly the declared canary/canaries are pending
<consumer-migrate> up --json
<consumer-migrate> verify --json
```

Expected state after import and canary:

```text
historical target rows: Applied by import, actions not executed
new native canary: AppliedNow exactly once
second up: AlreadyApplied
strict verify: success
```

Repository commits for canaries/evidence use:

```text
MasterPlan: docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md
ExecPlan: docs/plans/15-prove-staged-imports-and-native-append-only-upgrades.md
Intention: intention_01kx6bkt8decx81jm8zbbjmgjk
```


## Validation and Acceptance

All four representative histories import from restored copies with no target SQL replay,
complete audit evidence, and strict verify success. Direct and alternative PGMQ paths both
resolve to the same target baseline, but alternative import fails when its state validator
is deliberately made false. Combined Kiroku/Keiro import is atomic and dependency order is
preserved.

Fresh and imported databases apply only the new canary entries once, expose their reviewed
state, and report AlreadyApplied on the second run. Existing Kiroku append/read, Keiro
framework, and PGMQ queue/topic tests pass. Every scenario has a redacted evidence record
and restoration was rehearsed. Any unknown row or manual repair is a no-go until separately
explained and reviewed.


## Idempotence and Recovery

Always begin a rehearsal from a fresh restored copy. Never repair a failed rehearsal in
place to manufacture success; retain logs, record the discovery, fix the owning code, and
restore again. Identical imports/up runs are designed to repeat safely. Protect snapshots
and credentials outside the repository. Canary migrations are append-only after release;
recover with a new forward migration, not history edits. No production runner is disabled
by this plan.


## Interfaces and Dependencies

Use released consumer executables from
`docs/plans/12-upgrade-kiroku-to-a-native-migration-component.md`,
`docs/plans/13-upgrade-keiro-and-compose-its-kiroku-dependency.md`, and
`docs/plans/14-upgrade-pgmq-with-equivalent-history-validation.md`, plus PostgreSQL
backup/restore tools approved by the environment and repository-native tests. Evidence
documents must include the exact component plans:

```text
Kiroku: kiroku/0001..0008
Keiro stack: kiroku/0001..0008 then keiro/0001..0017
PGMQ: pgmq/0001..0002
```

If owner-approved canary content differs from the suggested metadata change, record the
choice and rationale in this plan and the MasterPlan before implementation.


## Revision Note

2026-07-11: Recorded publication of all three owner revisions, corrected Keiro's Kiroku
pin to the published canary commit, captured the clean remote-only full-matrix proof, and
identified Danwa and MLS Service v2 as candidate staging owners through `mori`. EP-15
remains in progress because cloud access requires independent reauthentication and
operator-owned restoration evidence plus two clean-copy passes for every scenario are
still required.
