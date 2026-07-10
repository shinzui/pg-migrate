---
id: 2
slug: deliver-pg-migrate-v1-integrations-and-release
title: "Deliver pg-migrate v1 integrations and release"
kind: master-plan
created_at: 2026-07-10T15:50:24Z
intention: "intention_01kx6bkssqee4sz0gzw0tdvkkv"
---

# Deliver pg-migrate v1 integrations and release

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

After this initiative, an application can mount a reusable `optparse-applicative` command
tree for planning, inspection, execution, repair, and authoring; operators can consume
versioned text or JSON output; Codd and `hasql-migration` databases can be imported through
maintained Hasql-only adapters; and tests can start a fresh PostgreSQL instance through a
small `ephemeral-pg` helper without pulling test dependencies into production packages.
The complete release is exercised on PostgreSQL 17 and 18 and documented with stable API,
ledger, manifest, JSON, compatibility, upgrade, and operational contracts.

This wave starts only after
`docs/masterplans/1-build-pg-migrate-v1-core-engine.md` is complete. It owns the
`pg-migrate-cli/`, `pg-migrate-import-codd/`,
`pg-migrate-import-hasql-migration/`, and `pg-migrate-test-support/` packages plus the
repository-level acceptance matrix and release documentation. It does not change Kiroku,
Keiro, PGMQ, or a production database; those actions belong to
`docs/masterplans/3-migrate-initial-ecosystem-to-pg-migrate.md`. It also does not add
schema snapshot comparison to the runner or introduce a standalone executable that tries
to discover another package's embedded plan.


## Decomposition Strategy

EP-7 owns the reusable parser, rendering, command dispatch values, and versioned JSON
schemas. EP-8 and EP-9 are separate because Codd has multiple ledger generations,
partial nontransactional evidence, and a legacy advisory lock, whereas
`hasql-migration` has a qualified table, base64 MD5 payload evidence, duplicate-row risk,
and alternative-history validation. They can proceed in parallel against the generic
import API. EP-10 owns the public test-support dependency boundary and the cross-package,
cross-PostgreSQL acceptance suite. EP-11 freezes and explains the contracts only after
the acceptance matrix proves them.

Combining both adapters was rejected because it would obscure their different safety
proofs and make fixtures harder to review. Putting test support into the core package was
rejected because `ephemeral-pg` must not enter the production closure. Folding docs into
each implementation plan remains useful for local Haddocks, but a final contract review
is still required because ledger, manifest, JSON, and compatibility promises span every
package.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 7 | Build the reusable migration CLI and JSON contracts | docs/plans/7-build-the-reusable-migration-cli-and-json-contracts.md | None | None | Complete |
| 8 | Import Codd history through the adapter | docs/plans/8-import-codd-history-through-the-adapter.md | None | EP-7 | Complete |
| 9 | Import hasql-migration history through the adapter | docs/plans/9-import-hasql-migration-history-through-the-adapter.md | None | EP-7 | Complete |
| 10 | Provide ephemeral PostgreSQL test support and acceptance matrix | docs/plans/10-provide-ephemeral-postgresql-test-support-and-acceptance-matrix.md | EP-7, EP-8, EP-9 | None | Complete |
| 11 | Publish v1 API operations and compatibility documentation | docs/plans/11-publish-v1-api-operations-and-compatibility-documentation.md | EP-10 | None | Complete |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).


## Dependency Graph

The completed core MasterPlan is a hard initiative-level prerequisite: EP-7 needs the
runner, reports, status, verify, repair, and authoring APIs; EP-8 and EP-9 need the generic
history importer and opaque target-plan description. Once that prerequisite is met,
EP-7, EP-8, and EP-9 can proceed in parallel. Their soft links exist because adapter
command parsers should use EP-7's command and rendering conventions, but their library
APIs and fixture tests do not need to wait for it.

EP-10 follows all three so the acceptance suite can exercise real parser trees, both
adapter packages, JSON contracts, and the dependency-closure boundary rather than using
stubs. EP-11 follows EP-10 because public compatibility claims must describe observed,
passing behavior. No child in this registry may weaken a core invariant merely to make an
adapter or renderer easier.


## Integration Points

EP-7 owns `pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI.hs`, the
`MigrationCommand` tree, output selection, exit classification, and JSON schema version.
EP-8 and EP-9 add import subparsers through public adapter parsers rather than adding
source-specific constructors to the core runner. EP-10 owns golden JSON fixtures shared
by every command; EP-11 publishes the accepted schemas without changing them.

EP-8 and EP-9 consume the generic `HistoryImport`, `EvidenceRequirement`,
`PayloadRelation`, `ImportOptions`, and `importMigrationHistory` types owned by core EP-6.
Both adapters return structured source evidence and reports. They never manufacture target
checksums or import unknown target IDs. Only EP-8 may apply the extra Codd source lock, and
it must acquire that lock on a dedicated source connection before the generic importer
acquires the normal `pg-migrate` lock on its own dedicated target connection.

EP-10 owns `pg-migrate-test-support/src/Database/PostgreSQL/Migrate/Test.hs` and the CI
PostgreSQL 17/18 matrix. No production Cabal stanza may depend on this package or directly
on `ephemeral-pg`. EP-11 owns the compatibility table and release checklist, but versions
and schema constants remain defined in code by their implementation plans.


## Progress

- [x] EP-7: Built the reusable migration CLI and JSON contracts. The package now provides
  the grouped parser, typed command/handler/outcome boundary, public read-only core
  inspection operations, stable text, JSON schema version 1, six JSON and nine help
  goldens, parser-derived completions, and two live PostgreSQL command scenarios. All
  workspace gates and the legacy-free core-library closure audit pass.
