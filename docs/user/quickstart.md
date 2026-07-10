# Quickstart

Add `pg-migrate`, `pg-migrate-embed`, and `pg-migrate-cli` to the application. Put SQL in
an ordered manifest and embed its exact bytes:

```haskell
{-# LANGUAGE TemplateHaskell #-}

entries = $(embedMigrationManifest "migrations/manifest")

component = migrationComponentFromEmbeddedSql "accounts" Set.empty entries
plan = component >>= migrationPlan . (:| [])
```

The application—not the library—reads its database configuration and mounts
`migrationCommandParser plan`. Construct `cliEnvironment settings plan defaultRunOptions`,
dispatch with `runMigrationCommand`, render text or JSON, and translate `exitClass` to the
process exit code. See [`examples/basic/app/Main.hs`](../../examples/basic/app/Main.hs).

To try the example in the development shell:

```bash
nix develop
process-compose up -D
cabal run pg-migrate-basic-example -- --help
DATABASE_URL="$PG_CONNECTION_STRING" cabal run pg-migrate-basic-example -- up
DATABASE_URL="$PG_CONNECTION_STRING" cabal run pg-migrate-basic-example -- up
DATABASE_URL="$PG_CONNECTION_STRING" cabal run pg-migrate-basic-example -- verify
```

The first `up` reports `AppliedNow`; the second reports `AlreadyApplied`. `verify` succeeds
when the ledger is an exact applied prefix of the current plan with matching checksums,
kinds, modes, positions, and no disallowed unknown rows. It does not compare live schema
objects with SQL source.

Deploy migrations as an explicit pre-deployment or administrative job. Do not make
service-startup migration execution the primary production path: multiple replicas,
timeouts, and nontransactional crash ambiguity require operator-visible orchestration.
