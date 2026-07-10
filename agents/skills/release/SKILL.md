---
name: release
description: Release the pg-migrate packages to Hackage following PVP
argument-hint: "[major|minor|patch]"
disable-model-invocation: true
allowed-tools: Read, Bash, Edit, Glob, Grep, Write, AskUserQuestion
---

# pg-migrate Release Skill

Release the `pg-migrate` packages to [Hackage](https://hackage.haskell.org/)
using the Haskell **PVP** version scheme (`A.B.C.D`). This is a Nix +
`cabal` project (GHC 9.12.4); the format and check gates go through the flake.

## Versioning Strategy

All three packages share the **same version number** and are released
together. A single annotated git tag `v<version>` marks each release.

The Haskell PVP version format is `A.B.C.D`:

- `A.B` — **major**: breaking API changes (removed/renamed exports, changed
  types, changed semantics).
- `C` — **minor**: backwards-compatible API additions (new exports, new
  modules, new instances).
- `D` — **patch**: bug fixes, docs, internal-only changes, performance work.

## Packages (in dependency order)

Publish in this order — each package depends on the ones before it:

1. **pg-migrate** (`pg-migrate/`) — Hasql-native PostgreSQL migration engine.
   No internal dependencies.
2. **pg-migrate-embed** (`pg-migrate-embed/`) — compile-time ordered SQL
   manifests. Depends on `pg-migrate`.
3. **pg-migrate-cli** (`pg-migrate-cli/`) — reusable command parsers and
   renderers. Depends on `pg-migrate` **and** `pg-migrate-embed`.

The following are **NOT released** to Hackage:

- **pg-migrate-crash-helper** — an internal `executable` component of the
  `pg-migrate` package used only by its integration test suite.
- **recompilation-probe** (`pg-migrate-embed/test/recompilation/fixture/`) — a
  test fixture cabal package; it is not listed in `cabal.project` and exists
  only to exercise `pg-migrate-embed`'s recompilation behavior.

## Arguments

`$ARGUMENTS` is optional:

- `major`, `minor`, or `patch` — the bump level.
- If omitted, determine the bump level from the changes (see step 2).

## Steps

### 1. Determine what changed since the last release

- Read the current version from `pg-migrate/pg-migrate.cabal` (all packages
  share the same version).
- Find the latest git tag matching `v*` (`git tag --list 'v*'`) to identify
  the last release point. There may be none yet (this is a pre-1.0 project).
- Run `git log --oneline <last-tag>..HEAD` (or `git log --oneline` if there is
  no tag) to list commits since the last release.
- If there are no commits since the last tag, tell the user there is nothing
  to release and stop.

Present a summary showing:

- Current version
- Last release tag (or "none")
- Number of commits since last release
- Which package directories (`pg-migrate/`, `pg-migrate-embed/`,
  `pg-migrate-cli/`) have changes

### 2. Determine the next version using PVP

Rules:

- If `$ARGUMENTS` is `major`, `minor`, or `patch`, use that bump level.
- Otherwise, analyze the commits (Conventional Commits are used in this repo)
  to determine the appropriate bump:
  - `feat!:` / `BREAKING CHANGE:` / "remove"/"rename"/"change type" → **major**
  - `feat:` / "add"/"new export"/"new module" → **minor**
  - `fix:` / `docs:` / `refactor:` / `test:` / `chore:` / internal-only → **patch**
- Present the proposed bump to the user and ask for confirmation before
  proceeding.

Increment the version:

- **major**: increment `B`, reset `C` and `D` to 0 (e.g. `0.1.0.0` → `0.2.0.0`)
- **minor**: increment `C`, reset `D` to 0 (e.g. `0.1.0.0` → `0.1.1.0`)
- **patch**: increment `D` (e.g. `0.1.0.0` → `0.1.0.1`)

### 3. Update versions, internal bounds, and changelogs

#### Version update

Edit all three package cabal files to set the new version:

- `pg-migrate/pg-migrate.cabal`
- `pg-migrate-embed/pg-migrate-embed.cabal`
- `pg-migrate-cli/pg-migrate-cli.cabal`

Note: an upstream cabal's version may already have been bumped mid-cycle (e.g.
so a downstream's lower bound can be declared). Verify all three cabals are at
the target version before committing.

#### Internal dependency bound update

Set PVP-compatible bounds matching the new version everywhere an internal
package appears in a downstream cabal:

- `pg-migrate-embed/pg-migrate-embed.cabal` — `pg-migrate` in the `library`
  and the `pg-migrate-embed-test` test-suite.
- `pg-migrate-cli/pg-migrate-cli.cabal` — `pg-migrate` and `pg-migrate-embed`
  in the `library`, and `pg-migrate` in the `pg-migrate-cli-test` test-suite.

Use `<pkg> ^>=A.B.C.D` for the new version. (Today these internal
dependencies are declared without a bound; add the bounds as part of the
release.)

#### Changelog update

- For each published package, maintain a `CHANGELOG.md` in its package
  directory (`pg-migrate/CHANGELOG.md`, `pg-migrate-embed/CHANGELOG.md`,
  `pg-migrate-cli/CHANGELOG.md`). Create it if missing. Add a new section for
  the new version above previous entries, using today's date in `YYYY-MM-DD`
  format.
- If a package cabal does not yet reference its changelog, add
  `extra-doc-files: CHANGELOG.md` so it ships in the sdist and renders on
  Hackage.
- Move any "Unreleased" content into the new version section.
- Summarize commits since the last release, grouped by (include only
  non-empty categories):
  - **Breaking Changes** (major)
  - **New Features** (minor or major)
  - **Bug Fixes**
  - **Other Changes** (docs, refactoring, tests, internal)
- Also maintain a root `CHANGELOG.md` covering the release as a whole; create
  it if it does not exist.

Show the user ALL changes (version bumps, the internal bounds in
`pg-migrate-embed` and `pg-migrate-cli`, and changelog entries) for review
before committing.

### 4. Verify — format, build, test, flake check

Run these from the repo root inside the Nix dev shell. Stop and fix on any
failure before proceeding.

1. `nix fmt` — format (nixpkgs-fmt + fourmolu + cabal-fmt). Re-review the diff
   afterward.
2. `cabal build all` — build every package and component.
3. Unit tests (no database required):
   - `cabal test pg-migrate:pg-migrate-unit`
   - `cabal test pg-migrate-embed:pg-migrate-embed-test`
   - `cabal test pg-migrate-embed:pg-migrate-embed-recompilation`
   - `cabal test pg-migrate-cli:pg-migrate-cli-test`
4. Integration tests (**Postgres-backed**, strongly recommended): the dev
   shell exports `PGHOST`/`PGDATA`/`PGDATABASE`. Ensure a database exists
   (`just create-database`, starting Postgres first if needed), then run
   `cabal test pg-migrate:pg-migrate-integration` (or `cabal test all`). If a
   database is genuinely unavailable, note explicitly to the user that the
   integration suite was skipped — do not silently omit it.
5. `nix flake check` — treefmt + pre-commit gates.
   - The flake exposes `packages.default`, `checks`, `devShells`, and
     `formatter`.
   - **Newly created files (e.g. a new `CHANGELOG.md`) must be `git add`-ed
     before nix evaluation will see them**, since nix reads the git tree.
   - If any check fails, fix it before proceeding.

### 5. Commit, tag, and push

- Stage all modified `.cabal` and `CHANGELOG.md` files.
- Create a single commit using a Conventional Commits message:
  `chore(release): <new-version>` (repo convention). The body should summarize
  what's in the release and why this bump level was chosen.
- Create a single annotated tag: `git tag -a v<version> -m "Release <version>"`.
- Push the commit and tag: `git push && git push --tags`.

### 6. Publish to Hackage (in dependency order)

For EACH package, in dependency order
(**pg-migrate → pg-migrate-embed → pg-migrate-cli**):

1. `cd <pkg-dir>`.
2. `cabal check` — verify no packaging issues.
3. `cabal sdist`, then `cabal upload --publish <tarball-path>` to publish the
   source distribution.
4. `cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump`,
   then `cabal upload --publish --documentation <docs-tarball-path>` to publish
   docs.
5. Report the Hackage URL:
   `https://hackage.haskell.org/package/<pkg>-<version>`.

**Do not** upload a package until every package it depends on has uploaded
successfully — a downstream's bound requires the new upstream to already be on
Hackage. So `pg-migrate` must be live before `pg-migrate-embed`, and both must
be live before `pg-migrate-cli`.

After all packages are published, present a summary:

| Package | Version | Hackage URL |
|---------|---------|-------------|
| pg-migrate | X.Y.Z.W | https://hackage.haskell.org/package/pg-migrate-X.Y.Z.W |
| pg-migrate-embed | X.Y.Z.W | https://hackage.haskell.org/package/pg-migrate-embed-X.Y.Z.W |
| pg-migrate-cli | X.Y.Z.W | https://hackage.haskell.org/package/pg-migrate-cli-X.Y.Z.W |

### 7. Create GitHub release

After all Hackage uploads succeed, create a GitHub release for the tag
(`gh` is available):

```bash
gh release create v<version> --title "v<version>" --notes "$(cat <<'EOF'
## Packages

| Package | Hackage |
|---------|---------|
| pg-migrate | https://hackage.haskell.org/package/pg-migrate-X.Y.Z.W |
| pg-migrate-embed | https://hackage.haskell.org/package/pg-migrate-embed-X.Y.Z.W |
| pg-migrate-cli | https://hackage.haskell.org/package/pg-migrate-cli-X.Y.Z.W |

## What's Changed

<changelog entries for this version from the root CHANGELOG.md>
EOF
)"
```

- Use the root `CHANGELOG.md` entries for the release notes body.
- Include the Hackage links table so each package is easily discoverable.
- Report the GitHub release URL when done.

## Important

- Always ask the user to confirm the version bump and changelogs before
  committing.
- Always publish in dependency order:
  **pg-migrate → pg-migrate-embed → pg-migrate-cli**.
- Never skip `cabal check`, the test suites, or `nix flake check`.
- If any step fails (including `nix flake check`), stop and report the error
  rather than continuing.
- If any Hackage upload fails, do **NOT** upload packages that depend on it
  (e.g. a `pg-migrate` failure blocks both `pg-migrate-embed` and
  `pg-migrate-cli`; a `pg-migrate-embed` failure blocks `pg-migrate-cli`).
- Run `nix fmt` before committing, and `git add` any new files before
  `nix flake check` so nix's git-tree evaluation sees them.
- The commit and tag should only be created AFTER user approval of all changes.
