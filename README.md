# pg-migrate

`pg-migrate` is a Hasql-native PostgreSQL migration toolkit for applications that own an
explicit, compile-time migration plan. Libraries export ordered components; applications
compose them, configure the database connection, and mount the reusable CLI. The runner is
forward-only, uses ledger schema v1, and supports PostgreSQL 17 and 18.

The package set is:

- [`pg-migrate`](https://hackage.haskell.org/package/pg-migrate-1.0.0.0): validated
  plans, runner, ledger, repair, inspection, and generic import.
- [`pg-migrate-embed`](https://hackage.haskell.org/package/pg-migrate-embed-1.0.0.0):
  manifest v1 validation, exact-byte embedding, and authoring.
- [`pg-migrate-cli`](https://hackage.haskell.org/package/pg-migrate-cli-1.0.0.0):
  reusable command parser, dispatcher, text output, and JSON schema v1.
- [`pg-migrate-import-codd`](https://hackage.haskell.org/package/pg-migrate-import-codd-1.0.0.0):
  Codd V1–V5 source adapter.
- [`pg-migrate-import-hasql-migration`](https://hackage.haskell.org/package/pg-migrate-import-hasql-migration-1.0.0.0):
  base64-MD5 predecessor adapter.
- [`pg-migrate-test-support`](https://hackage.haskell.org/package/pg-migrate-test-support-1.0.0.0):
  opt-in `ephemeral-pg` test helper.

Start with the [quickstart](docs/user/quickstart.md) and the runnable
[`examples/basic`](examples/basic). The remaining documentation is organized by audience:

- Library authors: [component](docs/user/component-authoring.md),
  [manifest](docs/user/manifest-authoring.md), and
  [plan composition](docs/user/plan-composition.md).
- Application owners: [CLI integration](docs/user/cli-integration.md) and
  [testing](docs/user/testing.md).
- Operators: [deployment](docs/operations/deployment.md),
  [locks/timeouts](docs/operations/locking-and-timeouts.md),
  [repair](docs/operations/nontransactional-repair.md), and
  [history import](docs/operations/history-import.md).
- Contract consumers: [public API](docs/reference/public-api.md),
  [ledger v1](docs/reference/ledger-v1.md),
  [manifest v1](docs/reference/manifest-v1.md),
  [JSON v1](docs/reference/json-v1.md), and
  [compatibility](docs/reference/compatibility.md).

`verify` compares the declared plan with the migration ledger. It is not a schema snapshot
or database-state equivalence checker. Back up the database before deployment or history
import, use a maintenance window for predecessor cutovers, and treat `Running` after a
crash as operationally ambiguous until an operator inspects the database.

## Release status

Version [`1.0.0.0`](https://github.com/shinzui/pg-migrate/releases/tag/v1.0.0.0) is the
first stable release. All six packages and their Haddocks are published on Hackage. Add
only the packages an application needs; for example, a migration-owning library can use:

```cabal
build-depends:
    pg-migrate        >=1.0 && <1.1
  , pg-migrate-embed  >=1.0 && <1.1
```

Package versions are independent of the ledger, manifest, and JSON contract versions,
which are each currently v1. The complete release gate covers source distributions,
Haddocks, production dependency closure, documentation, and the fifteen-group acceptance
matrix on both PostgreSQL 17 and 18. See the [release policy](docs/reference/release-policy.md),
[acceptance matrix](docs/acceptance-matrix.md), and
[release checklist](docs/release-checklist.md).

## Goals

- Give migration names component-local scope, so independently versioned libraries can
  own their schema changes.
- Embed exact SQL bytes in the executable and protect applied history with SHA-256
  checksums.
- Apply transactional migrations and their ledger rows atomically.
- Model interrupted nontransactional migrations explicitly and require audited repair.
- Serialize complete plans with a session-level PostgreSQL advisory lock on one dedicated
  Hasql connection.
- Expose structured errors, events, reports, and reusable CLI parsers instead of owning
  application logging, configuration, or exit policy.
- Import existing Codd and `hasql-migration` history through optional adapters without
  coupling predecessor engines to the core runner.

The current v1 contracts target the GHC 9.12.4 project toolchain and PostgreSQL 17 and 18.
They intentionally exclude down migrations, automatic retries or repair, arbitrary `IO`
migrations, runtime filesystem discovery, and whole-database schema snapshot comparison.

## Design overview

A migration-owning library exports a `MigrationComponent`. Each component has a stable
name, an ordered non-empty migration list, and dependencies on other components. The
application assembles components into the final order, validates the resulting plan, and
passes it to the runner.

At runtime, the runner acquires one dedicated Hasql connection and one session advisory
lock for the complete plan. It verifies the embedded plan against the versioned
`pg_migrate` ledger before executing unapplied migrations. Transactional and
nontransactional SQL follow separate durable state machines; no recovery path silently
assumes that interrupted nontransactional SQL is safe to replay.

The central boundary is deliberate: core execution understands only the native plan and
ledger. Compatibility with predecessor migration engines lives in separate packages that
translate verified source evidence into the generic history-import model.

## Documentation and roadmap

- [Initial specification](docs/initial-spec.md) defines the normative v1 behavior and
  public contracts.
- [Core engine MasterPlan](docs/masterplans/1-build-pg-migrate-v1-core-engine.md) records
  the model, embedding, ledger, runner, repair, and generic history import.
- [Integrations and release MasterPlan](docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md)
  records the CLI, predecessor adapters, test support, acceptance matrix, and release
  documentation.
- [Ecosystem migration MasterPlan](docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md)
  covers staged adoption by Kiroku, Keiro, and PGMQ and the production cutover.
- [ExecPlans](docs/plans/) contain the self-contained implementation steps and acceptance
  criteria for each delivery slice.

## Development

The repository provides a Nix flake for the development environment:

```console
nix develop
```

Build the package and run the unit suite from that shell:

```console
cabal build all
just unit
```

Project identity and dependency metadata live in [`mori.dhall`](mori.dhall). Use `mori`
to locate registered dependency source and documentation when working on the
implementation:

```console
mori show --full
mori registry list
```
