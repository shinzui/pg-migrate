---
id: 1
slug: build-pg-migrate-v1-core-engine
title: "Build pg-migrate v1 core engine"
kind: master-plan
created_at: 2026-07-10T15:50:23Z
intention: "intention_01kx6bkse1end9hcygcaemmtqc"
---

# Build pg-migrate v1 core engine

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, a Haskell library can declare a named, ordered migration component,
an application can compose components into an explicitly ordered plan, and the
`pg-migrate` engine can validate and apply that plan through one dedicated Hasql
connection. SQL bytes are embedded in the executable, checksummed with SHA-256, checked
against a versioned PostgreSQL ledger, and executed under one session advisory lock.
Transactional and nontransactional work have distinct durable semantics, repair is
audited, and source-agnostic legacy history can be imported without executing target
migrations. A developer can observe the result with the core unit and PostgreSQL
integration suites and with a small example plan that applies exactly once.

This MasterPlan owns the core `pg-migrate/` package and the
`pg-migrate-embed/` package described by `docs/initial-spec.md`. It includes the pure
model, SQL validation, ordered manifests, ledger lifecycle, plan verification, connection
and lock ownership, transactional and nontransactional execution, repair, structured
events/reports/errors, and generic history import. It excludes the reusable CLI, legacy
source adapters, public `ephemeral-pg` helper, release documentation, and downstream
Kiroku, Keiro, and PGMQ conversions; those are coordinated by
`docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md` and
`docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md`. Down migrations,
automatic retry or repair, arbitrary `IO` actions, per-migration dependency edges,
filesystem migrations at runtime, and schema snapshot comparison remain explicit v1
non-goals.


## Decomposition Strategy

The work is split at behavioral boundaries. EP-1 establishes a compiling workspace and
the validated pure plan model. EP-2 owns all interpretation of SQL bytes and all manifest
and Template Haskell behavior. EP-3 owns the durable ledger schema and the pure comparison
between a declared plan and stored rows. EP-4 owns the dedicated connection, PostgreSQL
version gate, advisory lock, transactional executor, event ordering, and reports. EP-5
extends that lifecycle with the conservative nontransactional state machine and audited
repair. EP-6 reuses the plan, ledger, connection, and lock contracts to record verified
legacy history atomically.

This separation allows EP-2 and EP-3 to proceed in parallel after EP-1, and it makes each
work stream demonstrable with focused tests. A single plan was rejected because it would
mix pure parsing, Template Haskell recompilation, dynamic SQL, exception-safe connection
management, crash semantics, and import evidence across far more than five milestones.
Splitting ledger and transactional execution further by individual module was rejected
because their statements and row decoders form one shared schema contract. Generic import
remains separate from the Codd and `hasql-migration` adapters so the normal runner has no
predecessor dependency or source-specific branch.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Bootstrap the pg-migrate workspace and pure model | docs/plans/1-bootstrap-the-pg-migrate-workspace-and-pure-model.md | None | None | Complete |
| 2 | Validate SQL and embed ordered manifests | docs/plans/2-validate-sql-and-embed-ordered-manifests.md | EP-1 | None | Complete |
| 3 | Build the versioned ledger and plan verification | docs/plans/3-build-the-versioned-ledger-and-plan-verification.md | EP-1 | EP-2 | Complete |
| 4 | Run transactional migrations under a dedicated lock | docs/plans/4-run-transactional-migrations-under-a-dedicated-lock.md | EP-2, EP-3 | None | Complete |
| 5 | Run and repair nontransactional migrations | docs/plans/5-run-and-repair-nontransactional-migrations.md | EP-4 | None | In Progress |
| 6 | Import migration history through the generic model | docs/plans/6-import-migration-history-through-the-generic-model.md | EP-3, EP-4 | EP-5 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

EP-1 is the root because every other plan needs its Cabal workspace, custom prelude,
opaque model types, smart identifier constructors, component ordering, and test harness.
EP-2 and EP-3 can then proceed in parallel. EP-2 needs the `Migration` representation to
attach validated SQL, transaction mode, and checksum. EP-3 needs the plan description and
IDs to define ledger rows and prefix comparison; it has only a soft dependency on EP-2
because ledger codecs can be written against the model before the complete SQL scanner is
available.

