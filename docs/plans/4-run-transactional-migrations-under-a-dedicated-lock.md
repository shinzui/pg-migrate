---
id: 4
slug: run-transactional-migrations-under-a-dedicated-lock
title: "Run transactional migrations under a dedicated lock"
kind: exec-plan
created_at: 2026-07-10T15:50:24Z
intention: "intention_01kx6bkse1end9hcygcaemmtqc"
master_plan: "docs/masterplans/1-build-pg-migrate-v1-core-engine.md"
---

# Run transactional migrations under a dedicated lock

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, an application can hand `pg-migrate` Hasql settings or a bracketed
connection provider and safely apply a plan of transactional SQL and Haskell migrations.
The runner owns one dedicated connection for the complete operation, accepts only
PostgreSQL 17 and 18, holds one session advisory lock while it initializes and verifies
the ledger, and writes each migration and its Applied row atomically. Callers receive typed
events, reports, and original Hasql errors; the library emits no text and never exits.
Integration tests show two concurrent runners apply every migration exactly once and a
failed transaction leaves neither user effects nor a ledger row.


## Progress

- [x] (2026-07-10 12:39 PDT) Milestone 1: added opaque composable run options and
  connection providers, lock modes, immutable events/results/reports, cleanup context,
  and structured runner errors; all 84 core unit tests pass.
- [x] (2026-07-10 12:49 PDT) Milestone 2: implemented masked dedicated connection
  release, PostgreSQL 17/18 classification, blocking/no-wait/finite advisory locks with
  monotonic timing, explicit unlock, and statement-timeout save/restore; all 85 unit and
  6 PostgreSQL integration tests pass.
- [x] (2026-07-10 13:00 PDT) Milestone 3: implemented the locked runner, full-plan
  verification and nontransactional preflight, atomic SQL/Haskell actions plus Applied
  rows, repeat-run outcomes, rollback, and post-transaction condemnation detection; all
  85 unit and 10 PostgreSQL integration tests pass.
- [x] (2026-07-10 13:10 PDT) Milestone 4: proved durable event ordering, callback and
  asynchronous cleanup, default-wait concurrency, exactly-once effects, timeout and lock
  restoration, and nonnegative durations; all 85 unit and 14 PostgreSQL integration tests
  pass and the full workspace builds.


## Surprises & Discoveries

- Observation: Hasql Transaction returns the action result after `condemn` rolls the
  transaction back; condemnation is not surfaced as a `SessionError`.
  Evidence: the inspected `commitOrAbort` implementation chooses `abortTransaction` but
  still returns `Just res`. The runner therefore reloads the expected ledger row after a
  successful session, and the live condemnation test observes `TransactionCondemned`
  with neither user table nor ledger row remaining.

- Observation: two simultaneous server-blocking `pg_advisory_lock` libpq calls can occupy
  all available test RTS execution capabilities, leaving the lock holder idle inside its
  ledger transaction and the waiter blocked in PostgreSQL.
  Evidence: `pg_stat_activity` showed one connection `idle in transaction` after ledger
  DDL and the other waiting on `Lock/advisory`; replacing the infinite blocking call with
  deadline-free `pg_try_advisory_lock` polling made the same default-options concurrency
  test finish with exactly one execution of each effect.


## Decision Log

- Decision: The safe runner acquires and permanently releases its migration connection,
  including connections supplied by advanced providers.
  Rationale: User SQL can alter arbitrary session state; returning that connection to an
  application pool would violate the dedicated-connection contract.
  Date: 2026-07-10

- Decision: Use `pg_try_advisory_lock` for no-wait, finite, and infinite waits; infinite
  wait polls without a deadline.
  Rationale: polling gives explicit monotonic timing without changing `lock_timeout` and
  prevents simultaneous blocking libpq calls from starving the in-process lock holder.
  Date: 2026-07-10

- Decision: Represent cleanup failure as a structured error carrying both the optional
  primary runner error and a non-empty list of typed cleanup issues.
  Rationale: explicit unlock and statement-timeout restoration can both fail, and losing
  either the original failure or the cleanup evidence would make the dedicated-connection
  contract impossible to diagnose.
  Date: 2026-07-10


## Outcomes & Retrospective

Applications can now run validated transactional SQL and Haskell plans through either
Hasql settings or a bracketed dedicated connection provider. The runner accepts only
PostgreSQL 17 and 18, saves and restores `statement_timeout`, owns one advisory lock across
ledger initialization, verification, and execution, writes every action and Applied row
atomically, and reports `TransactionCondemned` when Hasql aborts without a session error.
Repeat runs return `AlreadyApplied`, and pending nontransactional work is rejected before
any mutation until EP-5 installs its durable state machine.

