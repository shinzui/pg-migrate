---
id: 9
slug: import-hasql-migration-history-through-the-adapter
title: "Import hasql-migration history through the adapter"
kind: exec-plan
created_at: 2026-07-10T15:50:24Z
intention: "intention_01kx6bkssqee4sz0gzw0tdvkkv"
master_plan: "docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md"
---

# Import hasql-migration history through the adapter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, a project can import a `hasql-migration` ledger from a validated qualified
table, verify the predecessor's base64-encoded MD5 against exact source bytes, and map
verified history to a native `pg-migrate` prefix. Direct identical payloads use
`SamePayload`; alternative histories use an explicit read-only domain validator and
`EquivalentState`. Duplicate legacy filenames and ambiguous evidence fail before target
writes. Fixture tests show valid/invalid MD5, local timestamp preservation, direct and
alternative routes, idempotency, and audit output without depending on the predecessor
Haskell package.


## Progress

(No implementation work has started.)


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Verify legacy MD5 and target SHA-256 as two separate claims over the same exact
  source bytes.
  Rationale: A matching predecessor checksum proves source-ledger consistency; only
  SHA-256 equality with the target proves `SamePayload`.
  Date: 2026-07-10

- Decision: Reject duplicate filenames even when duplicate rows are identical.
  Rationale: The legacy table has no uniqueness constraint, so selecting one row would
  conceal ambiguous history.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Complete `docs/plans/6-import-migration-history-through-the-generic-model.md` first.
`docs/plans/7-build-the-reusable-migration-cli-and-json-contracts.md` is a soft dependency.
This plan creates `pg-migrate-import-hasql-migration/` and public module
`Database.PostgreSQL.Migrate.History.HasqlMigration`. It depends on Hasql, crypton,
`memory`/byte-array encoding as needed, and `pg-migrate`, but not the
`hasql-migration` package.

Mori locates the predecessor source at
`/Users/shinzui/Keikaku/hub/haskell/hasql-migration`. Its current
`schema_migrations` shape is `filename text`, `checksum text`, and
`executed_at timestamp without time zone`; it has no primary or unique constraint. Source
inspection confirms the checksum is `convertToBase Base64 (hashWith MD5 bytes)`. Preserve
`executed_at` as `LocalTimeWithoutZone` in audit evidence rather than converting it to UTC.

The source table defaults to `public.schema_migrations` but is configurable through a
validated qualified identifier. Never rely on `search_path`. A source payload map is
caller-owned exact bytes keyed by legacy filename. The adapter verifies it against stored
MD5 before producing evidence. The target plan remains opaque; generic import resolves its
SHA-256 and metadata.


## Plan of Work

Milestone 1 defines `QualifiedTable`, `HasqlMigrationSourceConfig`, source rows,
selection/mapping inputs, reports, and errors. Parse exactly two PostgreSQL identifiers
separated by one dot, applying the same identifier grammar and safe quoting used for the
core ledger. Require explicit selected filenames and exact source payloads for every
selection. Read all rows in deterministic `(executed_at, filename)` order and reject any
duplicate filename before mapping.

Milestone 2 recomputes base64 MD5 over each selected payload using crypton `MD5` and
constant-time or ordinary equality appropriate for non-secret integrity data. Mismatch is
a source-evidence error containing filename and both encodings; it never reaches target
import. A valid row becomes `SourceLedgerChecksumVerified` with the exact source SHA-256
also attached. For `SamePayload`, the generic importer compares that SHA-256 with the
current SQL target checksum.

Milestone 3 supports alternative history. Accept `AllOf`/`AnyOf` mappings from callers and
one or more core `StateValidator`s. Run each validator through generic import under the
normal lock in `Read` mode; it must inspect schema/function contracts rather than trust
ledger names. Require operator opt-in to equivalent history. Unselected source rows are
reported, and strict-source rejects them. No mapping may silently consume evidence not
named in its requirement.

Milestone 4 exposes `readHasqlMigrationHistory`, `importHasqlMigrationHistory`, and
`hasqlMigrationImportCommandParser`. Add fixture DDL/rows under the package test tree for
valid MD5, invalid MD5, duplicate names, direct full install, two-step equivalent history,
failed state validator, local timestamp audit, strict source, identical second import, and
changed evidence conflict. Assert source tables are never modified.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`:

```bash
mori registry show shinzui/hasql-migration --full
sed -n '80,225p' /Users/shinzui/Keikaku/hub/haskell/hasql-migration/src/Hasql/Migration.hs
nix develop
just create-database
cabal test pg-migrate-import-hasql-migration:pg-migrate-import-hasql-migration-test
cabal build pg-migrate-import-hasql-migration --dry-run
```

Expected focused evidence:

```text
valid legacy MD5 accepted: OK
invalid legacy MD5 rejected: OK
duplicate filename rejected: OK
equivalent-state validator required: OK
source ledger unchanged: OK
```

Run `nix fmt`, `cabal build all`, and all tests. Required trailers:

```text
MasterPlan: docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md
ExecPlan: docs/plans/9-import-hasql-migration-history-through-the-adapter.md
Intention: intention_01kx6bkssqee4sz0gzw0tdvkkv
```


## Validation and Acceptance

Seed the default source table with a payload's correct base64 MD5 and import it through a
SamePayload mapping. The target ledger/audit appears without action execution, and audit
JSON keeps the local timestamp explicitly unzoned. Changing either stored checksum or
source bytes rejects before target mutation. Two rows with one filename reject even if all
columns match. A quoted custom schema/table succeeds without changing `search_path`.

For an alternative two-row route, names and MD5 evidence alone are insufficient. A passing
domain validator plus equivalent-history opt-in permits import; either missing element
rejects. Lenient selection reports unrelated rows and strict-source rejects them. Repeating
identical evidence is idempotent; changing evidence conflicts. The Cabal dry-run contains
no `hasql-migration` dependency for the adapter.


## Idempotence and Recovery

Source reads and checksum validation are repeatable and non-mutating. Target import inherits
the generic importer's atomic idempotency. Fix a bad payload/table configuration and rerun;
never update the predecessor checksum to force a match. An equivalent-state validator must
be read-only, so retrying it cannot change source state. Keep predecessor processes
quiesced during the maintenance window even though this source has no standard lock.


## Interfaces and Dependencies

Use Hasql 1.10, crypton `MD5` and `SHA256`, byte-array base64 encoding, `pg-migrate`, and
optionally `pg-migrate-cli`. Required interfaces are:

```haskell
qualifiedTable :: Text -> Either HasqlMigrationDefinitionError QualifiedTable
readHasqlMigrationHistory :: HasqlMigrationSourceConfig -> IO (Either HasqlMigrationImportError HasqlMigrationHistory)
importHasqlMigrationHistory :: ImportOptions -> HasqlMigrationSourceConfig -> ConnectionProvider -> MigrationPlan -> NonEmpty HistoryMapping -> IO (Either HasqlMigrationImportError HistoryImportReport)
hasqlMigrationImportCommandParser :: MigrationPlan -> Parser HasqlMigrationImportCommand
```

Delegate target prefix, SHA-256 equality, equivalent-state policy, idempotency, and audit
writes to `docs/plans/6-import-migration-history-through-the-generic-model.md`.
