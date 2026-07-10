---
id: 8
slug: import-codd-history-through-the-adapter
title: "Import Codd history through the adapter"
kind: exec-plan
created_at: 2026-07-10T15:50:24Z
intention: "intention_01kx6bkssqee4sz0gzw0tdvkkv"
master_plan: "docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md"
---

# Import Codd history through the adapter

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, an application with Codd history can read supported legacy ledger shapes,
verify selected filenames and optional SHA-256 manifest evidence, map them to current
`MigrationId`s, and atomically import the corresponding target prefix without executing
target actions. The adapter holds the configured legacy runner lock before the normal
`pg-migrate` lock, rejects partial nontransactional Codd rows, and never modifies the Codd
schema. Fixture tests cover both `codd_schema.sql_migrations` and
`codd.sql_migrations`, strict/unselected rows, payload evidence, locking, and audit output.


## Progress

(No implementation work has started.)


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Hold the Codd advisory lock on one dedicated source connection while the
  generic importer uses a second dedicated target connection.
  Rationale: This preserves source-before-target lock ordering without exposing a reusable
  raw connection from the core provider; both locks remain held through the target commit.
  Date: 2026-07-10

- Decision: Treat a Codd SHA-256 lock file as repository/source evidence, not proof of the
  exact bytes historically executed.
  Rationale: Codd stores filenames and status but no SQL checksum, so import still requires
  explicit confirmation policy.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Complete `docs/plans/6-import-migration-history-through-the-generic-model.md` first.
`docs/plans/7-build-the-reusable-migration-cli-and-json-contracts.md` is a soft dependency
for parser/rendering consistency. This plan creates
`pg-migrate-import-codd/pg-migrate-import-codd.cabal` and modules under
`Database.PostgreSQL.Migrate.History.Codd`. It depends on `pg-migrate`, Hasql, crypton,
and optional CLI machinery, but not `codd`, `codd-extras`, or `postgresql-simple`.

Mori locates Codd 0.2.0 at `/Users/shinzui/Keikaku/hub/haskell/codd-project/codd`.
Source inspection shows V1 and V2 tables in schema `codd_schema` without partial-status
columns, V3/V4 add `num_applied_statements` and `no_txn_failed_at`, and V5 renames the
schema to `codd`. Detect shapes through PostgreSQL catalogs and fixture-tested column lists,
not Codd internal modules. The adapter reads only documented shapes. It rejects a row with
`no_txn_failed_at IS NOT NULL`.

The default legacy lock key is hexadecimal `0x6B69726F6B754D67`, stored as the equivalent
signed `Int64`, but callers may configure another key. Codd processes that do not honor
that wrapper lock still require a maintenance window. A Codd-era `migrations.lock` maps
lowercase SHA-256 hex to filename and proves current source bytes match the checked-in
manifest, not what Codd necessarily ran.


## Plan of Work

Milestone 1 defines opaque `CoddSourceConfig`, row/evidence/report/error values, and safe
constructors. Configuration includes source provider/settings, legacy lock key, selected
filenames, strict-source policy, optional exact source payload map, optional parsed
SHA-256 manifest, and checked-in mappings. Validate all mapping targets and evidence keys
before connection acquisition. Keep filename-to-target mapping explicit; never infer a
component or target name from a timestamped filename.

Milestone 2 implements `Database.PostgreSQL.Migrate.History.Codd.Ledger`. On a dedicated
source connection, detect whether exactly one supported `codd_schema` or `codd` ledger
exists and select a typed query for that shape. Decode filename, applied timestamp, partial
failure marker where available, and statement count as diagnostic evidence. Reject unknown
columns, duplicate filenames, both schemas present, and partial failures. Preserve every
unselected row in the report; strict-source turns any unselected row into an error.