The final live suite proves rollback, condemnation, no-wait and finite waits, default-wait
concurrency, exactly-once side effects, durable event order, callback failure, and
asynchronous interruption. Cleanup restores the prior timeout and unlocks before the
advanced provider callback returns. Final validation passed `nix fmt`, `cabal build all`,
85 core unit tests, and 14 PostgreSQL 17 integration tests. EP-5 can reuse the same
connection, lock, event, and cleanup lifecycle without creating a parallel runner.


## Context and Orientation

Complete `docs/plans/2-validate-sql-and-embed-ordered-manifests.md` and
`docs/plans/3-build-the-versioned-ledger-and-plan-verification.md` first. The SQL plan at
`docs/plans/2-validate-sql-and-embed-ordered-manifests.md` guarantees every `SqlAction` is
strict UTF-8, free of top-level transaction control, and tagged with exact-byte checksum
and transaction mode. The ledger plan owns all ledger DDL, codecs, and plan comparison.
Call those interfaces rather than duplicate them.

Locally registered Hasql 1.10.3.5 uses `Connection.acquire`, `Connection.release`, and
`Connection.use connection session`. `Connection.use` cleans up after asynchronous
exceptions but preserves session state when cleanup succeeds, so this runner restores its
own settings and then discards the connection. Hasql Transaction 1.2.2 provides
`transactionNoRetry ReadCommitted Write`, `Transaction.sql`, `Transaction.statement`,
and `Transaction.condemn`.

A session advisory lock belongs to one PostgreSQL connection until explicitly unlocked or
the connection closes. It is database-local. The runner order is: acquire connection,
read server version, acquire lock, initialize or upgrade ledger, compare plan, execute all
pending migrations, release lock, restore settings, and release connection. No reconnect
is allowed inside this sequence.


## Plan of Work

Milestone 1 adds `pg-migrate/src/Database/PostgreSQL/Migrate/Runner/Types.hs`. Define opaque
`RunOptions` with functional updates for ledger config, `LockWait`, optional statement
timeout, unknown-history policy, and event callback. Define immutable public
`MigrationEvent`, `MigrationOutcome`, `MigrationResult`, and `MigrationReport` values, and
a `MigrationError` sum retaining `Hasql.Errors.ConnectionError` or `SessionError` where
available. Add `ConnectionProvider` as a rank-n bracket and smart constructors from Hasql
settings and an advanced acquisition function. The advanced constructor must scope its
callback to a new, throwaway connection.

Milestone 2 creates `pg-migrate/src/Database/PostgreSQL/Migrate/Runner/Connection.hs` and
`pg-migrate/src/Database/PostgreSQL/Migrate/Runner/Lock.hs`. Mask acquisition and release while
allowing the body to receive asynchronous exceptions. Query `server_version_num`, accept
major 17 or 18, and reject older or newer stable majors before ledger mutation. Implement
default wait, finite timeout using monotonic elapsed time and `pg_try_advisory_lock`, and
no-wait as one try. Query the prior `statement_timeout`, set the requested value through
parameterized `set_config`, and restore it during cleanup. Always attempt explicit unlock;
report cleanup failure without hiding the primary error.

Milestone 3 creates `pg-migrate/src/Database/PostgreSQL/Migrate/Runner.hs`. Under the lock, call the
ledger interfaces from
`docs/plans/3-build-the-versioned-ledger-and-plan-verification.md` to install or upgrade
and load the ledger, then compare the complete plan before the first user mutation. Produce
`AlreadyApplied` results for the valid prefix and walk pending components as ordered
blocks. At this stage a pending nontransactional action returns a structured
unsupported-state error before execution;
`docs/plans/5-run-and-repair-nontransactional-migrations.md` removes that temporary limit.

For transactional SQL, construct one `Hasql.Transaction.Transaction`: execute the
validated payload with `Transaction.sql`, insert the Applied row with target metadata and
timing, then run `transactionNoRetry ReadCommitted Write`. For a transactional Haskell
action, run the caller action then the same ledger insert. After a successful return,
query the expected row on the same connection. If `Transaction.condemn` rolled back, the
missing row yields `TransactionCondemned` instead of false success.

