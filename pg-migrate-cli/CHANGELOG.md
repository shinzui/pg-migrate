# Changelog

## Unreleased

PVP impact: this set requires a major release (`1.1.0.0`) because it changes public record
field types, renames a public constructor, removes an accidentally exposed module, and
changes the `check` command syntax.

### Breaking changes

- Changed `ExecutionOptions` to represent absent lock and statement-timeout flags as
  optional overrides. Applications constructing commands directly must wrap explicit
  values in `Just`; `Nothing` now preserves `CliEnvironment` runner settings.
- Renamed `ExitSuccess` to `ExitSucceeded`, avoiding its collision with
  `System.Exit.ExitSuccess`.
- Changed `check MANIFEST` to `check --manifest PATH`, matching `new --manifest`.
- Stopped exposing the internal `PgMigrate.CLI.Prelude` module.
- Added `CliInputError` to the public `CliError` sum for command-input failures.
- Updated public report construction for the core package's new `cleanupIssues` fields and
  mandatory-primary `CleanupFailed` shape.

### Fixes and behavior changes

- Added explicit `--wait` and `--no-statement-timeout` overrides; absent execution flags no
  longer discard application-configured `RunOptions`.
- Reject `new --description` values containing control characters before any file is
  created, including for callers that construct `NewOptions` directly.
- Classify manifest IO failures from `check` and `new` as execution failures while keeping
  manifest validation failures as usage failures.
- Reject unknown inspection filters for `plan`, `list`, `status`, and `verify`; filter
  report issues as well as migration lists while retaining the full-report verification
  exit class.
- Share one checksum renderer between text and JSON output without changing rendered bytes.
- Render successful migration and repair cleanup observations in text and as an additive
  `cleanup_issues` array in JSON schema v1; history-import JSON exposes the same field.

## 1.0.0.0 — 2026-07-10

- Initial stable release of the reusable command tree, typed dispatcher, text output,
  parser-derived completion, and JSON schema v1 including history-import reports.
