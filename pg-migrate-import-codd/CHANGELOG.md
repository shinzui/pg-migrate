# Changelog

## 1.2.0.0 — 2026-09-18

Coherent-set release: `pg-migrate-test-support` moved to ephemeral-pg 0.3, a breaking change
to a type in its public API, so all six packages move to the 1.2 series together.

### Other changes

- No API or behavior changes in this package. Internal library bounds are now
  `>= 1.2 && < 1.3`.

## 1.1.0.0 — 2026-07-13

Major release: this set adds a field to `CoddImportCommand` and removes a public error
constructor.

### Breaking changes

- Added `allowEquivalent :: Bool` to `CoddImportCommand`, backed by the reusable parser's
  new `--allow-equivalent` flag.
- Removed the unreachable `EmptyCoddSelection` constructor from `CoddDefinitionError`.

### Fixes and behavior changes

- Parse `--source-lock-key` through `Integer` and reject decimal or hexadecimal values
  outside signed `Int64` bounds instead of silently wrapping them.
- Make `--strict-source` reject selected rows missing from a provided manifest as well as
  manifest entries outside the selection.
- Stop attaching locally calculated, unverified checksums to `LedgerOnly` evidence.
- Preserve a committed `HistoryImportReport` when releasing the Codd source lock fails,
  appending the source observation to `cleanupIssues`.
- Document the two optional error slots of `CoddUnlockFailed` and correct manifest/parser
  API descriptions.

## 1.0.0.0 — 2026-07-10

- Initial stable release of the Hasql-only Codd V1–V5 history adapter with source-first
  locking, manifest evidence, and action-free generic import.
