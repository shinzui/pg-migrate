---
id: 1
slug: bootstrap-the-pg-migrate-workspace-and-pure-model
title: "Bootstrap the pg-migrate workspace and pure model"
kind: exec-plan
created_at: 2026-07-10T15:50:23Z
intention: "intention_01kx6bkse1end9hcygcaemmtqc"
master_plan: "docs/masterplans/1-build-pg-migrate-v1-core-engine.md"
---

# Bootstrap the pg-migrate workspace and pure model

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan turns the current specification-only repository into a compiling GHC 9.12
package with the pure vocabulary needed by every later feature. A library author can
construct validated component and migration names, define SQL or constrained Haskell
migration actions, group them into components, and compose an explicitly ordered plan.
Invalid identifiers, duplicate names, missing or backward dependencies, and cycles are
reported as structured values without `IO`. The result is visible by running the unit
suite, which includes examples where explicit order is preserved and a stable topological
resolver changes only dependency-constrained order.


## Progress

- [x] (2026-07-10 10:12 PDT) Milestone 1: established the workspace, package, empty test
  harness, Nix override, Just recipes, and pre-release README; `nix develop -c cabal
  build all` succeeds with GHC 9.12.4.
- [x] (2026-07-10 10:20 PDT) Milestone 2: implemented opaque validated names, identities,
  constrained Hasql actions, components, and raw SHA-256 fingerprints.
- [x] (2026-07-10 10:20 PDT) Milestone 3: implemented explicit plan validation, stable
  topological resolution, distinct structured errors, and read-only plan descriptions.
- [x] (2026-07-10 10:20 PDT) Milestone 4: completed 34 focused definition, ordering,
  property, metadata, and public-API tests; the suite passes under GHC 9.12.4.
- [x] (2026-07-10 10:29 PDT) Final validation: `mori validate`, `mori show --full`,
  `nix fmt -- --fail-on-change`, `nix develop -c cabal build all`, two consecutive unit
  runs, `nix build .#default`, and `nix flake check --no-build` all succeeded.


## Surprises & Discoveries

- Observation: crypton 1.1.2's `Digest` implements `ByteArrayAccess` from `ram`, not from
  the older `memory` package despite the familiar `Data.ByteArray` module name.
  Evidence: the first model build rejected `memory`'s `convert`; the registered crypton
  source documents the `ram` instance in `Crypto/Hash/Types.hs`, and `ram` 0.20 provides
  the matching `Data.ByteArray.convert`.

- Observation: nixpkgs' GHC 9.12 package set contains crypton 1.0.6 and Hasql 1.9.3.1,
  which cannot satisfy the v1 bounds, while postgresql-binary's upstream test suite
  assumes a running PostgreSQL server and fails in a pure Nix build.
  Evidence: the first corrected-subdirectory Nix build reported the two version-bound
  failures; after pinning the local-corpus versions it reached postgresql-binary tests,
  where 76 round trips failed with `no connection to the server`.


## Decision Log

- Decision: Keep `pg-migrate.cabal` and the core source tree under `pg-migrate/`, matching
  the registered Mori package path.
  Rationale: The existing generated `nix/haskell.nix` assumes a root package, so add a
  project-owned `flake.module.nix` override for the default package rather than contradict
  `mori.dhall` or editing seihou-managed Nix modules.
  Date: 2026-07-10

- Decision: Preserve user-supplied component order in `migrationPlan` and provide stable
  automatic ordering only through `resolveMigrationPlan`.
  Rationale: Unrelated component order belongs to the final executable, as required by
  sections 7 and 8 of `docs/initial-spec.md`.
  Date: 2026-07-10

- Decision: Depend directly on `ram` for raw SHA-256 digest conversion.
  Rationale: crypton 1.1.2 derives its digest byte-array instance from `ram`; a direct
  dependency is required to persist the exact 32 digest bytes without using crypton
  internals or rendering hexadecimal text.
  Date: 2026-07-10

- Decision: Expose only read-only checksum and plan-description details from
  `Database.PostgreSQL.Migrate.Internal` while keeping every validated input constructor
  hidden.
  Rationale: EP-3 needs exact ledger metadata and the unit suite needs deterministic plan
  evidence, but neither requires a path to construct invalid names, migrations,
  components, or plans.
  Date: 2026-07-10

- Decision: Pin crypton 1.1.2, Hasql 1.10.3.5, hasql-transaction 1.2.2, and
  postgresql-binary 0.15.0.1 in the project-owned Nix package override, and disable only
  those dependencies' upstream checks.
  Rationale: these are the versions validated from the registered source corpus. Their
  upstream checks are not hermetic, while `pg-migrate`'s own 34-test suite remains
  enabled and passes inside `nix build .#default`.
  Date: 2026-07-10


## Outcomes & Retrospective