EP-4 is serialized behind EP-2 and EP-3 because atomic execution must consume validated
SQL and write exactly the ledger schema EP-3 defines. EP-5 extends EP-4's connection and
event lifecycle, so it cannot safely start with an independent runner. EP-6 requires the
ledger statements and lock-owning connection orchestration from EP-3 and EP-4. It may be
implemented alongside EP-5, although completing EP-5 first reduces merge pressure in the
top-level export module and shared audit-table statements.


## Integration Points

EP-1 owns the internal constructors in
`pg-migrate/src/Database/PostgreSQL/Migrate/Types.hs`, the pure plan representation in
`pg-migrate/src/Database/PostgreSQL/Migrate/Plan.hs`, and the stable re-export boundary in
`pg-migrate/src/Database/PostgreSQL/Migrate.hs`. Later plans extend the top-level export list but do
not expose constructors for validated inputs or mutable options.

EP-2 owns the exact-byte contract for `SqlAction`, `MigrationChecksum`, transaction-mode
directives, and `pg-migrate-embed/src/Database/PostgreSQL/Migrate/Embed.hs`. EP-4 must
decode already-validated UTF-8 only at the Hasql 1.10 `Text` boundary and must never
normalize bytes before comparing checksums.

EP-3 owns the complete `pgmigrate` ledger schema, its row codecs, internal schema version,
and comparison result consumed by EP-4, EP-5, and EP-6. No later plan may issue an
independent variant of ledger DDL. EP-5 extends the already-created `migrations` and
`repairs` tables; EP-6 writes `migrations` and `history_imports` in one transaction.

EP-4 owns `ConnectionProvider`, `RunOptions`, the session advisory-lock bracket, server
version policy, session-setting restoration, event callback boundaries, and report/error
types. EP-5 and EP-6 must enter PostgreSQL only through that bracket so a second connection
cannot silently drop the lock. The public API must also expose the repair and history
operations required by later packages even though the illustrative export list in section
16 of `docs/initial-spec.md` omits those later-defined functions.


## Progress

- [x] (2026-07-10 10:29 PDT) EP-1: Bootstrapped the GHC 9.12 workspace, opaque pure
  model, explicit and stable plan validation, Nix package, and 34-test unit suite.
- [x] (2026-07-10 11:45 PDT) EP-2: Added exact-byte SQL validation, ordered Template
  Haskell manifests, component construction, crash-conservative authoring, and a
  tracked-input recompilation proof; the final 65-test core and 24-test embed suites pass.
- [x] (2026-07-10 12:29 PDT) EP-3: Added the versioned four-table ledger, typed snapshot
  loading, exhaustive plan comparison, status and strict verification, and PostgreSQL 17
  coverage; all 81 unit and 4 integration tests pass and the full workspace builds.
- [x] (2026-07-10 13:10 PDT) EP-4: Added dedicated connection/version/timeout/lock
  ownership, atomic transactional execution, structured events and reports, condemnation
  detection, and interruption-safe cleanup; all 85 unit and 14 integration tests pass.


## Surprises & Discoveries

- Observation: the locally registered crypton 1.1.2 exposes SHA-256 digest conversion
  through `ram`'s `Data.ByteArray`, not the older `memory` package. EP-1 therefore owns a
  direct `ram >= 0.20 && < 0.23` dependency; EP-2 and EP-3 should consume the resulting
  opaque 32-byte `MigrationChecksum` rather than add a competing conversion path.

- Observation: the default nixpkgs GHC 9.12 set predates the required crypton and Hasql
  releases. The project-owned `flake.module.nix` now pins the four-version crypton/Hasql
  graph used by Cabal. Later packages should reuse that package set rather than introduce
  independent pins, and upstream database-dependent checks must not replace each
  package's own hermetic tests.

- Observation: PostgreSQL 17 and 18 reserve schema names beginning with lowercase `pg_`,
  so the draft default `pg_migrate` cannot be created by an ordinary or superuser-backed
  application connection. EP-3 corrected the coordinated default to `pgmigrate` and now
  rejects the reserved prefix before Hasql execution.

- Observation: a server-blocking default advisory-lock call can starve an in-process
  concurrent runner at the libpq/RTS boundary. EP-4 therefore uses interruptible
  `pg_try_advisory_lock` polling for every wait mode, including infinite wait, while
  retaining the same one-session lock ownership contract for EP-5 and EP-6.


