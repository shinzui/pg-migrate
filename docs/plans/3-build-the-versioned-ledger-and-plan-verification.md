---
id: 3
slug: build-the-versioned-ledger-and-plan-verification
title: "Build the versioned ledger and plan verification"
kind: exec-plan
created_at: 2026-07-10T15:50:23Z
intention: "intention_01kx6bkse1end9hcygcaemmtqc"
master_plan: "docs/masterplans/1-build-pg-migrate-v1-core-engine.md"
---

# Build the versioned ledger and plan verification

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan gives `pg-migrate` a versioned, self-describing PostgreSQL ledger and a strict
comparison between that ledger and a declared migration plan. On a fresh PostgreSQL 17 or
18 database, the library can create its metadata schema and tables, read them through
typed Hasql statements, report pending and applied migrations, and reject changed,
reordered, interrupted, or unknown history before user SQL runs. Integration tests show
fresh initialization and every mismatch as structured data rather than rendered text.


## Progress

- [x] (2026-07-10 11:57 PDT) Milestone 1: added an opaque PostgreSQL identifier and
  ledger configuration, immutable stored-row/report/error types, and five focused
  configuration tests; all 70 core unit tests pass.
- [x] (2026-07-10 12:00 PDT) Milestone 2: implemented identifier-safe version 1 DDL,
  typed metadata statements, ordered upgrade selection, transactional installation, and
  newer-version refusal; all 72 core unit tests pass.
- [x] (2026-07-10 12:10 PDT) Milestone 3: added deterministic typed snapshot loading,
  exhaustive pure comparison, prefix/status/unknown policies, and strict-versus-lenient
  reports; all 80 core unit tests pass.
- [ ] Milestone 4: expose status and strict verification behavior, add PostgreSQL
  integration coverage, and complete final validation.


## Surprises & Discoveries

- Observation: GHC's `DuplicateRecordFields` still emits forward-compatibility warnings
  for type-directed record updates when two report types share field labels. The ledger
  implementation reconstructs immutable reports explicitly instead, keeping the package
  warning-free under GHC 9.12 and future record-field changes.
  Evidence: the first build warned on updating `VerificationReport.issues`; explicit
  reconstruction removed the warning without changing the 80 passing unit tests.


## Decision Log

- Decision: Keep ledger DDL in a versioned Haskell migration list and derive test fixtures
  from that single source.
  Rationale: The runner must embed ledger upgrades and must not depend on source files at
  runtime; duplicating authoritative DDL in fixture files would invite drift.
  Date: 2026-07-10

- Decision: Separate pure plan/row comparison from Hasql loading.
  Rationale: Prefix, checksum, position, kind, mode, status, and unknown-row behavior can
  be exhaustively tested without a database and reused by run, status, verify, and import.
  Date: 2026-07-10

- Decision: Validate ledger schema names as PostgreSQL quoted identifiers: non-empty,
  NUL-free UTF-8 of at most 63 bytes, with escaping deferred to the SQL builder.
  Rationale: quoted identifiers legitimately include spaces, Unicode, and double quotes;
  rejecting them would make the advertised safe quoting contract artificially narrow.
  Date: 2026-07-10

- Decision: Use hexadecimal `0x70675F6D69677261` as the stable default advisory lock
  key.
  Rationale: the bytes read as the recognizable prefix `pg_migra`, fit in signed `Int64`,
  and give this engine a project-owned constant rather than relying on runtime hashing.
  Date: 2026-07-10

- Decision: Return `Either LedgerError ()` inside the initialization `Session`.
  Rationale: a future ledger version is an expected, structured compatibility result and
  cannot be represented by the plan's provisional `Session ()` signature without
  discarding data or fabricating a Hasql transport error. EP-4 can lift this result into
  its runner error while preserving genuine `SessionError` separately.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Complete `docs/plans/1-bootstrap-the-pg-migrate-workspace-and-pure-model.md` first. It
provides opaque identities and an internal plan description with component order,
component-local position, checksum, kind, and transaction mode. The SQL plan in
`docs/plans/2-validate-sql-and-embed-ordered-manifests.md` is a soft dependency: this plan
can build ledger comparison from manual migrations, but final integration should use its
exact SQL checksum behavior.

The default metadata schema is `pg_migrate`. `ledger_metadata` stores one schema version;
`migrations` stores durable execution state; `history_imports` and `repairs` are append-only
audit tables even when those features are not yet invoked. A ledger version is the format
of these tables, not a user migration number. A strict plan comparison means the database
must contain only a valid prefix of every declared component and no unknown rows. Status
may use an explicit lenient unknown-history policy, but `verify` is strict by default.

Hasql 1.10.3.5 exposes opaque `Statement` values through `preparable` and `unpreparable`,
typed encoders/decoders, `Connection.use`, and structured `Hasql.Errors.SessionError`.
Schema names are dynamic, so validate them as PostgreSQL identifiers and quote them by
doubling embedded double quotes before constructing statement text. Never interpolate an
unvalidated raw name.


## Plan of Work

Milestone 1 adds ledger-facing types to
`pg-migrate/src/Database/PostgreSQL/Migrate/Ledger/Types.hs`. Implement opaque
`PostgresIdentifier` and `LedgerConfig`, `defaultLedgerConfig`, and `ledgerConfig`.
`LedgerConfig` controls only metadata schema and `Int64` advisory lock key; table names are
fixed. Add `MigrationStatus = Running | Applied | Failed`, `UnknownMigrationsPolicy`,
stored-row records, `VerificationIssue`, `VerificationReport`, and `StatusReport`. Public
output records may expose immutable constructors; validated configuration remains opaque.

