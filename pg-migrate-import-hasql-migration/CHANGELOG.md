# Changelog

## 1.2.0.0 — 2026-09-18

Coherent-set release: `pg-migrate-test-support` moved to ephemeral-pg 0.3, a breaking change
to a type in its public API, so all six packages move to the 1.2 series together.

### Other changes

- No API or behavior changes in this package. Internal library bounds are now
  `>= 1.2 && < 1.3`.

## 1.1.0.0 — 2026-07-13

Major release: this set removes a public error constructor.

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