## Decision Log

- Decision: Divide `docs/initial-spec.md` into three delivery-wave MasterPlans and make
  this document the core-engine wave.
  Rationale: The full specification spans six packages, two legacy engines, three
  downstream repositories, and production cutover. Three registries keep every child
  independently verifiable and below the seven-plan coordination limit.
  Date: 2026-07-10

- Decision: Preserve exact SQL bytes internally while validating UTF-8 at definition
  time.
  Rationale: SHA-256 covers source bytes, while locally registered Hasql 1.10.3.5 accepts
  `Text` for sessions and statements. Validation makes later byte-to-text conversion
  total without changing the checksum payload.
  Date: 2026-07-10

- Decision: Put the core package in `pg-migrate/`, matching the committed Mori identity,
  and keep every optional package in its named sibling directory.
  Rationale: The concurrently added `mori.dhall` is registered as
  `mori://shinzui/pg-migrate` with all six package paths. Project-owned flake composition
  should redirect the default package to `pg-migrate/` without rewriting those identities.
  Date: 2026-07-10

- Decision: Extend the public surface with narrowly scoped history-import and repair
  entry points while retaining opaque validated input types.
  Rationale: Sections 18 and 19 require separate CLI and adapter packages to invoke those
  operations, but the illustrative export list in section 16 does not name them.
  Date: 2026-07-10

- Decision: Treat EP-1's `Database.PostgreSQL.Migrate.Internal` as a read-only
  integration boundary for exact checksum bytes and plan metadata.
  Rationale: EP-3 needs those values for ledger rows, while keeping validated input
  constructors inaccessible preserves the singular safe public API.
  Date: 2026-07-10

- Decision: Use `pgmigrate` as the v1 default metadata schema and cascade that name to
  import, repair, and cutover plans.
  Rationale: PostgreSQL reserves `pg_` for system schemas; the original `pg_migrate` name
  is impossible on the explicitly supported PostgreSQL 17 and 18 servers unless an unsafe
  server-wide developer setting is enabled.
  Date: 2026-07-10


## Outcomes & Retrospective

EP-1 delivered the compiling package, pure model, and plan semantics that unblock both
EP-2 and EP-3. EP-2 delivered exact-byte SQL validation, ordered compile-time embedding,
component construction, safe migration authoring, and explicit GHC dependency tracking.
EP-3 delivered the PostgreSQL-compatible `pgmigrate` ledger, versioned transactional DDL,
typed loading, exhaustive plan comparison, and read-only status/verification sessions.
EP-4 delivered dedicated connection and lock ownership, server/timeout policy, atomic
transactional execution, structured event/report/error behavior, and interruption-safe
cleanup. All final EP-1 through EP-4 formatting, build, unit, package-specific, and live
database checks passed. The initiative remains in progress: nontransactional repair and
history import are still owned by EP-5 and EP-6.


## Revision Note

2026-07-10: Marked EP-1 complete, recorded its crypton/Nix integration discoveries, and
clarified the internal read-only boundary that EP-2 and EP-3 must consume.

2026-07-10: Marked EP-2 complete after its final formatting, package builds, 65 core
tests, 24 embed tests, and tracked-input recompilation test all passed.

2026-07-10: Started EP-3 after confirming its hard dependency EP-1 and soft dependency
EP-2 are complete.

2026-07-10: Corrected the cross-plan default ledger schema from impossible `pg_migrate`
to PostgreSQL-compatible `pgmigrate` after live PostgreSQL 17 validation.

2026-07-10: Marked EP-3 complete after the full workspace build, 81 unit tests, and 4
PostgreSQL 17 integration tests passed, including installation, constraints, quoting,
read-only loading, and future-version refusal.

2026-07-10: Marked EP-4 complete after the full workspace build, 85 unit tests, and 14
PostgreSQL 17 integration tests passed; recorded the default infinite-wait polling change
that prevents in-process libpq/RTS starvation.

2026-07-10: Started EP-5 after EP-4's dedicated connection, lock, transactional runner,
event, and cleanup contracts passed their complete acceptance gate.

2026-07-10: Started EP-4 after its hard dependencies EP-2 and EP-3 passed their complete
acceptance gates.
