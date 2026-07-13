# Changelog

## Unreleased

PVP impact: this set requires a major release (`1.1.0.0`) because it adds a field to
`CoddImportCommand` and removes a public error constructor.

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
