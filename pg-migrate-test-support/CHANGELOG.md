# Changelog

## Unreleased

PVP impact: this set requires a major release (`1.1.0.0`) because it removes a public error
constructor and changes callback exception behavior.

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