Milestone 3 implements lock and payload validation. Acquire the legacy session advisory
lock on the source connection before reading rows. If a manifest is supplied, require one
entry for every selected source filename, no duplicates/extras under strict mode, and
SHA-256 of supplied exact source bytes to match. Create `LedgerOnly` without a manifest or
`SourceManifestVerified` with it. A SamePayload mapping separately supplies exact source
SHA-256 to the generic importer and requires explicit Codd confirmation policy.

While the source lock remains held, invoke the generic importer through a second use of a
provider that supplies a new target connection. The generic importer acquires the normal
lock and writes target/audit rows. Release target connection/lock, then source lock and
connection, preserving primary and cleanup failures. Never issue DDL, UPDATE, or DELETE
against Codd objects.

Milestone 4 exposes `readCoddHistory`, `importCoddHistory`, and a mountable
`coddImportCommandParser`. The parser accepts source schema auto-detection, lock override,
mapping/config artifact, strict-source, confirmation, and output flags but reads no
environment. Add SQL fixtures for Codd V1 through V5 and tests for current/legacy names,
partial failure, duplicates, lock contention/order, manifest mismatch, selection,
idempotent target import, and unchanged Codd row counts.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`:

```bash
mori registry show mzabani/codd --full
sed -n '900,1070p' /Users/shinzui/Keikaku/hub/haskell/codd-project/codd/src/Codd/Internal.hs
nix develop
just create-database
cabal test pg-migrate-import-codd:pg-migrate-import-codd-test
cabal build pg-migrate-import-codd --dry-run
```

Expected focused evidence:

```text
Codd V1 fixture imports: OK
Codd V5 fixture imports: OK
partial nontransactional row rejected: OK
legacy lock precedes target lock: OK
Codd ledger remains unchanged: OK
```

Run `nix fmt`, `cabal build all`, and all workspace tests. Required trailers:

```text
MasterPlan: docs/masterplans/2-deliver-pg-migrate-v1-integrations-and-release.md
ExecPlan: docs/plans/8-import-codd-history-through-the-adapter.md
Intention: intention_01kx6bkssqee4sz0gzw0tdvkkv
```


## Validation and Acceptance

For each supported fixture shape, select an applied filename, map it to the first target
migration, and import. The target ledger/audit rows appear without running target SQL, the
Codd schema and row count are unchanged, and source timestamp/shape/status appear in audit
JSON. V3/V4/V5 partial failures reject before target mutation. Duplicate filenames,
unknown shapes, both schemas, missing selected rows, and manifest mismatches are distinct
errors.

Hold the legacy lock from another connection and show import cannot acquire the target lock
or write target rows. Release it and show success. A lenient import reports unselected rows;
strict-source rejects them. SamePayload requires verified source bytes and confirmation.
The dry-run Cabal plan must not contain `codd`, `codd-extras`, or
`postgresql-simple` in this package's production dependencies.


## Idempotence and Recovery

Reading and validation are repeatable and non-mutating. An identical completed target
import is idempotent through
`docs/plans/6-import-migration-history-through-the-generic-model.md`. Any changed evidence
is a conflict. A failure before target commit leaves no new target rows; release both
dedicated connections and rerun after correcting evidence. Never drop, rename, or update
the Codd schema as cleanup. Keep the old runner quiesced throughout read and import even
when the advisory lock is available.


## Interfaces and Dependencies

Use Hasql 1.10 typed queries and crypton SHA-256. Depend on `pg-migrate` and optionally
`pg-migrate-cli`; do not depend on legacy libraries. Required interfaces are:

```haskell
readCoddHistory :: CoddSourceConfig -> IO (Either CoddImportError CoddHistory)
importCoddHistory :: ImportOptions -> CoddSourceConfig -> ConnectionProvider -> MigrationPlan -> NonEmpty HistoryMapping -> IO (Either CoddImportError HistoryImportReport)
coddImportCommandParser :: MigrationPlan -> Parser CoddImportCommand
```

The adapter produces generic `ImportEvidence` and `HistoryMapping` values and delegates all
target prefix, checksum, idempotency, and audit writes to core.
