# pg-migrate

`pg-migrate` is a Hasql-native PostgreSQL migration toolkit for applications that own an
explicit, compile-time migration plan. Libraries export ordered components; applications
compose them, configure the database connection, and mount the reusable CLI. The runner is
forward-only, uses ledger schema v1, and supports PostgreSQL 17 and 18.

The package set is:

- [`pg-migrate`](https://hackage.haskell.org/package/pg-migrate): validated
  plans, runner, ledger, repair, inspection, and generic import.
- [`pg-migrate-embed`](https://hackage.haskell.org/package/pg-migrate-embed):
  manifest v1 validation, exact-byte embedding, and authoring.
- [`pg-migrate-cli`](https://hackage.haskell.org/package/pg-migrate-cli):
  reusable command parser, dispatcher, text output, and JSON schema v1.
- [`pg-migrate-import-codd`](https://hackage.haskell.org/package/pg-migrate-import-codd):
  Codd V1–V5 source adapter.
- [`pg-migrate-import-hasql-migration`](https://hackage.haskell.org/package/pg-migrate-import-hasql-migration):
  base64-MD5 predecessor adapter.
- [`pg-migrate-test-support`](https://hackage.haskell.org/package/pg-migrate-test-support):
  opt-in `ephemeral-pg` test helper.

Add only the packages an application needs; for example, a migration-owning library can use:

```cabal
build-depends:
    pg-migrate        >=1.1 && <1.2
  , pg-migrate-embed  >=1.1 && <1.2
```

Applications embedding manifests on GHC 9.12 must also load
`Database.PostgreSQL.Migrate.Embed.RecompilePlugin`, as described in
[manifest authoring](docs/user/manifest-authoring.md). The current release is
[`1.1.0.0`](https://github.com/shinzui/pg-migrate/releases/tag/v1.1.0.0); it is breaking
relative to `1.0.0.0`, so read each package's `CHANGELOG.md` before upgrading.

## Documentation

Start with the [user guide](docs/user/README.md), its
[quickstart](docs/user/quickstart.md), and the runnable [`examples/basic`](examples/basic).
The remaining documentation is organized by audience:

- Library authors: [component](docs/user/component-authoring.md),
  [manifest](docs/user/manifest-authoring.md), and
  [plan composition](docs/user/plan-composition.md).
- Application owners: [CLI integration](docs/user/cli-integration.md),
  [testing](docs/user/testing.md), and [troubleshooting](docs/user/troubleshooting.md).
- Operators: [deployment](docs/operations/deployment.md),
  [locks/timeouts](docs/operations/locking-and-timeouts.md),
  [repair](docs/operations/nontransactional-repair.md), and
  [history import](docs/operations/history-import.md).
- Contract consumers: [public API](docs/reference/public-api.md),
  [errors and events](docs/reference/errors-and-events.md),
  [ledger v1](docs/reference/ledger-v1.md),
  [manifest v1](docs/reference/manifest-v1.md),
  [JSON v1](docs/reference/json-v1.md),
  [compatibility](docs/reference/compatibility.md), and
  [release policy](docs/reference/release-policy.md).

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

The v1 contracts intentionally exclude down migrations, automatic retries or repair,
arbitrary `IO` migrations, runtime filesystem discovery, and schema snapshot comparison:
`verify` compares the declared plan with the migration ledger, not with the live schema.

## Design overview

A migration-owning library exports a `MigrationComponent`. Each component has a stable
name, an ordered non-empty migration list, and dependencies on other components. The
application assembles components into the final order, validates the resulting plan, and
passes it to the runner.

At runtime, the runner acquires one dedicated Hasql connection and one session advisory
lock for the complete plan. It verifies the embedded plan against the versioned ledger
(schema `pgmigrate` by default) before executing unapplied migrations. Transactional and
nontransactional SQL follow separate durable state machines; no recovery path silently
assumes that interrupted nontransactional SQL is safe to replay.

The central boundary is deliberate: core execution understands only the native plan and
ledger. Compatibility with predecessor migration engines lives in separate packages that
translate verified source evidence into the generic history-import model.

## Development

The repository provides a Nix flake for the development environment:

```console
nix develop
```

Build the packages, run the unit suite, and validate the OKF documentation bundles from
that shell:

```console
cabal build all
just unit
just docs
```

The [initial specification](docs/initial-spec.md) defines the normative v1 behavior.
Design history lives in [MasterPlans](docs/masterplans/) and [ExecPlans](docs/plans/);
releases follow the [release checklist](docs/release-checklist.md) and
[acceptance matrix](docs/acceptance-matrix.md). Project identity and dependency metadata
live in [`mori.dhall`](mori.dhall).
