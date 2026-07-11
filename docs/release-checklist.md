# 1.0.0.0 release checklist

- [x] All six packages use version `1.0.0.0` and bounded internal library dependencies.
- [x] Public ledger, manifest, and JSON version constants equal 1.
- [x] User, operator, reference, compatibility, and acceptance documentation is present.
- [x] The basic two-component example builds and its actual parser accepts `--help`.
- [x] `nix fmt`, `cabal check`, `cabal haddock all`, and `cabal sdist all` pass.
- [x] Every unpacked source distribution builds without repository-only source files.
- [x] `mori validate`, `mori show --full`, and registry refresh pass.
- [x] Production dependency closure and its injected-negative test pass.
- [x] PostgreSQL 17 and 18 each pass all fifteen acceptance groups.
- [x] No Hackage, GitHub release, or other publication was performed.

Before publishing, the operator should review generated sdists/Haddocks, confirm repository
and package metadata, select the intended commit, create signed release notes/tags as local
policy requires, and invoke the separately authorized release workflow.
