---
id: 5
slug: run-and-repair-nontransactional-migrations
title: "Run and repair nontransactional migrations"
kind: exec-plan
created_at: 2026-07-10T15:50:24Z
intention: "intention_01kx6bkse1end9hcygcaemmtqc"
master_plan: "docs/masterplans/1-build-pg-migrate-v1-core-engine.md"
---

# Run and repair nontransactional migrations

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan completes the runner for operations PostgreSQL cannot execute inside a normal
transaction, such as `CREATE INDEX CONCURRENTLY`, and gives operators explicit audited
recovery. Before the action, the runner durably records Running; after observed success it
records Applied, and after observed Hasql failure it attempts to record Failed. A crash or
ambiguous connection loss leaves Running and blocks future mutation. Operators may then
mark the result applied or retry only with an explicit reason and confirmation. Tests
demonstrate success, failure, crash ambiguity, asynchronous interruption, and the repair
audit trail.


## Progress

- [x] (2026-07-10 13:17 PDT) Milestone 1: implemented exact metadata-guarded
  Running/Applied/Failed transitions and single-statement/session dispatch in the existing
  runner; all 85 unit tests and both focused PostgreSQL success/failure tests pass.
- [x] (2026-07-10 13:25 PDT) Milestone 2: added confirmed, reason-bearing repair
  requests; metadata-verified mark-applied and retry; append-only audit rows; and shared
  runner lifecycle/dispatch hooks; all 87 unit and 3 focused repair integration tests pass.
- [x] (2026-07-10 13:34 PDT) Milestone 3: proved success, observed failure, true process
  termination after Running, durable callback boundaries, exact repair audit contents,
  rejection of every unsafe target class, and cleanup; all 87 unit and 21 PostgreSQL
  integration tests pass and the full workspace builds.


## Surprises & Discoveries

- Observation: after the crash helper receives `SIGKILL`, PostgreSQL retains its session
  advisory lock until the in-flight `pg_sleep` finishes and the backend observes the dead
  client socket. The deterministic harness therefore uses a bounded two-second statement
  and waits for process termination before asserting both Running and lock availability.


## Decision Log

- Decision: Treat every interruption after Running commits as ambiguous and leave Running.
  Rationale: PostgreSQL may have committed nontransactional work before the client observes
  success; guessing would make the ledger less trustworthy than operator review.
  Date: 2026-07-10

- Decision: Make retry a repair operation that retains Running while re-executing, not a
  status reset followed by the ordinary runner.
  Rationale: One audited command must own validation, audit insertion, and action dispatch
  under the same advisory lock.
  Date: 2026-07-10


## Outcomes & Retrospective

The shared runner now executes validated nontransactional SQL and session actions with
durable Running/Applied/Failed transitions, preserving ambiguity across process death and
asynchronous interruption. Repair is explicit, confirmed, metadata-checked, and audited;
mark-applied and retry cannot operate on unknown, changed, transactional, or already
Applied targets. The crash helper remains test-only. The final 87-unit/21-integration
suite proves exact audit fields, success and observed failure, conservative crash state,
durable callback boundaries, and advisory-lock cleanup.


## Context and Orientation

Complete `docs/plans/4-run-transactional-migrations-under-a-dedicated-lock.md` first. It
owns the dedicated connection, advisory lock, server-version check, session cleanup,
events, reports, and transactional dispatcher. Extend that runner; do not create a second
lifecycle. `docs/plans/2-validate-sql-and-embed-ordered-manifests.md` already guarantees a
nontransactional SQL migration contains one safe PostgreSQL statement.

Nontransactional means the user action cannot share one atomic transaction with its ledger
result. Running is durable evidence that execution started, not a transient process flag.
Failed means the client observed a Hasql failure and successfully recorded it; it does not
prove PostgreSQL left no effect. Both statuses block ordinary `up` and strict `verify`.
Repair is an operator assertion recorded in `pgmigrate.repairs`, never an automatic
inference.

Hasql 1.10 constructs an unprepared statement with
`Hasql.Statement.unpreparable Text Encoders.noParams Decoders.noResult` and runs it with
`Hasql.Session.statement ()`. Do not use `Session.script`: the simple-query protocol can
implicitly transact multiple statements, defeating the one-statement contract.


## Plan of Work

Milestone 1 adds transition statements to
`pg-migrate/src/Database/PostgreSQL/Migrate/Ledger/Sql.hs` and dispatch to
`pg-migrate/src/Database/PostgreSQL/Migrate/Runner.hs`. In a short transaction, insert Running with
start time and current metadata. Execute `SqlAction` as one unpreparable statement or
`SessionAction` directly on the same dedicated connection outside an explicit transaction.
On success, transactionally update exactly the expected Running row to Applied with finish
time and duration. On an observed `SessionError`, attempt an exact Running-to-Failed
transition carrying diagnostic text while retaining the structured error in the return.

If marking Failed also fails, return a composite error and leave Running. If an
asynchronous exception arrives after Running, perform only connection and lock cleanup and
leave Running regardless of possible server completion. Emit `MigrationStarted` before the
Running insert as specified, and completion or failure only after its durable transition.
No callback runs inside a transition transaction.

