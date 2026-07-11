# Local implementation proof (not staging evidence)

This record captures repository-local ephemeral-database validation for EP-15. It does not
satisfy the staging inventory, restoration, released-artifact, operator, or two-clean-copy
requirements in `docs/rollout/staging-inventory.md`.

## Artifacts and plans

- Kiroku canary: commit `6399844a507a3ea5a3974181b4d8c1380f2f7b5b`,
  `kiroku/0008-schema-management-comment`.
- Keiro canary: commit `49c6f2a87d9bda23cc97c61fb59a220ab9c9e043`,
  `keiro/0017-schema-management-comment` after Kiroku `0008`.
- PGMQ canary: commit `edb62737654b14c3cdd9ddc03da11810598b694b`,
  `pgmq/0002-schema-management-comment`.
- Historical mappings remain Kiroku `0001..0007`, Keiro `0001..0016`, and PGMQ
  `0001-install-v1.11.0`; no mapping or historical SQL byte changed.

## Imported-prefix transitions

- Kiroku current and legacy Codd fixtures import seven rows, verify with only Kiroku
  `0008` pending, apply only `0008`, verify cleanly, and rerun all eight as
  `AlreadyApplied`. Repeated import is `AlreadyImported`.
- Combined current and legacy Codd fixtures atomically import 23 rows, verify with only
  Kiroku `0008` and Keiro `0017` pending, apply them in that component order, verify
  cleanly, and rerun all 25 as `AlreadyApplied`. Repeated import is `AlreadyImported`.
- PGMQ direct and two-step fixtures import only the baseline, verify with only `0002`
  pending, apply only `0002`, verify cleanly, and rerun both entries as `AlreadyApplied`.
  Equivalent history still requires explicit opt-in and fails when a required catalog
  function, type, or table is removed.

## Commands and results

- Kiroku: `nix develop -c cabal test all` passed. The migration suite passed 10 examples,
  the store suite passed 234 examples, and all CLI, metrics, telemetry, Codd, and adapter
  suites passed.
- Keiro: with the ignored local Kiroku package override and the unavailable remote source
  stanza temporarily omitted, `nix develop -c cabal test all` passed. The migration suite
  passed 10 examples, the framework suite passed 280 examples, keiro-pgmq passed 50 with
  two documented pending cases, Jitsurei passed 16, and all DSL/Codd suites passed. The
  tracked `cabal.project` was restored byte-for-byte afterward.
- PGMQ: `nix develop -c cabal test all` passed: migration 7, hasql 55, effectful 17, and
  config 10. `nix build .#checks.aarch64-darwin.pgmq-migration-tests` also passed.

All databases in this record were disposable local ephemeral instances. No production or
operator-controlled staging database was accessed or mutated.