EP-1 is complete. The repository now has a GHC 9.12.4 Cabal workspace and reproducible
Nix package; opaque validated identifiers and action-bearing migrations; component-local
identity; explicit and stable dependency-aware plans; raw SHA-256 fingerprints; and a
read-only description boundary for later ledger work. The 34-test suite covers every
identifier rule, the known SHA-256 `abc` vector, duplicate and dependency errors, caller
order, stable resolution, metadata positions, and construction through only the singular
public API.

The main implementation lesson is that matching Cabal and Nix dependency graphs must be
verified independently: the development shell resolved the required Hackage releases,
while nixpkgs needed explicit source pins and hermetic-check policy. SQL construction is
intentionally still absent; `docs/plans/2-validate-sql-and-embed-ordered-manifests.md`
owns `sqlMigration`, SQL lexical validation, and embedded manifests.


## Context and Orientation

The repository currently has no `.cabal` file, `cabal.project`, Haskell source, or tests.
It does have a committed and registered `mori.dhall` plus `mori/repo-id` identifying
`shinzui/pg-migrate` and all six planned package directories.
`docs/initial-spec.md` is the normative product contract. `flake.nix` imports
`nix/haskell.nix`, which supplies GHC 9.12.4 but currently points `callCabal2nix` at the
repository root. The Mori identity places the core package at `./pg-migrate`, so resolve
that mismatch in project-owned `flake.module.nix` with a forced default-package definition
targeting the subdirectory; do not edit the seihou-managed module. `nix/treefmt.nix`
enables Fourmolu and `cabal-fmt` through `nix fmt`. `process-compose.yaml` starts a local PostgreSQL server and calls
`just create-database`, but no `Justfile` exists yet; add it in this plan so later
database plans have one repeatable entry point.

The implementation follows the local corpus at
`mori://shinzui/haskell-jitsurei/docs/core-standards`,
`mori://shinzui/haskell-jitsurei/docs/core-custom-prelude`, and
`mori://shinzui/haskell-jitsurei/docs/core-record-patterns`. Use GHC2024, the shared
extensions from the specification, postpositive qualified imports, strict unprefixed
record fields, and explicit deriving strategies. `PackageImports` belongs only in
`pg-migrate/src/PgMigrate/Prelude.hs`; import `Data.Generics.Labels ()` only in a module that uses
generic-lens labels.

A migration component is the ordered, non-empty migration history owned by one Haskell
package. A migration plan is the final executable's ordered, non-empty list of components.
A component dependency means the dependency's complete current history must run before
the dependent component. Migration names are local to a component; the globally unique
identity is the pair `(component, migration)`.


## Plan of Work

Milestone 1 establishes a healthy project. Validate the existing registered identity with
`mori validate`, `mori show --full`, and `mori status`; do not reinitialize it. Create
`cabal.project` with package `pg-migrate`, GHC
9.12.4, tests enabled, and benchmarks disabled by default. Create `pg-migrate.cabal` with a
shared `common common` stanza using GHC2024 and the extensions in section 4 of the
specification. Create `pg-migrate/pg-migrate.cabal`,
`pg-migrate/src/PgMigrate/Prelude.hs`,
`pg-migrate/src/Database/PostgreSQL/Migrate.hs`, an empty internal module layout, and
`pg-migrate/test/unit/Main.hs`. Add project-owned `flake.module.nix` that uses `lib.mkForce`
to point `packages.default` at `inputs.self + "/pg-migrate"`, preserving the generated Nix
files. Add `Justfile` recipes for
idempotent local database creation, formatting, unit tests, and all tests. Add a concise
`README.md` that labels the package pre-release and points at `docs/initial-spec.md`.
At this milestone `nix develop -c cabal build all` and the empty test harness pass.

Milestone 2 implements the model in
`pg-migrate/src/Database/PostgreSQL/Migrate/Types.hs` and smart constructors in
`pg-migrate/src/Database/PostgreSQL/Migrate/Definition.hs`. Keep constructors internal for
`ComponentName`, `MigrationName`, `MigrationChecksum`, `Migration`, and
`MigrationComponent`. Validate that identifiers are non-empty printable ASCII, unchanged
by trimming, exclude `/` and control characters, and occupy at most 200 UTF-8 bytes.
Represent `SqlAction ByteString`, `TransactionAction (Hasql.Transaction.Transaction ())`,
and `SessionAction (Hasql.Session.Session ())` without inventing `Eq` or `Show` instances
for executable actions. Implement `migrationFingerprint` with crypton's SHA-256 and the
manual `transactionMigration`, `sessionMigration`, `migrationComponent`, and identity
constructors. `sqlMigration` is completed by
`docs/plans/2-validate-sql-and-embed-ordered-manifests.md`; expose no unsafe placeholder.

