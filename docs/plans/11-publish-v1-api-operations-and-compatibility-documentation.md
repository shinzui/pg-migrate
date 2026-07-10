---
id: 11
slug: publish-v1-api-operations-and-compatibility-documentation
title: "Publish v1 API operations and compatibility documentation"
kind: exec-plan
created_at: 2026-07-10T15:50:25Z
intention: "intention_01kx6bkssqee4sz0gzw0tdvkkv"
master_plan: "docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md"
---

# Publish v1 API operations and compatibility documentation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

This plan makes the tested implementation releasable and operable. Library authors receive
an API and manifest authoring guide; application owners receive CLI integration examples;
operators receive lock, timeout, repair, import, maintenance-window, and recovery runbooks;
and machine consumers receive checked ledger, manifest, and JSON version contracts. The
compatibility table names PostgreSQL 17 and 18 and explains the future-major policy. Cabal
checks, Haddocks, source distributions, examples, and every documented command are
validated before the v1 contract is declared ready.


## Progress

- [x] Audited every public facade, added module and per-symbol Haddocks, exposed the
  independent ledger, manifest, and JSON version constants, and hid internal bridge
  modules from user documentation. All seven public modules report 100% coverage.
- [x] Added the README map, six user guides, six operator/import runbooks, seven contract
  references, release policy, and a checked release checklist.
- [x] Added and ran the two-component example through help, first apply, idempotent second
  apply, and strict verify against PostgreSQL 17.
- [x] Set all six production packages to `1.0.0.0`, bounded internal dependencies, added
  changelogs and distribution metadata, and made the example and recompilation fixture
  source-distribution-safe.
- [x] Passed warning-free `cabal check`, 100%-coverage public Haddocks, offline link checks,
  source distribution generation and unpacked build/test on PostgreSQL 17 and 18, Mori
  validation/registration, production closure, and both fifteen-group acceptance gates.
- [x] Updated `agents/skills/release/SKILL.md` from its original three-package,
  pre-1.0 workflow to the six-package dependency order, independent contract policy,
  complete local release gate, and separate commit/publication approvals.


## Surprises & Discoveries

- Observation: the initial Haddock build succeeded while reporting only one or two percent
  coverage for the main facades. Treating that output as a release defect produced
  per-symbol public documentation and explicit hiding for internal bridge modules.

- Observation: `cabal check` rejected extensionless fixture globs even though checkout
  builds accepted them. Enumerating manifests and extension-bearing files made the embed
  package portable to Hackage tooling.

- Observation: the recompilation test assumed checkout directory names and failed from
  versioned source-distribution directories. It now resolves either layout and both server
  matrices build and test solely from unpacked tarballs.

- Observation: full parallel acceptance could delay the crash helper beyond its original
  five-second observation window. A fifteen-second bounded poll preserves the same durable
  `Running` assertion while removing scheduler-dependent flakiness.

- Observation: the repository release skill predated both adapters and test support, and
  still prescribed an incomplete three-package workflow. Synchronizing it with the checked
  release policy prevents future automation from bypassing the v1 artifact and matrix
  gates.

- Observation: the generated `packages.default` assumes a Cabal package at the repository
  root, so `nix flake check` does not model this multi-package workspace. The synchronized
  skill uses the actual Cabal, unpacked-sdist, closure, and two-major gates instead.


## Decision Log

- Decision: Document ledger, manifest, and JSON formats as independent versioned
  contracts.
  Rationale: They have different consumers and may evolve on different schedules even when
  released by the same package set.
  Date: 2026-07-10

- Decision: Describe `verify` only as declared-plan versus ledger verification.
  Rationale: Schema snapshot equality is an explicit non-goal and misleading wording would
  create an unsafe operator expectation.
  Date: 2026-07-10

- Decision: Require separate approval for the release commit and for external publication.
  Rationale: A locally verified candidate does not itself authorize tags, pushes, Hackage
  uploads, documentation uploads, or a GitHub release.
  Date: 2026-07-10


## Outcomes & Retrospective

The six-package v1 surface is release-ready but not published. Each package is versioned
`1.0.0.0`, its public facade has complete Haddock coverage, and the three independent
machine/on-disk contracts expose version 1 from code. Users have a runnable application
example and task-oriented guides; operators have deployment, locking, repair, and both
history-import runbooks; contract consumers have ledger, manifest, JSON, compatibility,
error/event, and release-policy references.

The strongest release proof came from checking distribution artifacts rather than only the
checkout: that found and fixed both invalid Cabal globs and a repository-layout assumption.
Fresh unpacked tarballs passed their full suites on PostgreSQL 17 and 18. Mori now resolves
all six packages and the release documentation through `mori://shinzui/pg-migrate`.
Publishing remains a separate explicitly authorized operator action. The invocable release
skill now enforces the same six-package scope and evidence boundary.


## Context and Orientation

Complete `docs/plans/10-provide-ephemeral-postgresql-test-support-and-acceptance-matrix.md`
first. At that point the repository contains the core `pg-migrate/` package and five optional
packages: embed, CLI, Codd adapter, `hasql-migration` adapter, and test support. The
acceptance matrix is evidence for every public claim. `docs/initial-spec.md` remains the
normative design source, but release docs must stand alone for users.

The repository currently began with only `docs/initial-spec.md` and no README suitable for
users. Create a stable documentation map rather than one oversized README. Semantic
versioning applies to Haskell public API, ledger schema/migrations, ordered manifest format,
JSON schemas, and import mapping behavior. PostgreSQL v1 supports 17 and 18. A newer stable
major becomes supported only after entering the matrix; below 17 and stable majors newer
than the matrix are rejected. Removing an end-of-life major requires at least one minor
release of notice and a compatibility-table update.


## Plan of Work