Milestone 4 wires event and report behavior. Callbacks run at consistency boundaries and
never inside a user transaction. `MigrationStarted` precedes mutation; completion or
failure follows durable outcome. A callback exception stops before the next mutation and
still runs lock, setting, and connection cleanup. Use monotonic time for durations and UTC
for report timestamps. Add fixtures for rollback, condemn, callback failure, timeout
restoration, lock timeout/no-wait, pure server-version classification, and concurrency.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`:

```bash
mori registry show hasql/hasql --full
sed -n '1,220p' /Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql/src/library/Hasql/Connection.hs
sed -n '1,180p' /Users/shinzui/Keikaku/hub/haskell/hasql-project/hasql-transaction/src/library/Hasql/Transaction/Sessions.hs
nix develop
just create-database
cabal test pg-migrate:pg-migrate-unit pg-migrate:pg-migrate-integration
```

Expected final evidence includes:

```text
transactional rollback: OK
condemned transaction: OK
two concurrent runners: OK
lock timeout and no-wait: OK
Test suite pg-migrate-integration: PASS
```

Run `nix fmt` and `cabal build all`. Commits require:

```text
MasterPlan: docs/masterplans/1-build-pg-migrate-v1-core-engine.md
ExecPlan: docs/plans/4-run-transactional-migrations-under-a-dedicated-lock.md
Intention: intention_01kx6bkse1end9hcygcaemmtqc
```


## Validation and Acceptance

Apply a plan containing two transactional SQL migrations to a fresh database. The first
run returns two `AppliedNow` results and creates two Applied rows; the second returns two
`AlreadyApplied` results without executing SQL again. A migration that creates a table and
then fails leaves neither table nor row. A Haskell transaction that calls `condemn` yields
`TransactionCondemned` and no row.

Start two runners against the same plan and database concurrently. Both succeed, the
ledger contains one row per migration, and a side-effect table proves each action ran once.
Holding the lock from another connection makes no-wait fail immediately and a finite wait
fail near its configured duration without changing `lock_timeout`. After success, Hasql
error, callback exception, or asynchronous exception, another connection can acquire the
lock. Event order matches durable boundaries and all durations are nonnegative.


## Idempotence and Recovery

Successful plans are idempotent because the verified prefix skips Applied rows. Failed
transactional work is safe to rerun because PostgreSQL rolls back the action and ledger
insert together. Never retry automatically. If unlock or setting restoration fails,
release the connection rather than reuse it. Tests create and remove only uniquely named
schemas. A killed process releases the session lock when PostgreSQL closes its connection.


## Interfaces and Dependencies

Use locally inspected Hasql 1.10.3.5 and Hasql Transaction 1.2.2. `time` supplies UTC;
use a monotonic clock for waits and durations. Required interfaces are:

```haskell
defaultRunOptions :: RunOptions
withLedger :: LedgerConfig -> RunOptions -> RunOptions
withLockWait :: LockWait -> RunOptions -> RunOptions
withStatementTimeout :: Maybe NominalDiffTime -> RunOptions -> RunOptions
withUnknownMigrationsPolicy :: UnknownMigrationsPolicy -> RunOptions -> RunOptions
withEventHandler :: (MigrationEvent -> IO ()) -> RunOptions -> RunOptions
connectionProviderFromSettings :: Hasql.Connection.Settings.Settings -> ConnectionProvider
connectionProvider :: (forall a. (Hasql.Connection.Connection -> IO a) -> IO (Either Hasql.Errors.ConnectionError a)) -> ConnectionProvider
runMigrationPlan :: RunOptions -> Hasql.Connection.Settings.Settings -> MigrationPlan -> IO (Either MigrationError MigrationReport)
runMigrationPlanWith :: RunOptions -> ConnectionProvider -> MigrationPlan -> IO (Either MigrationError MigrationReport)
```

Constructors for `RunOptions`, `ConnectionProvider`, and validated configuration remain
hidden. Output constructors remain public for integrations and tests.


## Revision Note

2026-07-10: Started implementation and expanded Progress into the four independently
verifiable milestones from the plan of work.

2026-07-10: Recorded the completed runner type contract and cleanup-error composition
decision after all 84 unit tests passed.

2026-07-10: Recorded the completed connection, version, lock, and statement-timeout
lifecycle after all 85 unit and 6 live PostgreSQL tests passed.

2026-07-10: Recorded the completed atomic transactional runner and Hasql condemnation
discovery after all 85 unit and 10 live PostgreSQL tests passed.

2026-07-10: Completed event, callback, concurrency, and asynchronous-cleanup coverage;
revised infinite locking to deadline-free polling after live RTS starvation evidence; and
recorded the final full-workspace acceptance results.
