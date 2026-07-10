---
id: 16
slug: cut-over-production-and-retire-predecessor-runners
title: "Cut over production and retire predecessor runners"
kind: exec-plan
created_at: 2026-07-10T15:50:26Z
intention: "intention_01kx6bkt8decx81jm8zbbjmgjk"
master_plan: "docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md"
---

# Cut over production and retire predecessor runners

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan performs the controlled production transition after staging proof. Operators
back up each database, quiesce every predecessor migration writer, import historical rows,
run strict verification, apply only the reviewed native canary, and switch deployment jobs
to the new consumer command. After an observation window and verification of every
database, repositories and deployed artifacts remove predecessor runtime dependencies.
The result is one audited `pg_migrate` ledger per database and no Codd or
`hasql-migration` runner capable of racing it.


## Progress

(No implementation work has started.)


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Make production mutation conditional on explicit named operator approval even
  when the ExecPlan is otherwise ready.
  Rationale: Backups, process quiescence, deployment changes, and database writes require
  authority and coordination beyond repository implementation.
  Date: 2026-07-10

- Decision: Never delete the new ledger to roll back an application deployment.
  Rationale: The ledger and import/repair audits are evidence; recovery is forward-only or
  full database restore under the approved runbook.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Complete `docs/plans/15-prove-staged-imports-and-native-append-only-upgrades.md` first and
require its go/no-go criteria for every production topology. This plan spans operator-owned
deployment systems and the Kiroku, Keiro, and pgmq-hs repositories. It is not authorization
by itself: before any production write, record the approver, maintenance window, database
inventory, backup owner, application owner, migration operator, and abort authority.

The old ledger remains present after import. Dual writers are unsafe: Codd and
`hasql-migration` do not coordinate on `pg-migrate`'s lock. Quiescence means deployment
jobs disabled, startup migration paths disabled, and no old process capable of writing.
The Codd adapter's optional legacy lock is additional protection, not proof of quiescence.

The new import writes Applied target prefixes and audits without executing actions. The
subsequent `up` should execute only the native canary from
`docs/plans/15-prove-staged-imports-and-native-append-only-upgrades.md`. Any other pending
target, unknown row, mismatch, Running, Failed, or unexpected selected/unselected evidence
is an abort condition. `verify` does not replace application health checks or focused
schema contracts.


## Plan of Work

Milestone 1 produces an approved runbook from the staging evidence. Inventory every
database and classify it as Kiroku-only, combined Kiroku/Keiro, PGMQ direct, or PGMQ
alternative. Pin exact binary/container hashes, plan summaries, mapping artifacts,
PostgreSQL majors, expected source rows, database roles, lock keys, maintenance window, and
contacts. Take and restore-test fresh backups. Pre-stage old/new job toggles and ensure one
command can prove old writers are stopped.

Milestone 2 performs one canary production database. Disable old jobs/startup paths and
verify no active old writer. Run source inspection in non-mutating mode and compare its
JSON/hash with the approved expectation. Acquire source protection where available, import
with a ticket-specific reason and confirmation, and capture reports. Run strict verify.
If it succeeds, run `up`; require exactly the approved native canary as AppliedNow, then
strict verify again. Run focused application/schema health checks before ending the window.

Abort before import on any evidence or quiescence mismatch. After import commits, do not
reenable the old writer or delete target rows. If verify/up fails, keep all writers disabled,
retain locks/logs where safe, and choose either a reviewed forward fix or full database
restore according to the named abort authority. A full restore must restore application
data and both ledgers together.

Milestone 3 observes the canary database for the approved interval. Monitor migration
events, advisory-lock contention, application errors, query health, and schema-specific
checks. Re-run strict verify from the deployed artifact. Once accepted, repeat the exact
runbook database by database; never run old and new jobs concurrently or batch an unproven
topology.

Milestone 4 switches deployment configuration permanently to an explicit pre-deploy
migration job; ordinary replicas do not become the primary migration mechanism. Remove
Codd/hasql-migration environment settings and startup hooks only after all databases for a
service have cut over. Keep import commands and audit docs available for disaster recovery,
but disable them from normal deployment paths.

Milestone 5 makes repository cleanup commits. In Kiroku/Keiro remove transitional Codd
snapshot/runtime targets only according to their explicit drift-control decision; remove
predecessor runtime dependencies and obsolete wrapper APIs/config docs. In pgmq-hs remove
remaining `hasql-migration` pins/modules. Update compatibility/rollout docs and `mori`
metadata. Build released artifacts from clean checkouts and run the full acceptance gate.


## Concrete Steps

The approved runbook substitutes real consumer binary names, database selectors, and
secrets through the deployment platform. Its logical sequence is:

```bash
<disable-old-migration-jobs>
<prove-old-writers-quiescent>
<consumer-migrate> import <source> --check --strict-source --json
<consumer-migrate> import <source> --reason "<change-ticket>" --confirm --strict-source --json
<consumer-migrate> verify --json
<consumer-migrate> up --json
<consumer-migrate> verify --json
<run-application-health-checks>
```

Required success shape:

```text
imported history: exact expected prefix
up: exactly one approved native canary AppliedNow
verify: success, no unknown/pending/interrupted rows
application health: pass
old migration writers: disabled
```

Cleanup commits in each repository use:

```text
MasterPlan: docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md
ExecPlan: docs/plans/16-cut-over-production-and-retire-predecessor-runners.md
Intention: intention_01kx6bkt8decx81jm8zbbjmgjk
```


## Validation and Acceptance

Every inventoried database has a restore-tested backup, approved report, exact historical
import, one native canary, final strict verify success, health-check success, and observation
record. Audit tables include source evidence/reason/role/version/timestamps. No database has
both old and new writers enabled. Re-running deployed `up` reports all AlreadyApplied.

Clean released builds of Kiroku, Keiro, and pgmq-hs contain no predecessor runtime
dependency or migration wrapper, and their deployment manifests invoke the explicit new
job. All repository tests and pg-migrate PostgreSQL 17/18 acceptance pass. Transitional
snapshot checks are either retained test-only or removed with a recorded replacement/drift
decision. The MasterPlan outcome lists every database and any remaining exception.


## Idempotence and Recovery

Inspection, strict verify, health checks, and an identical completed import/up are safe to
repeat. Production backup, import, and deployment toggles are risky and require approved
operators. Before import, abort by leaving the old system unchanged and reenable only after
the cause is understood. After import, preserve the new ledger/audit and keep writers
stopped while applying a forward fix; restore the entire backup only through the approved
disaster-recovery path. Never reset checksums, delete audit rows, or run both engines to
"see which wins."


## Interfaces and Dependencies

Use only the exact released consumer artifacts proven by
`docs/plans/15-prove-staged-imports-and-native-append-only-upgrades.md`,
environment-approved backup/deployment tools, and the standard CLI/import APIs. The
operational handoff must name these durable artifacts:

```text
pg_migrate.ledger_metadata
pg_migrate.migrations
pg_migrate.history_imports
pg_migrate.repairs
```

Custom ledger schemas substitute the validated configured schema consistently. The final
deployment interface is an explicit migration command/job receiving consumer-controlled
connection configuration; the core runner never reads Codd environment variables or owns
service process exit policy.
