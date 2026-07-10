---
name: release
description: Release all six pg-migrate packages to Hackage following PVP with explicit version and publication approvals
argument-hint: "[initial|major|minor|patch|A.B.C.D]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# pg-migrate Release Skill

Release the six `pg-migrate` packages to Hackage using the Haskell PVP version
scheme (`A.B.C.D`). This is a Nix and Cabal project using GHC 9.12.4. The public
Haskell API, ledger schema, ordered manifest, JSON schema, PostgreSQL support
matrix, and history-import evidence semantics are separate compatibility
surfaces. Read these checked-in contracts before proposing a release:

- `docs/reference/release-policy.md`
- `docs/reference/compatibility.md`
- `docs/release-checklist.md`
- the six package `CHANGELOG.md` files

Publishing, pushing, tagging, and creating a GitHub release are external
mutations. Preparing and validating a release does not authorize them. Obtain
explicit user confirmation at the approval points below.

## Versioning strategy

All six published packages use the same version and are released as one
coherent set. A single annotated git tag, `v<version>`, marks the release.

The PVP version format is `A.B.C.D`:

- `A.B` is the major version. Increment `B` for breaking API or semantic
  changes and reset `C` and `D` to zero.
- `C` is the minor version. Increment it for backward-compatible API additions,
  a newly supported PostgreSQL major, or compatibility-removal notice, and
  reset `D` to zero.
- `D` is the patch version. Increment it for fixes, documentation, tests,
  performance, or internal-only work that preserves every public contract.

Ledger, manifest, and JSON version constants change only when their respective
contracts change. Never bump all three merely because a package version changes.
Import mapping/evidence semantics and the supported PostgreSQL majors are also
public contracts; update their reference documents and acceptance evidence when
they change.

## Published packages, in dependency order

Publish in this order. A package must not be uploaded until every new internal
dependency it needs is live on Hackage:

1. `pg-migrate` (`pg-migrate/`) — core plan model, ledger, runner, repair,
   inspection, and generic history importer. No internal dependency.
2. `pg-migrate-embed` (`pg-migrate-embed/`) — ordered manifest validation,
   exact-byte Template Haskell embedding, and migration authoring. Depends on
   `pg-migrate`.
3. `pg-migrate-cli` (`pg-migrate-cli/`) — reusable parsers, dispatch, text,
   completion, and JSON contracts. Depends on `pg-migrate` and
   `pg-migrate-embed`.
4. `pg-migrate-import-codd` (`pg-migrate-import-codd/`) — Codd V1–V5 history
   adapter. Depends on `pg-migrate` and `pg-migrate-cli`.
5. `pg-migrate-import-hasql-migration`
   (`pg-migrate-import-hasql-migration/`) — qualified-table
   `hasql-migration` history adapter. Depends on `pg-migrate` and
   `pg-migrate-cli`.
6. `pg-migrate-test-support` (`pg-migrate-test-support/`) — public
   `ephemeral-pg` test helper. Depends on `pg-migrate`. It could technically be
   uploaded immediately after core, but publishing it last keeps the primary
   runtime chain together.

The following components are not published as independent Hackage packages:

- `pg-migrate-basic-example` (`examples/basic/`) is a runnable repository and
  source-distribution example, not part of the six-package release set.
- `pg-migrate-crash-helper` is an internal executable component used by core
  integration tests.
- `recompilation-probe`
  (`pg-migrate-embed/test/recompilation/fixture/`) is a source fixture used to
  prove Template Haskell recompilation behavior.

## Arguments

`$ARGUMENTS` is optional:

- `initial` enters the first-publication workflow when no release tag exists. It
  does not select a version or authorize publication.
- An exact PVP version (`A.B.C.D`) proposes that version explicitly.
- `major`, `minor`, or `patch` forces that bump proposal when a prior release
  tag exists.
- If omitted and no release tag exists, report the coherent current version as
  a candidate and ask the user to choose or confirm the exact initial version.
  Otherwise infer which bump the committed changes require.

## Steps

### 1. Inspect the current release state

Run from the repository root:

```bash
mori show --full
git status --short
git tag --list 'v*' --sort=-version:refname
git log --oneline --decorate
```

Read the version from every production cabal file, not just core:

```text
pg-migrate/pg-migrate.cabal
pg-migrate-embed/pg-migrate-embed.cabal
pg-migrate-cli/pg-migrate-cli.cabal
pg-migrate-import-codd/pg-migrate-import-codd.cabal
pg-migrate-import-hasql-migration/pg-migrate-import-hasql-migration.cabal
pg-migrate-test-support/pg-migrate-test-support.cabal
```

All six versions must agree. Find the latest `v*` tag and inspect commits and
file changes since it. If no tag exists, treat this as a first-publication
candidate. The checked-in version is evidence of preparation, not an automatic
version choice: do not assume `1.0.0.0`, mechanically bump it to `1.0.0.1`, or
publish it merely because it is already present. If a current version is
already newer than the latest tag, treat it as the prepared release candidate
and verify that its bump is sufficient.

