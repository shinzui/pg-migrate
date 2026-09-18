# Changelog

## 1.2.0.0 — 2026-09-18

Coherent-set release: `pg-migrate-test-support` moved to ephemeral-pg 0.3, a breaking change
to a type in its public API, so all six packages move to the 1.2 series together.

### Other changes

- No API or behavior changes in this package. Internal library bounds are now
  `>= 1.2 && < 1.3`.

## 1.1.0.0 — 2026-07-13

Major release: this set adds constructors to the public `ManifestError` and
`AuthoringError` sums.

### Breaking changes

- Added `ManifestByteOrderMark` so a leading UTF-8 BOM has a dedicated diagnostic.
- Added `AuthoringConcurrentModification` so a detected post-rename manifest clobber does
  not silently report successful authoring.

### Fixes and behavior changes

- Stop automatic numbering before a successor would lose the sequence's leading zero and
  become unreadable by the next authoring operation.
- Emit embedded SQL as one static primitive byte literal instead of one Template Haskell
  expression per byte, making multi-megabyte payloads practical while preserving exact
  bytes.
- Add `Database.PostgreSQL.Migrate.Embed.RecompilePlugin` for GHC 9.12. A module-local
  `OPTIONS_GHC -fplugin=...` pragma makes the embedding module recompile on every build so
  newly added or removed sibling SQL files rerun strict manifest membership validation.
- Document that migration authoring requires POSIX while manifest validation and embedding
  remain portable, and describe the authoring helper's actual concurrency guarantees.

## 1.0.0.0 — 2026-07-10

- Initial stable release of manifest format v1, exact-byte Template Haskell embedding,
  validation, and crash-conservative migration authoring.
