# pg-migrate

`pg-migrate` is a Hasql-native PostgreSQL migration toolkit for applications that own an
explicit, compile-time migration plan. Libraries export ordered components; applications
compose them, configure the database connection, and mount the reusable CLI. The runner is
forward-only, uses ledger schema v1, and supports PostgreSQL 17 and 18.

The 1.0 package set is:

- `pg-migrate`: validated plans, runner, ledger, repair, inspection, and generic import.
- `pg-migrate-embed`: manifest v1 validation, exact-byte embedding, and authoring.
- `pg-migrate-cli`: reusable command parser, dispatcher, text output, and JSON schema v1.
- `pg-migrate-import-codd`: Codd V1–V5 source adapter.
- `pg-migrate-import-hasql-migration`: base64-MD5 predecessor adapter.
- `pg-migrate-test-support`: opt-in `ephemeral-pg` test helper.

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

The release-blocking command is `just acceptance`; CI runs it independently on PostgreSQL
17 and 18. See the [acceptance matrix](docs/acceptance-matrix.md) and
[release checklist](docs/release-checklist.md).

`pg-migrate` is a planned Hasql-native PostgreSQL migration library for Haskell.
Libraries own and embed named migration components; applications compose those
components into an explicit, deterministic migration plan and run it through one
dedicated PostgreSQL connection.

> [!IMPORTANT]
> The project is currently in pre-release implementation. There is no supported
> release or stable library API yet.

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

Version 1 targets GHC 9.12 or newer and PostgreSQL 17 and 18. It intentionally excludes
down migrations, automatic retries or repair, arbitrary `IO` migrations, runtime
filesystem discovery, and whole-database schema snapshot comparison.

## Planned packages

| Package | Responsibility |
| --- | --- |
| `pg-migrate` | Core model, plan validation, ledger, runner, repair, and generic history import |
| `pg-migrate-embed` | Template Haskell support for embedding ordered SQL manifests |
| `pg-migrate-cli` | Reusable `optparse-applicative` parsers and command handlers |
| `pg-migrate-import-codd` | Optional Codd history-import adapter |
| `pg-migrate-import-hasql-migration` | Optional `hasql-migration` history-import adapter |
| `pg-migrate-test-support` | `ephemeral-pg` helpers kept outside the production dependency closure |

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
- [Core engine MasterPlan](docs/masterplans/1-build-pg-migrate-v1-core-engine.md) covers
  the model, embedding, ledger, runner, repair, and generic history import.
- [Integrations and release MasterPlan](docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md)
  covers the CLI, predecessor adapters, test support, acceptance matrix, and release
  documentation.
- [Ecosystem migration MasterPlan](docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md)
  covers staged adoption by Kiroku, Keiro, and PGMQ and the production cutover.
- [ExecPlans](docs/plans/) contain the self-contained implementation steps and acceptance
  criteria for each delivery slice.

Implementation starts with
[bootstrapping the workspace and pure model](docs/plans/1-bootstrap-the-pg-migrate-workspace-and-pure-model.md).

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