Present the current version, last tag or `none`, commit count, changed package
directories, changed compatibility surfaces, and whether the worktree contains
unrelated changes. Preserve unrelated user changes throughout the workflow.

### 2. Propose the release version

For a first publication (an `initial` argument, or no release tag), require the
user to choose or explicitly confirm an exact `A.B.C.D` version. Present the
coherent current version and release-readiness evidence, but do not default to
that version. If an exact version argument was supplied, validate and propose
it. A `major`, `minor`, or `patch` argument requires a prior release tag; apply
the forced bump from that tag. Otherwise use Conventional Commits plus the
actual API/contract diff:

- `feat!:`, `BREAKING CHANGE:`, removed/renamed exports, changed types, or
  incompatible semantics require a major bump.
- Backward-compatible exports/modules, a new tested PostgreSQL major, or
  advance removal notice require a minor bump.
- `fix:`, `docs:`, `refactor:`, `test:`, `chore:`, and internal changes that
  preserve all contracts require a patch bump.

Examples from `1.0.0.0` are `1.1.0.0` for major, `1.0.1.0` for minor, and
`1.0.0.1` for patch.

Explain the evidence for the proposed level and ask the user to confirm the
exact version before editing files. This is the first mandatory approval point
and approves only candidate preparation, not publication.

### 3. Update versions, bounds, contracts, and changelogs

Set the approved version in all six production cabal files. The example may
track the coherent repository version for source-distribution testing, but it
is not published.

Keep internal library dependency bounds PVP-compatible. The v1 series uses
`>= 1.0 && < 1.1`. For a new `A.B` series use `>= A.B && < A.(B+1)`. Raise a
lower bound to the exact new version only when downstream code truly consumes
same-cycle upstream API or behavior; do not tighten bounds mechanically. Audit
these library edges:

```text
pg-migrate-embed -> pg-migrate
pg-migrate-cli -> pg-migrate, pg-migrate-embed
pg-migrate-import-codd -> pg-migrate, pg-migrate-cli
pg-migrate-import-hasql-migration -> pg-migrate, pg-migrate-cli
pg-migrate-test-support -> pg-migrate
```

Test-suite references to workspace packages may remain unbounded because Cabal
resolves the local packages; the published library stanzas are the consumer
contract.

For each of the six packages, add a dated section to its `CHANGELOG.md`, above
older entries, and ensure the cabal file includes
`extra-doc-files: CHANGELOG.md`. Move any Unreleased notes into the versioned
section. Group material changes under Breaking Changes, New Features, Bug
Fixes, and Other Changes, omitting empty groups.

Update every affected compatibility artifact:

- `docs/reference/compatibility.md` for toolchain, dependency, or PostgreSQL
  support changes.
- `docs/reference/release-policy.md` if version policy changes.
- `docs/reference/ledger-v1.md`, `manifest-v1.md`, or `json-v1.md` only when
  that independent contract changes.
- the relevant user/operator guides for behavior changes.
- `docs/release-checklist.md` to name the candidate version and reset evidence
  items until the new run proves them.
- `mori.dhall` when packages, dependencies, lifecycle, or registered docs
  change.

Show the complete version, bound, contract, checklist, and changelog diff to the
user before committing anything.

### 4. Run the complete local release gate

Stop and fix every failure. Do not silently skip PostgreSQL-backed or
source-distribution tests.

First format, validate package metadata, build, document, and create source
distributions:

```bash
nix fmt
nix develop -c bash -euo pipefail -c 'for dir in pg-migrate pg-migrate-embed pg-migrate-cli pg-migrate-import-codd pg-migrate-import-hasql-migration pg-migrate-test-support examples/basic; do (cd "$dir" && cabal check); done'
nix develop -c cabal build all
nix develop -c cabal haddock all
nix develop -c cabal sdist all
```

Treat missing documentation on any public facade as a release defect. The
expected facades are:

```text
Database.PostgreSQL.Migrate
Database.PostgreSQL.Migrate.History
Database.PostgreSQL.Migrate.Embed
Database.PostgreSQL.Migrate.CLI
Database.PostgreSQL.Migrate.History.Codd
Database.PostgreSQL.Migrate.History.HasqlMigration
Database.PostgreSQL.Migrate.Test
```

Unpack the newly generated tarballs into a fresh directory under `.dev/`, make
a temporary `cabal.project` that lists all six unpacked packages plus the
unpacked example, and set `tests: True`. From that project, run `cabal build
all` and `cabal test all` once in `.#postgresql17` and once in
`.#postgresql18`. This is mandatory: it proves manifests, fixtures, and the
recompilation test do not depend on checkout-only files or directory names.

Run the checkout acceptance matrix against both real server majors. Start and
stop each server explicitly so the selected shell and data directory agree:

```bash
nix develop .#postgresql17 -c process-compose up -D
nix develop .#postgresql17 -c just acceptance
nix develop .#postgresql17 -c process-compose down

nix develop .#postgresql18 -c process-compose up -D
nix develop .#postgresql18 -c just acceptance
nix develop .#postgresql18 -c process-compose down
```

