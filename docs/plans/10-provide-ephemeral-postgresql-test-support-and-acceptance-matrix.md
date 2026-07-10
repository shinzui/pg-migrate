---
id: 10
slug: provide-ephemeral-postgresql-test-support-and-acceptance-matrix
title: "Provide ephemeral PostgreSQL test support and acceptance matrix"
kind: exec-plan
created_at: 2026-07-10T15:50:25Z
intention: "intention_01kx6bkssqee4sz0gzw0tdvkkv"
master_plan: "docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md"
---

# Provide ephemeral PostgreSQL test support and acceptance matrix

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, downstream tests can run a validated migration plan against a temporary
PostgreSQL instance through one small helper and receive a fresh Hasql connection for their
assertions. The repository also has a release-blocking acceptance matrix on PostgreSQL 17
and 18 covering the complete runner, manifests, JSON, repairs, and both import adapters.
Production packages remain free of `ephemeral-pg` and predecessor dependencies. A single
CI command demonstrates all fifteen acceptance groups from `docs/initial-spec.md`.


## Progress

- [x] (2026-07-10 15:38 PDT) Milestone 1: Added `pg-migrate-test-support` with simple,
  options-aware, and configuration-aware helpers plus structured startup, migration,
  callback acquisition, callback, cleanup, and combined callback/cleanup failures.
- [x] (2026-07-10 15:38 PDT) Milestone 2: Proved a migrated table is visible through a
  freshly acquired callback connection whose backend PID differs from the migration
  connection; startup, migration, and callback failure paths are fixture-tested.
- [x] (2026-07-10 15:38 PDT) Milestone 3: Added `just acceptance`, the executable mapping
  of all fifteen initial-spec groups, and an explicit schema-v1 import JSON golden.
- [x] (2026-07-10 15:38 PDT) Milestone 4: Added unmanaged PostgreSQL 17/18 Nix shells and
  matching CI matrix jobs. The aggregate command passes against PostgreSQL 17.10 and 18.4;
  pure classifier tests continue to reject 16 and 19.
- [x] (2026-07-10 15:38 PDT) Milestone 5: Added a Cabal-plan graph closure checker for
  core/embed/CLI and both adapters. Its normal path passes, and injecting `base` as an
  extra forbidden package makes it fail as intended.


## Surprises & Discoveries

- Observation: the existing live server assertion hard-coded PostgreSQL 17 even though the
  core classifier already accepted 17 and 18. The real 18 matrix exposed it immediately;
  the test now asserts membership in the supported pair while the aggregate command prints
  the exact active major.

- Observation: Cabal's generated plan contains unrelated local packages when the whole
  multi-package project is configured. Closure isolation must recursively walk `depends`
  edges from the requested library roots rather than grep every package listed in
  `install-plan`.


## Decision Log

- Decision: Put all `ephemeral-pg` usage in `pg-migrate-test-support` or test-suite stanzas.
  Rationale: The production closure requirement is architectural and must be visible in
  Cabal package boundaries, not merely observed by convention.
  Date: 2026-07-10

- Decision: Test PostgreSQL 17 and 18 as separate matrix jobs rather than one server's
  compatibility classifier alone.
  Rationale: Version acceptance includes actual DDL, lock, transaction, and protocol
  behavior on both supported majors.
  Date: 2026-07-10


## Outcomes & Retrospective

Downstream tests can now bracket a fresh `ephemeral-pg` database, apply a validated plan,
and inspect it through a distinct Hasql connection without flattening expected failures to
text or leaking the callback connection. The package remains an explicit optional library.

`just acceptance` builds all packages, runs eleven test suites covering the fifteen named
groups, checks production closures, and rejects an unsupported active server. The same
command passed on explicit PostgreSQL 17.10 and 18.4 shells. CI runs those shells as
separate matrix jobs. The closure checker passed for core/embed/CLI and both adapter roots,
and its injected-negative path failed. JSON schema v1 now includes a byte-for-byte import
report golden in addition to the command goldens.


## Revision Note

2026-07-10: Implemented and completed EP-10 with the public ephemeral database helper,
fresh-connection and error-path tests, fifteen-group aggregate command, PostgreSQL 17/18
Nix and CI matrix, import JSON golden, and graph-aware production closure gate.


## Context and Orientation

Complete `docs/plans/7-build-the-reusable-migration-cli-and-json-contracts.md`,
`docs/plans/8-import-codd-history-through-the-adapter.md`, and
`docs/plans/9-import-hasql-migration-history-through-the-adapter.md` first. Core and every
optional integration package are then available for aggregate tests.

Mori locates `ephemeral-pg` 0.2.2.0 at
`/Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg`. Its public
`EphemeralPg.with` and `withConfig` bracket a temporary `Database`, and
`EphemeralPg.connectionSettings` returns Hasql 1.10 `Settings` directly. The helper must
use those settings, release the migration connection owned by `runMigrationPlan`, then
acquire a distinct connection for the caller and release it on every exit.

The current Nix shell supplies one `pkgs.postgresql`. Add project-owned matrix wiring in a
new unmanaged `flake.module.nix` or CI job rather than editing seihou-managed
`nix/haskell.nix` unless the template itself must change. PostgreSQL 17 and 18 are the only
accepted stable majors for v1. Tests that require process termination use a helper
executable, never kill the test runner's own process.


