# Changelog

## 1.2.0.0 — 2026-09-18

Major release: `withMigratedDatabaseConfig` takes an `EphemeralPg.Config`, and this set moves
to ephemeral-pg 0.3, whose `Config` gained a field.

### Breaking changes

- Require `ephemeral-pg >=0.3.1 && <0.4` (was `>=0.2 && <0.3`). ephemeral-pg 0.3 added
  `sweepStaleOnStart` to `Config`, so callers that construct `Config` exhaustively must
  set it; ephemeral-pg 0.3.1 also reclaims clusters abandoned by killed runs on the next
  startup.

### New features

- Add `defaultEphemeralConfig`, which pins ephemeral-pg's `temporaryRoot` to a stable
  per-user directory (`/tmp/ephpg-pg-migrate-<uid>`, created if missing). Start from it
  when calling `withMigratedDatabaseConfig`.

### Fixes and behavior changes

- `withMigratedDatabase` and `withMigratedDatabaseOptions` now use `defaultEphemeralConfig`,
  so the stale-cluster sweep keeps working under a per-session `$TMPDIR` (`nix develop`,
  `nix-shell`, CI runners).

## 1.1.0.0 — 2026-07-13

Major release: this set removes a public error constructor and changes callback exception
behavior.

### Breaking changes

- Removed `MigratedDatabaseCallbackCleanupFailed`; a successful callback value now wins
  when only its connection release fails.
- Asynchronous callback exceptions now propagate after cleanup instead of being returned as
  `MigratedDatabaseCallbackFailed`.

### Fixes and behavior changes

- Acquire the callback connection inside the same masked bracket that runs the callback and
  releases the connection, closing the interruption leak window.
- Preserve both exceptions in `MigratedDatabaseCallbackAndCleanupFailed` when a synchronous
  callback failure and connection-release failure occur together.

## 1.0.0.0 — 2026-07-10

- Initial stable release of the `ephemeral-pg` helper with fresh Hasql callback connections
  and structured startup, migration, callback, and cleanup failures.