Each acceptance run must end with `PASS (15 groups)`. It includes the graph-
aware production dependency closure. Also prove that the closure checker's
negative path fails:

```bash
CHECK_PRODUCTION_CLOSURE_EXTRA_FORBIDDEN=base scripts/check-production-closure
```

The negative command must exit nonzero and report that `base` unexpectedly
appears; a zero exit is a release failure.

Run the documented example and documentation/registry checks:

```bash
nix develop -c cabal run pg-migrate-basic-example -- --help
lychee --offline README.md docs
mori validate
mori show --full
mori register
mori registry show shinzui/pg-migrate --full
```

`mori registry show` must resolve all six packages and the checked-in release
docs. Run `mori register` only after any `mori.dhall` changes are final.
`nix flake check` is not a v1 release gate: the generated `packages.default`
models a single Cabal package at the repository root and does not represent this
multi-package workspace. The explicit Cabal, artifact, closure, and two-major
matrix gates above are authoritative.

Finally review `docs/release-checklist.md` line by line. Mark an item complete
only from evidence produced by this candidate. Re-run `git diff --check` and
review the full diff after all formatters and generated artifacts finish.

### 5. Approve and commit the release candidate

Present a compact evidence report containing:

- the approved version and PVP rationale;
- all six package versions and internal bounds;
- warning-free Cabal checks and public Haddock coverage;
- unpacked-sdist results for PostgreSQL 17 and 18;
- checkout acceptance results for PostgreSQL 17 and 18;
- example, link, Mori, and closure results;
- the final changelog and release-checklist diff;
- any unrelated worktree changes that will remain unstaged.

Ask the user to approve the candidate commit. After approval, stage only the
release files and create one Conventional Commit:

```text
chore(release): <version>
```

The body must summarize the release and explain the bump. Do not tag, push, or
upload yet.

### 6. Approve publication, then tag and push

Ask separately for authorization to publish the approved commit. This is the
second mandatory approval point and must explicitly cover creating the tag,
pushing the commit/tag, six Hackage uploads, documentation uploads, and the
GitHub release.

After approval, create and verify the annotated tag, then push only the intended
branch and tag:

```bash
git tag -a v<version> -m "Release <version>"
git show --stat v<version>
git push
git push origin v<version>
```

### 7. Publish all six packages to Hackage

For each package in the dependency order above:

1. Enter its package directory.
2. Run `cabal check` again.
3. Run `cabal sdist` and inspect the printed tarball path.
4. Upload it with `cabal upload --publish <tarball-path>`.
5. Build Hackage documentation with
   `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`.
6. Upload the generated documentation tarball with
   `cabal upload --publish --documentation <docs-tarball-path>`.
7. Verify and report
   `https://hackage.haskell.org/package/<package>-<version>` before continuing.

If an upload fails, do not upload anything that depends on it. A core failure
blocks all five downstream packages; an embed failure blocks CLI and both
adapters; a CLI failure blocks both adapters. Test support has no downstream
package in this release set.

Report all six results:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| pg-migrate | X.Y.Z.W | https://hackage.haskell.org/package/pg-migrate-X.Y.Z.W |
| pg-migrate-embed | X.Y.Z.W | https://hackage.haskell.org/package/pg-migrate-embed-X.Y.Z.W |
| pg-migrate-cli | X.Y.Z.W | https://hackage.haskell.org/package/pg-migrate-cli-X.Y.Z.W |
| pg-migrate-import-codd | X.Y.Z.W | https://hackage.haskell.org/package/pg-migrate-import-codd-X.Y.Z.W |
| pg-migrate-import-hasql-migration | X.Y.Z.W | https://hackage.haskell.org/package/pg-migrate-import-hasql-migration-X.Y.Z.W |
| pg-migrate-test-support | X.Y.Z.W | https://hackage.haskell.org/package/pg-migrate-test-support-X.Y.Z.W |

### 8. Create the GitHub release

Only after all six package and documentation uploads are verified, create a
GitHub release for `v<version>`. Build its notes from the six package changelog
sections and include the six-row Hackage table. Attach or link source artifacts
only if the user requested them. Report the GitHub release URL and re-check that
the tag points at the approved release commit.

## Non-negotiable rules

- Keep all six package versions coherent.
- Never infer the first published version from checked-in Cabal files,
  changelogs, or release checklists. Require explicit confirmation of the exact
  initial PVP version; `initial` alone is not confirmation.
- Never weaken or conflate the independent API, ledger, manifest, JSON,
  PostgreSQL, or import-evidence contracts to simplify a release.
- Never skip warning-free `cabal check`, complete public Haddocks, unpacked
  sdists, the production closure and negative proof, or either PostgreSQL
  acceptance matrix.
- Never publish a downstream package before the required upstream version is
  live.
- Never include `pg-migrate-basic-example`, crash helper, or recompilation probe
  as independent Hackage uploads.
- Preserve unrelated user changes and stage only the release candidate.
- Require explicit approval before the release commit and separate explicit
  approval before any tag, push, Hackage upload, documentation upload, or GitHub
  release.
- Stop on any failed gate or external mutation and report the exact state before
  continuing.
