---
id: 6
slug: import-migration-history-through-the-generic-model
title: "Import migration history through the generic model"
kind: exec-plan
created_at: 2026-07-10T15:50:24Z
intention: "intention_01kx6bkse1end9hcygcaemmtqc"
master_plan: "docs/masterplans/1-build-pg-migrate-v1-core-engine.md"
---

# Import migration history through the generic model

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, a project can prove that legacy migration evidence corresponds to a
validated `pg-migrate` plan and record target migrations as Applied without running their
actions. The importer supports exact-payload and explicitly validated equivalent-state
histories, enforces component prefixes, and writes target metadata plus source evidence
atomically under the normal advisory lock. Repeating the identical import is a no-op;
conflicting evidence is rejected. Tests prove prefix, conflict, idempotency, audit, and
Haskell-migration restrictions without any Codd or `hasql-migration` dependency in core.


## Progress

- [x] (2026-07-10 13:42 PDT) Milestone 1: defined opaque evidence/import inputs,
  safe static evidence and state validators, validated requirements/mappings, conservative
  options, structured errors/reports, and the public facade; all 95 unit tests pass.
- [x] (2026-07-10 13:46 PDT) Milestone 2: resolved target metadata only from the current
  plan, enforced per-component prefixes and exact payload/Haskell/equivalent-state rules,
  and built deterministic mapping-complete audit JSON; all 15 focused history tests pass.
- [x] (2026-07-10 13:53 PDT) Milestone 3: reused the dedicated connection/version/
  timeout/lock lifecycle, ran state validators read-only, classified exact idempotent
  repeats and conflicts, and inserted all Applied/audit pairs in one transaction; all 3
  focused PostgreSQL history tests pass.
- [ ] Milestone 4: prove live import, idempotency, conflict, rollback, state validation,
  and full workspace acceptance.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Carry state verification as a Hasql read transaction in the import draft and
  promote its evidence to `StateVerified` only after success under the import lock.
  Rationale: Callers must not label arbitrary JSON as verified state, while adapters need
  a public source-agnostic domain-validation hook.
  Date: 2026-07-10

- Decision: Store source timestamps only in audit evidence and use import time for target
  Applied rows.
  Rationale: Legacy local timestamps without zones cannot truthfully become absolute
  execution times.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Complete `docs/plans/3-build-the-versioned-ledger-and-plan-verification.md` and
`docs/plans/4-run-transactional-migrations-under-a-dedicated-lock.md` first. The ledger
plan at `docs/plans/3-build-the-versioned-ledger-and-plan-verification.md` owns the
`migrations` and `history_imports` tables and target plan description. The transactional
runner plan owns the dedicated connection, server gate, advisory lock, and cleanup. Reuse
those contracts.
`docs/plans/5-run-and-repair-nontransactional-migrations.md` is a soft dependency because
both features touch audit statements and top-level exports, but import does not depend on
repair behavior.

Evidence is a fact read from a predecessor ledger, verified source payload, or domain state
check. A requirement combines evidence keys with `AllOf` and `AnyOf`. A mapping names one
target `MigrationId`, the requirement that proves it, and either `SamePayload key` or
`EquivalentState`. The importer always obtains target checksum, position, kind, and mode
from the current plan; source evidence never supplies target metadata.

`SamePayload` proves byte identity and applies only to SQL. `EquivalentState` admits a
different historical route only when a read-only Hasql transaction successfully produces
required `StateVerified` evidence and the operator enabled equivalent-history policy.
Maintenance-window quiescence remains an operational prerequisite; generic import cannot
prove a predecessor process is stopped.


## Plan of Work

Milestone 1 creates `pg-migrate/src/Database/PostgreSQL/Migrate/History/Types.hs` and
`pg-migrate/src/Database/PostgreSQL/Migrate/History/Validation.hs`. Implement the conceptual types in
section 19 of `docs/initial-spec.md` with opaque constructors wherever arbitrary
construction could forge validation. Validate non-empty evidence keys and source/reason,
unique keys and targets, requirements referencing existing evidence, and unambiguous
satisfaction. Require a `SamePayload` key to participate in its satisfied requirement.
Reject `SamePayload` for a Haskell target and require `EquivalentState` for it.

Static evidence constructors create `LedgerOnly`, `SourceManifestVerified`, and
`SourceLedgerChecksumVerified` with optional exact SHA-256. A `StateValidator` carries its
key and a `Hasql.Transaction.Transaction (Either StateValidationError Value)`. Execute it
with `transactionNoRetry ReadCommitted Read`; only success produces `StateVerified`.
Executable validators have no `Eq`, `Show`, or JSON instance.

Milestone 2 resolves targets purely. Flatten the plan in component and local order.
Imported targets for each component must form a prefix starting at position 1; duplicate,
gapped, and unknown targets fail. `SamePayload` compares source payload SHA-256 to target
checksum, never a predecessor checksum using another algorithm. Equivalent mapping
requires a satisfied StateVerified key and explicit `AllowEquivalentHistory`. Build audit
JSON deterministically from only evidence satisfying each mapping, preserving source
identity, timestamp form, strength, payload checksum, and details.