Milestone 2 creates `pg-migrate/src/Database/PostgreSQL/Migrate/Repair.hs` and repair-facing types.
Accept only a concrete `MigrationId`, operation `MarkApplied` or `Retry`, a non-empty
reason, and explicit `Confirmation`. Under the normal provider and lock bracket, load and
verify the ledger, confirm the row is Running or Failed, nontransactional, present in the
current plan at identical metadata/checksum, and free of unrelated blocking mismatches.
Reject checksum changes and every transactional target.

For mark-applied, insert an append-only repairs row with old/new status, reason, database
role, runner version, and timestamp, then update the migration to Applied in the same
transaction. For retry, insert the audit row and set or retain Running transactionally,
execute the current action once, and finish through the normal nontransactional transition.
A failed retry lands in Failed if that transition can be recorded; the repair audit remains
append-only.

Milestone 3 adds deterministic crash injection only to the integration harness. Run a
helper executable or subprocess that pauses after Running commits, terminate it, and
assert the row remains Running. Do not expose crash hooks publicly. Add tests for server
failure, success, callback exceptions, mark-applied, retry success/failure, missing
confirmation, empty reason, checksum mismatch, and transactional repair rejection.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`:

```bash
mori registry show hasql/hasql --full
nix develop
just create-database
cabal test pg-migrate:pg-migrate-unit
cabal test pg-migrate:pg-migrate-integration --test-options='--pattern nontransactional'
cabal test pg-migrate:pg-migrate-integration --test-options='--pattern repair'
```

Expected focused evidence:

```text
CREATE INDEX CONCURRENTLY applies: OK
observed failure records Failed: OK
terminated helper leaves Running: OK
mark-applied writes audit: OK
retry writes audit and applies: OK
```

Then run all tests, `nix fmt`, and `cabal build all`. Required commit trailers:

```text
MasterPlan: docs/masterplans/1-build-pg-migrate-v1-core-engine.md
ExecPlan: docs/plans/5-run-and-repair-nontransactional-migrations.md
Intention: intention_01kx6bkse1end9hcygcaemmtqc
```


## Validation and Acceptance

Apply one `CREATE INDEX CONCURRENTLY` migration and observe Running followed by Applied,
one index, and one ledger row. A two-statement nontransactional script must already fail
definition and never reach dispatch. A deliberate SQL error produces Failed with finish
time and diagnostic text. Killing the helper after its pause leaves Running; the next
ordinary run and strict verify both stop before any later migration.

Mark-applied requires confirmation and a reason, changes only the matching row to Applied,
and adds one immutable audit row. Retry executes exactly once, retains a complete audit
record, and lands in Applied or Failed according to observed outcome. Neither operation
accepts a checksum mismatch, unknown ID, Applied row, or transactional row. After
interruption or repair failure, another connection can acquire the advisory lock.


## Idempotence and Recovery

Ordinary execution is idempotent only after Applied is durable. Running and Failed require
operator choice. Mark-applied cannot repeat after success because the row is already
Applied; return invalid repair rather than false success. Retry can repeat the user action,
so every attempt requires a new confirmation and reason and writes a new audit row. If the
process dies during retry, leave Running and inspect again. Never delete ledger or audit
rows to recover.


## Interfaces and Dependencies

Use `Hasql.Statement.unpreparable`, `Hasql.Session.statement`, and the connection/lock
bracket from `docs/plans/4-run-transactional-migrations-under-a-dedicated-lock.md`. Add
public immutable repair results while keeping confirmation explicit. Required interfaces
are:

```haskell
data RepairOperation = MarkApplied | Retry
repairRequest :: MigrationId -> RepairOperation -> Text -> Confirmation -> Either RepairDefinitionError RepairRequest
repairMigration :: RunOptions -> ConnectionProvider -> MigrationPlan -> RepairRequest -> IO (Either RepairError RepairReport)
```

The completed `runMigrationPlan` and `runMigrationPlanWith` from
`docs/plans/4-run-transactional-migrations-under-a-dedicated-lock.md` now handle all three
actions—transactional SQL/transaction, nontransactional SQL, and session migration—without
an unsupported-mode branch.


## Revision Note

2026-07-10: Updated the repair audit-table reference to the PostgreSQL-compatible default
schema `pgmigrate`; PostgreSQL reserves the original draft's `pg_migrate` name.

2026-07-10: Started implementation and expanded Progress into the three independently
verifiable milestones from the plan of work.

2026-07-10: Recorded the completed nontransactional state machine after a live
`CREATE INDEX CONCURRENTLY` reached Applied and an observed server error durably reached
Failed with diagnostic text.

2026-07-10: Recorded the completed repair API after mark-applied and retry both wrote one
audit row, retry executed the unchanged current action once, and transactional/checksum
validation rejected unsafe requests.

2026-07-10: Completed the plan after a real `SIGKILL` left Running, every unsafe repair
target was rejected, audit contents were verified, and all workspace acceptance checks
passed.