## Plan of Work

Milestone 1 creates `pg-migrate-test-support/pg-migrate-test-support.cabal` and
`pg-migrate-test-support/src/Database/PostgreSQL/Migrate/Test.hs`. Implement
`withMigratedDatabase`. Map `EphemeralPg.StartError`, Hasql connection acquisition error,
runner error, and callback cleanup error into distinct `MigratedDatabaseError`
constructors. Use `EphemeralPg.connectionSettings` directly. After migration success,
acquire a fresh callback connection with `Connection.acquire`, bracket
`Connection.release`, and return nested errors without printing or throwing expected
failures.

Milestone 2 consolidates fixtures. Add test helpers for unique component/ledger schemas,
fixture SQL, controlled Hasql failure, advisory lock holding, and subprocess crash points.
Keep helpers in test-support internal modules when downstream packages benefit; do not
expose constructors that bypass normal migration validation. Demonstrate the public helper
with a test that queries a table created by the plan, and prove callback connection process
ID differs from the migration connection process ID captured by an event/test hook.

Milestone 3 maps every section-20 acceptance item to an executable suite: plan validation;
prefix append/removal/insertion/reorder; exact-byte checksum; transactional rollback;
concurrent index; multiple-statement rejection; Running/Failed crash behavior; two runners;
lock timeout/no-wait; generic import; Codd fixtures; `hasql-migration` MD5; alternative
history validator; manifest/recompilation; and JSON contracts. Tests may remain in their
own packages, but create one `just acceptance` or Cabal aggregate command and document the
owner of each group.

Milestone 4 adds PostgreSQL 17/18 jobs under `.github/workflows/ci.yml` and matching local
Nix shells/checks when practical. Each job builds all packages, runs unit and integration
suites, and reports its server major. Add pure rejection tests for 16 and 19 plus actual
matrix success for 17/18. Avoid unsupported floating `postgresql` aliases in the release
gate; name explicit package majors.

Milestone 5 proves dependency isolation. Use `cabal build pg-migrate --dry-run` and the
generated build plan or a small checked script under `scripts/check-production-closure`
to assert core, embed, and CLI normal library closures exclude `ephemeral-pg`, Codd,
`codd-extras`, `hasql-migration`, and `postgresql-simple`; allow source adapters only their
documented Hasql/crypton dependencies. Run this script in CI.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`:

```bash
mori registry show shinzui/ephemeral-pg --full
sed -n '125,165p' /Users/shinzui/Keikaku/bokuno/ephemeral-pg-project/ephemeral-pg/src/EphemeralPg.hs
nix develop .#ghc9124
just acceptance
```

Run both explicit server jobs through the flake or CI-equivalent commands established by
the implementation:

```bash
nix develop .#postgresql17 -c just acceptance
nix develop .#postgresql18 -c just acceptance
```

Expected summary:

```text
PostgreSQL 17 acceptance: PASS (15 groups)
PostgreSQL 18 acceptance: PASS (15 groups)
production dependency closure: PASS
```

Run `nix fmt` and `cabal build all`. Required trailers:

```text
MasterPlan: docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md
ExecPlan: docs/plans/10-provide-ephemeral-postgresql-test-support-and-acceptance-matrix.md
Intention: intention_01kx6bkssqee4sz0gzw0tdvkkv
```


## Validation and Acceptance

`withMigratedDatabase` on a one-migration plan returns a callback connection that can query
the created table. Startup, migration, and callback acquisition failures have different
constructors. The callback connection is fresh, and every success/exception path releases
it. The public package builds only when explicitly selected; `pg-migrate` production build
does not mention it.

Both PostgreSQL jobs pass all fifteen named groups, not merely compilation. Concurrent and
crash tests are deterministic enough for CI: use bounded timeouts and observable barriers,
not sleeps as correctness. The JSON goldens are identical across server majors. The
closure script fails when a forbidden dependency is deliberately injected and passes after
removal. Version classifier tests reject below 17 and above the tested stable maximum.


## Idempotence and Recovery

Temporary databases, unique schemas, and fixture files make all tests repeatable. The
helper brackets server and connection cleanup on exceptions. If a matrix job fails, retain
its logs but do not reuse its data directory; rerun with a fresh ephemeral instance. Nix
configuration belongs in unmanaged `flake.module.nix` so seihou migrations do not overwrite
it. Do not weaken or quarantine a flaky concurrency test without recording the root cause
in this plan.


## Interfaces and Dependencies

The test-support library depends on `pg-migrate`, `ephemeral-pg >= 0.2 && < 0.3`, and
Hasql 1.10. Production libraries do not depend on it. Required public interface:

```haskell
withMigratedDatabase :: MigrationPlan -> (Hasql.Connection.Connection -> IO a) -> IO (Either MigratedDatabaseError a)
```

If custom `RunOptions` are needed, add a separate explicit
`withMigratedDatabaseOptions`; keep the simple required function. `MigratedDatabaseError`
must distinguish startup, acquisition, migration, and cleanup/callback failures without
flattening underlying errors to text.