- [x] EP-8: Imported Codd history through a Hasql-only adapter with exact V1–V5 catalog
  detection, legacy-source-first locking, manifest-backed payload evidence, pre-connection
  mapping validation, mountable parsing, and generic atomic target import. Eighteen pure
  tests and nine PostgreSQL fixtures prove source preservation, action-free audit writes,
  lock contention, strict/lenient selection, and idempotency; all workspace gates pass.
- [x] EP-9: Imported `hasql-migration` history through a Hasql-only adapter with safely
  quoted qualified tables, exact base64-MD5 payload verification, independent SHA-256
  evidence, local timestamp preservation, direct and validator-backed alternative routes,
  and generic atomic target import. Thirteen pure and six live tests pass with the full
  workspace matrix and predecessor-free production closure.
- [x] EP-10: Added the public ephemeral PostgreSQL helper, fresh callback-connection and
  structured failure proofs, all fifteen acceptance-group owners, schema-v1 import JSON,
  graph-aware production closure checking, and explicit PostgreSQL 17/18 Nix/CI jobs.
  `just acceptance` passes against PostgreSQL 17.10 and 18.4.
- [x] EP-11: Froze the six-package `1.0.0.0` API and version contracts, brought all public
  facades to complete Haddock coverage, published user/operator/reference documentation and
  a runnable two-component example, registered the six packages and docs with Mori, and
  proved checkout and unpacked-sdist suites on PostgreSQL 17 and 18 without publishing.


## Surprises & Discoveries

- Observation: the completed core initiative left its internal read-only ledger sessions
  without the public `migrationStatus` and `verifyMigrationPlan` operations named by the
  initial specification. EP-7 must add those public operations before its opaque
  `ConnectionProvider`-based handler can implement status and strict verify safely.

- Observation: EP-8's requirement to reject invalid checked-in target mappings before any
  source access exposed a missing pure target/prefix validator in the generic history API.
  The new `validateHistoryMappingTargets` operation shares the importer's target resolution
  logic without acquiring a connection.

- Observation: the current registered `hasql-migration` fork uses `ram`, not `memory`, for
  byte-array encoding. EP-9 follows that actual source dependency so crypton MD5 digests
  and base64 encoding share one `ByteArrayAccess` class.

- Observation: the first actual PostgreSQL 18 run found a live test that asserted major 17
  even though the version classifier accepted both supported majors. The matrix converted
  that latent assumption into a failing acceptance case before release documentation.

- Observation: testing unpacked source distributions found both Hackage-invalid fixture
  globs and a recompilation test coupled to checkout directory names. The release gate now
  proves the actual tarball layouts on both supported PostgreSQL majors.


## Decision Log

- Decision: Treat the completed core-engine MasterPlan as an initiative-level hard
  prerequisite instead of duplicating core work in this registry.
  Rationale: Child-plan dependencies are local to one registry, while every package in
  this wave compiles against artifacts delivered by the first MasterPlan.
  Date: 2026-07-10

- Decision: Keep Codd and `hasql-migration` in separate adapter packages that depend only
  on Hasql and `pg-migrate`, not on predecessor Haskell libraries.
  Rationale: This preserves the core production closure and makes the source evidence
  decoders fixture-testable independently of legacy implementation internals.
  Date: 2026-07-10

- Decision: Make JSON schema version 1 and the PostgreSQL 17/18 matrix release blockers.
  Rationale: Machine consumers and server-version rejection are public contracts, so they
  must be proven before documentation declares v1 stable.
  Date: 2026-07-10


## Outcomes & Retrospective

The integrations-and-release initiative is complete. Applications can mount the reusable
CLI and consume stable JSON v1; operators can import Codd V1–V5 and `hasql-migration`
history through source-preserving Hasql adapters; tests can use the isolated
`ephemeral-pg` support package; and all six packages expose coherent `1.0.0.0` contracts.

The final acceptance boundary covers fifteen ownership groups on PostgreSQL 17 and 18,
including production dependency closure and versioned goldens. Public facades have complete
Haddock coverage, source distributions build and test from versioned unpacked directories,
and Mori resolves all packages and release docs. No Hackage upload, tag, GitHub release, or
production database mutation was performed.


## Revision Note

2026-07-10: Started EP-7 after verifying that the core-engine initiative is complete and
that the optional CLI package has not yet been created.

2026-07-10: Recorded EP-7 Milestone 1 completion and the public core inspection API gap
that Milestone 2 must close.

2026-07-10: Recorded the EP-7 handler, text, JSON, golden, and completion checkpoint; kept
the database-backed command acceptance explicitly open.

2026-07-10: Marked EP-7 complete after the full workspace build and test matrix, exact help
and JSON goldens, repeatable live PostgreSQL CLI scenarios, formatting, and core-library
dependency-closure audit passed.

2026-07-10: Started EP-8, the next registry-ordered child with all hard dependencies met.

2026-07-10: Recorded EP-8 Milestone 1 completion and start of exact catalog/lock handling.

2026-07-10: Marked EP-8 complete after all V1–V5 fixtures, source-first locking, evidence,
preflight, audit, non-execution, source-preservation, idempotency, dependency-closure, and
full-workspace gates passed.

2026-07-10: Marked EP-9 complete after qualified-table, MD5/SHA-256, local timestamp,
direct/equivalent history, read-only validator, source-preservation, conflict,
dependency-closure, and full-workspace gates passed.

2026-07-10: Marked EP-10 complete after the test-support API, fifteen-group aggregate,
import JSON golden, closure gate and negative test, and real PostgreSQL 17/18 acceptance
jobs passed.

2026-07-10: Marked EP-11 and this MasterPlan complete after the API/documentation freeze,
warning-free package checks, complete public Haddocks, example and link checks, Mori
registration, unpacked-sdist tests, production closure, and PostgreSQL 17/18 acceptance.