Milestone 1 audits code and Haddocks. Ensure `Database.PostgreSQL.Migrate` presents the
safe common facade and that repair/history operations are reachable through documented
public modules. Hide constructors for identifiers, migrations, components, plans, options,
providers, and configs; expose immutable event/report/status/import outputs. Add module
Haddocks explaining atomicity and ambiguity. Run `cabal haddock all` with warnings treated
as release defects.

Milestone 2 writes user guides: update `README.md`; add `docs/user/quickstart.md`,
`component-authoring.md`, `manifest-authoring.md`, `plan-composition.md`,
`cli-integration.md`, and `testing.md`. Include a runnable example package under
`examples/basic/` that embeds two components, declares one dependency, mounts CLI parsing,
and receives connection settings from its own configuration. It must not imply migration
discovery or service-startup execution as the primary deployment path.

Milestone 3 writes operator/import guides:
`docs/operations/deployment.md`, `locking-and-timeouts.md`,
`nontransactional-repair.md`, `history-import.md`, `codd-import.md`, and
`hasql-migration-import.md`. State backup, quiescence, lock ordering, evidence selection,
confirmation, reason, audit, strict verify, and forward-only recovery procedures. Include
the durable Running ambiguity and warn that repair never bypasses checksum mismatch.

Milestone 4 freezes references: `docs/reference/public-api.md`, `ledger-v1.md`,
`manifest-v1.md`, `json-v1.md`, `errors-and-events.md`, and `compatibility.md`. Copy no
large implementation source; describe fields, constraints, ordering, version constants,
and upgrade guarantees. Add JSON examples generated by
`docs/plans/7-build-the-reusable-migration-cli-and-json-contracts.md`. Add
`docs/reference/release-policy.md` for semantic versioning and advance notice.

Milestone 5 prepares release artifacts. Update `mori.dhall` so `shinzui/pg-migrate`
describes all six packages, internal package dependencies, Hasql/crypton/optparse sources,
the test-only `ephemeral-pg` relationship, and user/reference docs. Run `mori validate`,
`mori show --full`, and `mori register` so the downstream rollout plans can resolve
`mori://shinzui/pg-migrate` rather than rely on an absolute source path. Then set coherent
initial package versions and bounds,
update each changelog, run `cabal check` in every package, build Haddocks and `sdist`, unpack
the source distributions in a temporary directory, and build/test from them on both server
majors. Run link/command/example checks and the complete acceptance gate. Produce a checked
`docs/release-checklist.md`; publishing to Hackage or GitHub remains a separate authorized
operator action.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`:

```bash
nix develop
nix fmt
cabal haddock all
cabal check
cabal sdist all
mori validate
mori show --full
mori register
just acceptance
```

Run the documented example and both explicit server matrices:

```bash
cabal run pg-migrate-basic-example -- --help
nix develop .#postgresql17 -c just acceptance
nix develop .#postgresql18 -c just acceptance
```

Expected release gate:

```text
all Haddocks built
all source distributions pass cabal check
PostgreSQL 17 acceptance: PASS
PostgreSQL 18 acceptance: PASS
documentation examples: PASS
```

Commits require:

```text
MasterPlan: docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md
ExecPlan: docs/plans/11-publish-v1-api-operations-and-compatibility-documentation.md
Intention: intention_01kx6bkssqee4sz0gzw0tdvkkv
```


## Validation and Acceptance

Every public identifier resolves in Haddocks, every documented command is accepted by the
actual parser, and every output excerpt is generated or checked by tests. The quickstart
builds and applies once on a fresh temporary database, then reports AlreadyApplied. The
verify docs never promise schema equality. Repair/import runbooks include reason,
confirmation, audit, backup, and quiescence requirements.

Reference docs exactly match ledger constraints, manifest rejection rules, and JSON
goldens. Compatibility says 17 and 18 supported and describes future addition/removal.
Unpacked sdists build without repository-only files. The production closure check passes.
`mori registry show shinzui/pg-migrate --full` resolves all six packages and their docs.
No publish/upload is performed by this plan unless separately authorized.


## Idempotence and Recovery

Documentation generation, Haddocks, checks, sdists, examples, and acceptance are
repeatable. Generate machine examples from tested values to avoid hand-edited drift. Build
sdists in temporary directories and do not delete existing release artifacts outside
`dist-newstyle`. If a public contract changes during this plan, update code/tests first,
record the decision in both MasterPlan and child plan, then regenerate docs; do not make
documentation silently redefine implementation.


## Interfaces and Dependencies

This plan adds no runtime library. It consumes all six packages and Cabal tooling. The
release must document at least these stable surfaces: `Database.PostgreSQL.Migrate`,
`Database.PostgreSQL.Migrate.Embed`, `Database.PostgreSQL.Migrate.CLI`,
`Database.PostgreSQL.Migrate.History`,
`Database.PostgreSQL.Migrate.History.Codd`,
`Database.PostgreSQL.Migrate.History.HasqlMigration`, and
`Database.PostgreSQL.Migrate.Test`.

The reference version constants must be discoverable from code and documentation:

```haskell
ledgerSchemaVersion :: Int
jsonSchemaVersion :: Int
manifestFormatVersion :: Int
```

If the manifest remains an implicit v1 format with no marker in each file, expose and
document the library-supported format version rather than adding an unrequested header.


## Revision Note

2026-07-10: Completed the public API audit, documentation map, guides, runbooks, references,
example, coherent `1.0.0.0` package metadata, source-distribution portability fixes, Mori
registration, and the PostgreSQL 17/18 release gates without publishing artifacts.

2026-07-10: Synchronized the disabled-by-default release skill with the completed v1
package graph, contract policy, local gates, approval boundaries, and six-package Hackage
publication order.
