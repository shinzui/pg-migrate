---
id: 7
slug: build-the-reusable-migration-cli-and-json-contracts
title: "Build the reusable migration CLI and JSON contracts"
kind: exec-plan
created_at: 2026-07-10T15:50:24Z
intention: "intention_01kx6bkssqee4sz0gzw0tdvkkv"
master_plan: "docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md"
---

# Build the reusable migration CLI and JSON contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, a service executable can mount one reusable `optparse-applicative` command
tree for inspecting a declared plan, checking manifests, querying status, verifying a
database, applying migrations, repairing nontransactional history, and creating a new SQL
file. The consumer still owns configuration precedence, logging, output streams, and
process exit. Human output is stable and machine commands emit an explicitly versioned
JSON schema. Golden tests show grouped help, parser-derived completions, and deterministic
text/JSON for every command without requiring migration discovery.


## Progress

- [x] (2026-07-10 14:28 PDT) Milestone 1: Created the optional CLI package, typed command
  model, grouped parser, and parser-focused tests. All 8 parser tests pass, including
  grouped help, narrow verify wording, duration and conflict rejection, repair
  confirmation, validated targets, and absent implicit database settings.
- [ ] (2026-07-10 15:01 PDT) Milestone 2: Added the consumer-supplied handler environment,
  typed outcomes and exit classes, public core inspection operations, execution dispatch,
  manifest checking, authoring, filters, and stable text rendering. Pure handler coverage
  passes; live status, strict verify, up, and repair acceptance remains.
- [x] (2026-07-10 15:01 PDT) Milestone 3: Added JSON schema version 1 with ordered arrays,
  lowercase SHA-256, UTC timestamps, integer milliseconds, constructor-derived error
  tags, six checked-in golden contracts, and repeat-render stability coverage.
- [ ] (2026-07-10 15:01 PDT) Milestone 4: Grouped top-level and subcommand help plus plain
  and enriched parser-derived completion proofs pass. Live PostgreSQL command coverage
  remains before this milestone is complete.


## Surprises & Discoveries

- Observation: Hasql 1.10's `Settings.connectionString` intentionally maps an invalid
  connection string to empty settings instead of returning a parse error. The CLI parser
  therefore produces the requested typed Hasql settings without claiming stricter eager
  URL validation than the dependency provides.

- Observation: the core plan implemented `loadStatus` and `loadVerification` sessions
  internally, but the public `migrationStatus` and `verifyMigrationPlan` operations named
  by `docs/initial-spec.md` are absent. Milestone 2 must close that public integration gap
  rather than reach through the opaque `ConnectionProvider` from the CLI package.

- Observation: inspection filters must not change strict verification semantics. The
  handler filters displayed applied, pending, and unknown arrays but retains the complete
  issue list and computes `ExitVerificationFailed` from the unfiltered report.


## Decision Log

- Decision: Return typed command outcomes and recommended exit classes rather than calling
  `exitWith` inside the CLI library.
  Rationale: Consumer executables own process policy, while the package still centralizes
  parser and rendering conventions.
  Date: 2026-07-10

- Decision: Put the JSON schema version in every top-level machine response.
  Rationale: Plan, ledger, and report types will evolve; explicit versioning gives machine
  consumers a compatibility boundary independent of Haskell constructors.
  Date: 2026-07-10

- Decision: Keep parsing free of filesystem and environment access even when authoring
  cannot infer a numeric name.
  Rationale: whether `--name` is required depends on manifest contents; the pure parser
  records the optional name and the handler returns a typed usage failure if the authoring
  API reports `ExplicitMigrationNameRequired`.
  Date: 2026-07-10

- Decision: Represent verification disagreement as `ok: false` with a structured `data`
  report instead of an operational `error` object.
  Rationale: pending or mismatched history is the successful result of running strict
  verification, while connection, session, and runner failures are errors. Consumers can
  inspect every issue without parsing an error message.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Revision Note

2026-07-10: Began implementation after confirming the core MasterPlan is complete and the
declared `pg-migrate-cli/` package directory is absent.

2026-07-10: Completed Milestone 1 with the optional package, public command types, grouped
parser, and eight passing parser contract tests; recorded Hasql connection-string behavior
and the missing public core inspection operations for Milestone 2.

2026-07-10: Added the public core inspection operations, typed handlers, stable text,
inspection filters, JSON schema version 1, six golden contracts, and real plain/enriched
completion protocol tests. Live PostgreSQL command acceptance remains for Milestones 2
and 4.


## Context and Orientation

Complete `docs/masterplans/1-build-pg-migrate-v1-core-engine.md` before starting. Its child
plans provide `MigrationPlan`, plan descriptions, status/verification, the completed
runner, repair, generic history, and manifest authoring. This plan creates the optional
`pg-migrate-cli/` package and adds it to `cabal.project`; the core package must not depend
back on it.

The locally registered `optparse-applicative` source is version 0.19.0.0 and exports
`parserOptionGroup`, `commandGroup`, `subparser`, `helper`, and its built-in completion
protocol. Follow `mori://shinzui/haskell-jitsurei/docs/cli-option-groups` and
`mori://shinzui/haskell-jitsurei/docs/cli-shell-completions`. Parser construction is pure:
it does not read environment variables, acquire a connection, inspect the runtime
filesystem, print, or exit.

Commands are grouped by operator intent. Inspection contains `plan`, `status`, `verify`,
`list`, and `check`; Execution contains `up` and `repair`; Authoring contains `new`.
`verify` means declared-plan versus ledger verification, not live-schema snapshot equality.
`up` always applies the complete plan in v1. Filters may narrow inspection output only.


