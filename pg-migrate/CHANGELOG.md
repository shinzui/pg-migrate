# Changelog

## Unreleased

PVP impact: this set requires a major release (`1.1.0.0`) because it changes public report
constructors and the `CleanupFailed` constructor.

### Breaking changes

- Added `cleanupIssues :: [CleanupIssue]` to `MigrationReport`, `RepairReport`, and
  `HistoryImportReport`; the latter is now a multi-field `data` type rather than a
  `newtype`.
- Changed `CleanupFailed` from an optional primary error to
  `CleanupFailed MigrationError (NonEmpty CleanupIssue)`.
- Added `HistoryPayloadEvidenceTooWeak` to `HistoryValidationError`; exhaustive consumers
  must handle the new constructor.
- Added `ByteOrderMarkFound` and `MisplacedDirective` to `SqlError`; exhaustive consumers
  must handle the new constructors.

### Fixes and behavior changes

- Preserve durably successful migration, repair, and history-import reports when advisory
  unlock or statement-timeout restoration fails, attaching the cleanup observations to the
  report instead of replacing it with an error.
- Retain a genuine primary runner failure inside `CleanupFailed` when cleanup also fails.
- Added `Eq` for `CleanupIssue`, preserving the existing report `Eq` instances after their
  new field was added.
- Require `SamePayload` mappings to use evidence of at least
  `SourceManifestVerified` strength, preventing matching but unverified ledger-only
  checksums from authorizing imports.
- Reject SQL payloads with a leading UTF-8 byte-order mark and reject `pg-migrate:` line
  comments placed after SQL begins; psql meta-command diagnostics now use file-absolute
  line numbers.
- Reject zero and negative temporary statement timeouts before acquiring a connection;
  `Nothing` remains the way to leave the PostgreSQL session default untouched.
- Honor an explicitly configured `AllowUnknownMigrations` policy during repair and history
  import, matching normal execution. The strict default remains unchanged.
- Replace the transactional runner's per-migration full-ledger reload with a keyed
  existence query and build history-import classification maps once per import.
- Pin and document the conservative mixed native/import contract: import a gap-free legacy
  prefix before applying that component natively; native rows without matching import audit
  evidence remain conflicts.

## 1.0.0.0 — 2026-07-10

- Initial stable release of the validated plan model, ledger schema v1, transactional and
  nontransactional runner, repair audit, inspection API, and generic history importer.
