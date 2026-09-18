# 1.2.0.0 release checklist

`1.2.0.0` is a breaking release over the published `1.1.0.0`: `pg-migrate-test-support`
moves to ephemeral-pg 0.3, whose `Config` type appears in its public API. Every item below
is unchecked until this candidate's own gate run proves it; evidence from an earlier
version does not carry over.

- [x] All six packages use version `1.2.0.0` and bound internal library dependencies to
      `>= 1.2 && < 1.3`.
- [x] Public ledger, manifest, and JSON version constants still equal 1. No ledger,
      manifest, JSON, PostgreSQL support, or import-evidence contract changed this cycle.
- [x] Each package changelog records a dated `1.2.0.0` section; `pg-migrate-test-support`
      names its breaking ephemeral-pg change and the new `defaultEphemeralConfig`.
- [x] User, reference, compatibility, and release-policy documentation reflects the 1.2
      bounds, the ephemeral-pg requirement, and the stable per-user temporary root.
- [x] The basic two-component example builds and its actual parser accepts `--help`.
- [x] `nix fmt`, `cabal check`, `cabal haddock all`, and `cabal sdist all` pass. All seven
      public facades document at 100%.
- [x] Every unpacked source distribution builds and tests without repository-only source
      files, on PostgreSQL 17 and 18.
- [x] `mori validate`, `mori show --full`, `mori register`, and `mori registry show` pass
      and resolve all six packages and eight docs. `mori.dhall` now sets
      `versionConstraint = None Text` in its dependency augmentation, which the pinned
      mori-schema requires.
- [x] Production dependency closure and its injected-negative test pass.
- [x] PostgreSQL 17 and 18 each pass all fifteen acceptance groups.
- [x] No Hackage, GitHub release, or other publication was performed by the local gate.

Before publishing, the operator should review generated sdists/Haddocks, confirm repository
and package metadata, select the intended commit, create signed release notes/tags as local
policy requires, and invoke the separately authorized release workflow.
