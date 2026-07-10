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

(No implementation work has started.)


## Surprises & Discoveries

(None yet.)


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

(To be filled during and after implementation.)


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
