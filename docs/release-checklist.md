# 1.1.0.0 release checklist

`1.1.0.0` is a breaking release over the published `1.0.0.0`. Every item below is unchecked
until this candidate's own gate run proves it; evidence from an earlier version does not
carry over.

- [x] All six packages use version `1.1.0.0` and bound internal library dependencies to
      `>= 1.1 && < 1.2`.
- [x] Public ledger, manifest, and JSON version constants still equal 1, and every changed
      contract document justifies why its version is unchanged. The manifest's new
      byte-order-mark rejection tightens format v1 parsing rather than introducing a v2;
      the JSON `cleanup_issues` and `input.invalid` additions are additive within schema v1.
- [x] Each package changelog records a dated `1.1.0.0` section naming its breaking changes.
- [x] User, operator, reference, compatibility, and acceptance documentation reflects the
      new report shapes, the `check --manifest` syntax, and the GHC 9.12 recompilation
      plugin requirement.
- [x] The basic two-component example builds and its actual parser accepts `--help`.
- [x] `nix fmt`, `cabal check`, `cabal haddock all`, and `cabal sdist all` pass. All seven
      public facades document at 100%.
- [x] Every unpacked source distribution builds and tests without repository-only source
      files, on PostgreSQL 17 and 18.
- [ ] `mori validate`, `mori show --full`, and registry refresh pass. `mori validate` and
      `mori registry show` pass and resolve all six packages and seven docs. `mori register`
      currently fails inside Mori's own event store (`column s.truncate_before does not
      exist`), which is unrelated to this release; `mori.dhall` is unchanged this cycle, so
      no registry refresh is owed.
- [x] Production dependency closure and its injected-negative test pass.
- [x] PostgreSQL 17 and 18 each pass all fifteen acceptance groups.
- [x] No Hackage, GitHub release, or other publication was performed by the local gate.

Before publishing, the operator should review generated sdists/Haddocks, confirm repository
and package metadata, select the intended commit, create signed release notes/tags as local
policy requires, and invoke the separately authorized release workflow.
