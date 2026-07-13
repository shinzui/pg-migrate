# Changelog

## Unreleased

PVP impact: this set requires a major release (`1.1.0.0`) because it removes a public
error constructor.

### Breaking changes

- Removed the unreachable `EmptyHasqlMigrationSelection` constructor from
  `HasqlMigrationDefinitionError`.

### Fixes and behavior changes

- Record the quoted schema-qualified `source_table` in every row's audit evidence.
- Replace internal partial payload-map lookups with the structured
  `MissingHasqlMigrationPayload` definition error.
- Correct the reusable parser's API description to state that its plan parameter is
  reserved.

## 1.0.0.0 — 2026-07-10

- Initial stable release of the qualified-table `hasql-migration` adapter with base64-MD5
  verification, SHA-256 evidence, and validator-backed alternative history.