Milestone 3 creates `pg-migrate/src/Database/PostgreSQL/Migrate/History.hs`. Through the provider from
`docs/plans/4-run-transactional-migrations-under-a-dedicated-lock.md`, verify server
version, acquire the normal lock, initialize or upgrade and load the ledger, run state
validators, validate every mapping before writes, and reject conflicts. In one transaction
insert Applied target rows using import time, target metadata, and runner version, plus one
matching `history_imports` audit row per target. Never execute a target action.

An import repeated with equivalent normalized evidence and identical target metadata
returns `AlreadyImported` without writes. Any difference in evidence, mapping, reason,
target metadata, or audit JSON is `ImportConflict`. Emit structured events only at durable
boundaries and return imported/already-imported IDs. Preserve Hasql errors structurally.

Milestone 4 adds pure requirement/payload tests and integration tests for fresh import,
multi-component prefixes, duplicate targets, gaps, unknown targets, conflicts, identical
idempotency, changed evidence, atomic rollback, audit JSON, read-only state validation, and
Haskell equivalent state. Inspect the Cabal plan to prove core still has no Codd,
`hasql-migration`, or `postgresql-simple` dependency.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate`:

```bash
mori registry show hasql/hasql --full
nix develop
just create-database
cabal test pg-migrate:pg-migrate-unit --test-options='--pattern history'
cabal test pg-migrate:pg-migrate-integration --test-options='--pattern import'
cabal build pg-migrate --dry-run
```

Expected focused evidence:

```text
same-payload prefix import: OK
equivalent-state validator: OK
identical second import: OK
changed evidence conflict: OK
atomic audit rollback: OK
```

Run all tests, `nix fmt`, and `cabal build all`. Required trailers:

```text
MasterPlan: docs/masterplans/1-build-pg-migrate-v1-core-engine.md
ExecPlan: docs/plans/6-import-migration-history-through-the-generic-model.md
Intention: intention_01kx6bkse1end9hcygcaemmtqc
```


## Validation and Acceptance

Import the first two migrations of a three-entry component with matching exact-payload
evidence. The report shows two Imported IDs, the ledger shows Applied rows at positions 1
and 2 with current target checksums, and no target action ran. A second identical import
reports AlreadyImported and preserves row counts. A gap importing positions 1 and 3,
changed evidence, an unknown target, or a payload mismatch fails before any write.

For equivalent state, a successful read-only validator and explicit policy allow the
mapping; missing policy or a failing validator rejects it. SamePayload for a Haskell
migration fails. Force the second audit insert to fail and prove the target ledger insert
rolls back. Query `history_imports`: source timestamps remain in JSON, while target times
equal import time. `cabal build pg-migrate --dry-run` must not mention legacy engines.


## Idempotence and Recovery

An exact repeated import is idempotent. Any non-identical repeat is a conflict requiring
human investigation; there is no update path. Validation precedes one write transaction,
and ledger plus audit commit atomically, so correct a database error and rerun the same
import. Death before commit leaves no target row; death after commit is confirmed by the
identical rerun. Never delete legacy evidence or the audit table as recovery.


## Interfaces and Dependencies

Add `aeson` for `Value` and audit JSON; otherwise use core containers, time, Hasql, and
Hasql Transaction. Do not add predecessor packages. Required interfaces include the
conceptual section-19 types, safe constructors, and:

```haskell
stateValidator :: EvidenceKey -> Hasql.Transaction.Transaction (Either StateValidationError Value) -> StateValidator
historyImport :: Text -> Map EvidenceKey ImportEvidence -> [StateValidator] -> NonEmpty HistoryMapping -> Text -> Either HistoryDefinitionError HistoryImport
defaultImportOptions :: ImportOptions
withEquivalentHistory :: EquivalentHistoryPolicy -> ImportOptions -> ImportOptions
importMigrationHistory :: ImportOptions -> ConnectionProvider -> MigrationPlan -> HistoryImport -> IO (Either HistoryImportError HistoryImportReport)
```

Expose these through public `Database.PostgreSQL.Migrate.History` and re-export the common
surface from `Database.PostgreSQL.Migrate`. Constructors that could forge validated IDs,
state strength, or target metadata remain hidden.


## Revision Note

2026-07-10: Started implementation after EP-3 and EP-4 hard dependencies and the EP-5
soft dependency passed their complete acceptance gates; expanded Progress into four
independently verifiable milestones.

2026-07-10: Recorded the validated source-agnostic history model and public facade after
all 95 unit tests passed without exposing a constructor that can forge StateVerified.

2026-07-10: Recorded pure target resolution after prefix gaps, unknown targets, checksum
mismatches, Haskell payload claims, equivalent-state policy, and ambiguous requirements
all received focused coverage.

2026-07-10: Recorded the shared-lifecycle importer after live exact-payload and Haskell
equivalent-state imports passed, an identical repeat reported AlreadyImported, changed
evidence conflicted, and a forced second audit failure rolled back every target row.