## Plan of Work

Milestone 1 creates `pg-migrate-cli/pg-migrate-cli.cabal` and modules under
`pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI/`. Define `MigrationCommand` and
command-specific option records as values. Implement
`migrationCommandParser :: MigrationPlan -> Parser MigrationCommand` with three
`commandGroup`s. Organize common flags with `parserOptionGroup "Connection"`,
`"Execution"`, and `"Output"`. The optional `--database-url` yields Hasql settings but no
environment variable is implied. Parse `--lock-timeout`, `--no-wait`, and
`--statement-timeout` into typed durations and reject conflicting flags.

`plan` renders component order/dependencies; `list` renders migration identities and
metadata; `check` validates one manifest on disk without a database; `status` reads ledger
state; strict `verify` makes no database change and fails for pending, mismatch,
interrupted/failed, dependency, or unknown-row issues; `up` invokes the full runner;
`repair` requires one `COMPONENT/MIGRATION`, one operation, reason, and `--confirm`; `new`
requires a manifest path and description plus `--name` when numeric inference is not
possible. Help must state that execution filters are unavailable in v1.

Milestone 2 defines a handler boundary. `runMigrationCommand` accepts a consumer-supplied
`CliEnvironment` containing either settings or a `ConnectionProvider`, a plan, and runner
options. It returns `CliOutcome` with a typed payload and `ExitClass`; it does not print or
exit. Pure `renderText` and `renderJson` functions turn outcomes and errors into output.
Use core reports, IDs, and structured Hasql details rather than parsing `show` strings.

Milestone 3 defines JSON schema version 1 in
`pg-migrate-cli/src/Database/PostgreSQL/Migrate/CLI/Json.hs`. Every response is an object
with `schemaVersion`, `command`, `ok`, and either `data` or structured `error`. IDs are
`component/migration`; checksums use lowercase hexadecimal; timestamps use UTC ISO-8601;
durations use integer milliseconds. Array order follows plan or ledger order, never map
iteration. Write golden files under `pg-migrate-cli/test/golden/json/` for `plan`,
`status`, `verify`, `up`, `repair`, and source-independent errors.

Milestone 4 adds parser/help tests and completion proof. Golden-test top-level and each
subcommand's `--help`, including the grouped headings and the narrow verify wording. Invoke
optparse-applicative's built-in plain and enriched completion requests against the actual
parser and assert new commands/flags appear; do not maintain a separate command registry.
Use pure fixtures for plan/list/check and a temporary PostgreSQL schema for status,
verify, up, and repair.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`:

```bash
mori registry show pcapriotti/optparse-applicative --full
sed -n '400,445p' /Users/shinzui/Keikaku/hub/haskell/optparse-applicative-project/optparse-applicative/src/Options/Applicative/Builder.hs
nix develop
just create-database
cabal test pg-migrate-cli:pg-migrate-cli-test
```

Expected help contains:

```text
Inspection
  plan
  status
  verify
  list
  check
Execution
  up
  repair
Authoring
  new
```

Run `nix fmt`, `cabal build all`, and all workspace tests. Commits require:

```text
MasterPlan: docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md
ExecPlan: docs/plans/7-build-the-reusable-migration-cli-and-json-contracts.md
Intention: intention_01kx6bkssqee4sz0gzw0tdvkkv
```


## Validation and Acceptance

Build a sample consumer parser around a two-component plan. Top-level help shows the three
command groups, each flag appears in the correct option group, and `verify --help`
explicitly says it compares plan and ledger rather than schema snapshots. Parsing never
consults `PG_CONNECTION_STRING`. Invalid duration, conflicting wait flags, missing repair
confirmation, and missing explicit authoring name all return parser errors.

For identical fixture input, text and JSON output are byte-for-byte stable across two runs.
Every JSON golden has `schemaVersion: 1`; checksum/timestamp/duration encoding follows the
contract. Strict verify returns an unsuccessful exit class for pending migrations without
mutating the ledger. `up` cannot select one component. Plain and enriched completion output
contains the same real commands. `pg-migrate` core's Cabal stanza remains independent of
`optparse-applicative`.


## Idempotence and Recovery

Pure parsing/rendering is repeatable. Inspection commands do not mutate except `check` and
`new` may read/write the requested manifest; `new` inherits the exclusive and atomic
recovery semantics from `docs/plans/2-validate-sql-and-embed-ordered-manifests.md`. `up`
and repair inherit core idempotence and audit rules. Golden updates
must be reviewed as public contract changes rather than blindly regenerated. A consumer
can always choose not to print a returned outcome or can map `ExitClass` to its own policy.


## Interfaces and Dependencies

Depend on `pg-migrate`, `pg-migrate-embed`, `optparse-applicative >= 0.19 && < 0.20`,
`aeson`, `bytestring`, `text`, and `time`. Required interfaces include:

```haskell
migrationCommandParser :: MigrationPlan -> Parser MigrationCommand
runMigrationCommand :: CliEnvironment -> MigrationCommand -> IO CliOutcome
renderMigrationCommandText :: CliOutcome -> Text
renderMigrationCommandJson :: CliOutcome -> Value
data ExitClass = ExitSuccess | ExitVerificationFailed | ExitUsageFailed | ExitExecutionFailed
```

Adapter packages later expose their own parsers for an `Import` group; they consume this
package's rendering conventions without adding legacy constructors to `MigrationCommand`.