Milestone 2 creates `pg-migrate/src/Database/PostgreSQL/Migrate/Ledger/Sql.hs` and
`pg-migrate/src/Database/PostgreSQL/Migrate/Ledger/Migrations.hs`. Build statements from a quoted
validated schema. Version 1 creates exactly the four tables and constraints in section 12
of `docs/initial-spec.md`, inserts the singleton metadata row, and records the running
library version. Run each internal ledger upgrade transactionally. A missing schema is
version 0; an understood older version upgrades one step at a time; a version newer than
the binary returns `LedgerTooNew` without mutation. Expose an internal list of versioned
upgrade actions so tests can create each supported prior version.

Milestone 3 creates `pg-migrate/src/Database/PostgreSQL/Migrate/Ledger.hs`. Implement Hasql statements
to load metadata and all rows in deterministic `(component, position)` order. The pure
comparison checks, in order, duplicate/corrupt database rows, pre-existing `Running` or
`Failed`, known identity position, checksum, kind, transaction mode, per-component prefix,
and unknown rows under policy. Report all non-mutually-exclusive verification issues in
stable order, but mutating callers will stop if any issue exists. An applied target prefix
may be empty. Database rows for an entirely unknown component count as unknown, not as a
missing plan dependency.

Milestone 4 exposes non-mutating internal sessions used later by `migrationStatus` and
`verifyMigrationPlan`. Status partitions plan entries into applied and pending and includes
unknown rows when policy permits. Verification additionally treats any pending required
migration as an issue. Neither path initializes or upgrades the ledger when invoked in
read-only verification mode; a missing ledger is reported as all migrations pending. Add
unit tests for every issue and integration tests under `test/integration/` for installation,
idempotent re-entry, newer-version refusal, and a custom quoted schema.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`:

```bash
mori registry show hasql/hasql --full
nix develop
just create-database
cabal test pg-migrate:pg-migrate-unit
cabal test pg-migrate:pg-migrate-integration
```

The local shell sets `PG_CONNECTION_STRING`; the integration harness must explain and skip
only when that variable is absent, while CI must provide it. Expected summary:

```text
Test suite pg-migrate-unit: PASS
Test suite pg-migrate-integration: PASS
```

Run `nix fmt` and `cabal build all` before committing. Required trailers are:

```text
MasterPlan: docs/masterplans/1-build-pg-migrate-v1-core-engine.md
ExecPlan: docs/plans/3-build-the-versioned-ledger-and-plan-verification.md
Intention: intention_01kx6bkse1end9hcygcaemmtqc
```


## Validation and Acceptance

On a fresh database, running the ledger initializer twice leaves schema version 1 and no
duplicate metadata. Inspecting `pg_migrate.migrations` shows the exact constraints in the
specification. A custom valid schema such as `app_migrations` creates quoted objects there;
an invalid or overlong identifier is rejected before Hasql execution.

Pure comparison tests must distinguish checksum mismatch, removed or inserted migration,
position change, kind change, transaction-mode change, `Running`, `Failed`, and unknown
row. Appending a new target migration produces one pending item. Removing the last applied
migration from the target fails prefix validation. Strict verification fails on pending
required migrations and unknown rows; lenient status preserves unknown rows in its report
without treating them as target migrations. Setting metadata to a future version leaves
all tables unchanged and returns `LedgerTooNew`.


## Idempotence and Recovery

Ledger initialization and each supported upgrade are transactional and idempotent after
their version is recorded. If an upgrade transaction fails, its metadata version must not
advance; correct the cause and rerun. Tests use a dedicated local database/schema and drop
only their uniquely named test schemas, never the developer's default schema. Do not offer
a downgrade or automatically rewrite a newer ledger. Keep old-version fixture constructors
when adding future upgrades so CI can test every version in the current major series.


## Interfaces and Dependencies

Use Hasql 1.10 statements and Hasql Transaction 1.2.2; retain `SessionError` values in
structured errors. Required public or internal interfaces include:

```haskell
defaultLedgerConfig :: LedgerConfig
ledgerConfig :: Text -> Int64 -> Either DefinitionError LedgerConfig
comparePlanWithLedger :: UnknownMigrationsPolicy -> PlanDescription -> [StoredMigration] -> VerificationReport
initializeOrUpgradeLedger :: LedgerConfig -> Text -> Hasql.Session.Session ()
loadLedger :: LedgerConfig -> Hasql.Session.Session LedgerSnapshot
statusFromSnapshot :: MigrationPlan -> LedgerSnapshot -> StatusReport
verifyFromSnapshot :: MigrationPlan -> LedgerSnapshot -> VerificationReport
```

`initializeOrUpgradeLedger` is internal and assumes the caller already owns the advisory
lock; `docs/plans/4-run-transactional-migrations-under-a-dedicated-lock.md` supplies that
bracket. No function in this plan writes stdout, reads environment variables, or exits the
process.


## Revision Note

2026-07-10: Started implementation and expanded Progress into the four independently
verifiable milestones from the plan of work.

2026-07-10: Recorded the completed validated configuration and immutable ledger model,
including the quoted-identifier and stable-lock-key decisions.

2026-07-10: Recorded the completed version 1 DDL and transactional upgrade path, and
clarified the structured initialization result consumed by EP-4.

2026-07-10: Recorded typed snapshot loading and exhaustive stable plan comparison,
including the GHC record-update compatibility discovery.