Milestone 3 implements `pg-migrate/src/Database/PostgreSQL/Migrate/Plan.hs`. `migrationPlan`
preserves input order and returns a distinct `PlanError` for duplicate components,
duplicate local migration names, missing dependencies, dependencies placed after their
consumer, and cycles. `resolveMigrationPlan` performs a stable topological sort: among
currently available components it selects the earliest item in caller order. Add an
internal read-only plan description accessor containing identities, positions, checksum,
kind, and transaction mode for future ledger code; it must not reveal executable actions
publicly. Re-export only the safe surface from `Database.PostgreSQL.Migrate` and test
constructor opacity by compiling a small public-API fixture.

Milestone 4 fills `pg-migrate/test/unit/Main.hs` and focused modules under
`pg-migrate/test/unit/Test/`.
Table-driven tests cover every validation error. Property tests permute unrelated
components to prove explicit order preservation and repeat the same input to prove stable
resolution. A regression test creates identical local names in two different components
and proves they are valid, while duplicate local names inside one component fail.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`. Reconfirm the dependency corpus before
editing, then enter the project shell:

```bash
mori registry show hasql/hasql --full
mori registry show kazu-yamamoto/crypton --full
mori registry show UnkindPartition/tasty --full
mori validate
mori show --full
mori status
nix develop
```

After Milestone 1, format and build:

```bash
nix fmt
cabal build all
cabal test pg-migrate:pg-migrate-unit
```

Expected final shape:

```text
Build profile: ...
In order, the following will be built ... pg-migrate-0.1.0.0 ...
Test suite pg-migrate-unit: PASS
1 of 1 test suites (1 of 1 test cases) passed.
```

Before stopping, update Progress, Decision Log, Surprises & Discoveries, and Outcomes as
appropriate. Commits must be Conventional Commits and include:

```text
MasterPlan: docs/masterplans/1-build-pg-migrate-v1-core-engine.md
ExecPlan: docs/plans/1-bootstrap-the-pg-migrate-workspace-and-pure-model.md
Intention: intention_01kx6bkse1end9hcygcaemmtqc
```


## Validation and Acceptance

Acceptance requires `mori validate` and `mori show --full` to identify
`shinzui/pg-migrate`, plus `nix fmt -- --fail-on-change` or the repository's equivalent
check, `cabal build all`, and `cabal test pg-migrate:pg-migrate-unit` to pass. The tests must show
that `componentName " event-store"` fails for surrounding whitespace, a 201-byte name
fails, and `migrationId "event-store" "0001-bootstrap"` succeeds. A component with two
`0001` migrations fails, while two components can each own `0001`.

For plans, `[event-store, event-sourcing]` succeeds when the latter depends on the former;
the reversed order fails with an invalid-order error; an absent dependency and a cycle
have different errors. Given caller order `[queue, event-store, event-sourcing]`, the
stable resolver keeps `queue` before `event-store` because only the last dependency edge
constrains order. Run the unit suite twice and require the same serialized plan
description both times.


## Idempotence and Recovery

All edits are ordinary source additions. Cabal builds, formatting, and tests are safe to
repeat. `just create-database` must tolerate an already-existing local database rather than
drop it. Keep the registered `./pg-migrate` package path; resolve Nix output composition in
the unmanaged `flake.module.nix` and update `cabal.project` rather than editing generated
Nix modules. Preserve unrelated repository changes.


## Interfaces and Dependencies

Use `hasql >= 1.10 && < 1.11`, `hasql-transaction >= 1.2 && < 1.3`, crypton for SHA-256,
and `tasty`, `tasty-hunit`, and `tasty-quickcheck` only in tests. The locally registered
Hasql source exposes `Hasql.Connection.Settings.Settings`, `Hasql.Session.Session`, and
`Hasql.Transaction.Transaction`; do not rely on pre-1.10 `Session.run` or public
`Statement` constructors.

The public module `Database.PostgreSQL.Migrate` must expose opaque input types and these
functions by the end of this plan:

```haskell
componentName :: Text -> Either DefinitionError ComponentName
migrationName :: Text -> Either DefinitionError MigrationName
migrationId :: Text -> Text -> Either DefinitionError MigrationId
migrationFingerprint :: ByteString -> MigrationChecksum
transactionMigration :: Text -> MigrationChecksum -> Hasql.Transaction.Transaction () -> Either DefinitionError Migration
sessionMigration :: Text -> MigrationChecksum -> Hasql.Session.Session () -> Either DefinitionError Migration
migrationComponent :: Text -> Set Text -> NonEmpty Migration -> Either DefinitionError MigrationComponent
migrationPlan :: NonEmpty MigrationComponent -> Either PlanError MigrationPlan
resolveMigrationPlan :: NonEmpty MigrationComponent -> Either PlanError MigrationPlan
```


## Revision Note

2026-07-10: Updated the living sections throughout implementation, recorded the crypton
and Nix dependency discoveries, and finalized the plan after all acceptance commands
passed. The intended behavior and milestone scope did not change.
