---
id: 2
slug: validate-sql-and-embed-ordered-manifests
title: "Validate SQL and embed ordered manifests"
kind: exec-plan
created_at: 2026-07-10T15:50:23Z
intention: "intention_01kx6bkse1end9hcygcaemmtqc"
master_plan: "docs/masterplans/1-build-pg-migrate-v1-core-engine.md"
---

# Validate SQL and embed ordered manifests

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

After this plan, a component owner can place ordered `.sql` files beside a one-line-per-file
manifest, embed their exact bytes into a Haskell binary, and build a validated
`MigrationComponent`. The definition layer rejects unsafe transaction control, malformed
directives, invalid UTF-8, and ambiguous nontransactional scripts before any database is
contacted. Adding a migration through the authoring helper creates one file and appends it
to the manifest atomically. Tests demonstrate exact-byte SHA-256 behavior and prove that
changing either the manifest or a listed file recompiles the embedding module.


## Progress

- [x] (2026-07-10 10:42 PDT) Milestone 1: implemented strict UTF-8 validation, SQL
  lexical classification, structured definition errors, and exact-byte `sqlMigration`;
  all 65 core unit tests pass.
- [x] (2026-07-10 10:49 PDT) Milestone 2: implemented manifest checking and
  Template Haskell embedding; all 13 embed-package manifest tests pass.
- [x] (2026-07-10 10:55 PDT) Milestone 3: constructed components from embedded
  manifest entries and proved manifest order, suffix-derived names, per-file transaction
  modes, and structured error preservation; all 17 embed-package tests pass.
- [x] (2026-07-10 11:12 PDT) Milestone 4: implemented crash-conservative migration
  authoring with zero-padded sequence inference, explicit-name validation, exclusive file
  creation, atomic manifest replacement, and rollback after simulated replacement failure;
  all 24 embed-package tests pass.
- [ ] Milestone 5: prove manifest and SQL input changes trigger recompilation.
- [ ] Run final formatting, builds, tests, and plan closeout.


## Surprises & Discoveries

- Observation: GHC 9.12's `makeRelativeToProject` resolves relative splice inputs against
  the package root and `addDependentFile` expects the resulting absolute path. The embedder
  therefore resolves once, registers the manifest and every listed SQL file by absolute
  path, and retains only the manifest basenames in its generated value.
  Evidence: the package test compiles a real splice over
  `test/fixtures/valid/migrations/manifest` and observes its non-sorted manifest order.

- Observation: GHC 9.12 brings Prelude's `ioError` into scope, so an identically named
  structured-error helper is ambiguous rather than shadowing Prelude silently. The
  authoring implementation uses the unambiguous `authoringIoError` name and avoids
  partial list functions under `-Wall -Wcompat`.
  Evidence: the first focused build reported `Ambiguous occurrence ‘ioError’`; after the
  rename and numeric-prefix pattern match, all 24 embed-package tests pass without source
  warnings.


## Decision Log

- Decision: Implement a purpose-built lexical classifier rather than depend on a SQL AST
  library.
  Rationale: The required behavior is deliberately narrow—find safe top-level statement
  boundaries and transaction-control commands while preserving exact bytes—and no
  locally registered `postgresql-syntax` dependency is available.
  Date: 2026-07-10

- Decision: Validate UTF-8 once in `sqlMigration` but retain the original `ByteString` in
  the action.
  Rationale: Hasql 1.10 sessions accept `Text`, while the public checksum contract covers
  exact original bytes including comments and whitespace.
  Date: 2026-07-10

- Decision: Validate UTF-8 with a small byte-level classifier before calling the total
  `decodeUtf8` function.
  Rationale: `text`'s public strict decoder identifies malformed input but does not expose
  the failing byte offset required by the structured definition error contract. The
  classifier rejects overlong encodings, surrogate code points, out-of-range code points,
  truncated sequences, and invalid continuation bytes without normalizing valid payloads.
  Date: 2026-07-10

- Decision: Expose a narrowly scoped `Database.PostgreSQL.Migrate.Embed.Internal` module
  containing only the injectable manifest-renaming variant.
  Rationale: deterministic tests must prove rollback after replacement failure without
  relying on platform-specific permission behavior, while the stable facade exposes only
  `newMigration` and opaque validated options.
  Date: 2026-07-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Implement `docs/plans/1-bootstrap-the-pg-migrate-workspace-and-pure-model.md` first. It
creates the opaque `Migration` representation, `SqlAction ByteString`, identifier smart
constructors, `MigrationComponent`, and the root public facade. This plan completes the SQL
constructor and adds the separate `pg-migrate-embed/` package. The specification sections
9 and 15 are normative.

The locally registered Hasql 1.10.3.5 source uses `Text` for `Hasql.Session.script` and
for `Hasql.Statement.unpreparable`; `Hasql.Transaction.sql` in
`hasql-transaction` 1.2.2 accepts bytes. The definition layer therefore checks strict
UTF-8 without normalizing the `ByteString`. A lexical scanner recognizes token and
statement boundaries without constructing a PostgreSQL syntax tree. It must understand
single-quoted standard and escape strings, double-quoted identifiers, dollar-quoted
bodies, line comments, nested block comments, and semicolons only at top level.

A manifest is a UTF-8 text file whose every line is one relative `.sql` basename in
execution order. Blank lines and comments are errors. The manifest, not filename sorting,
is authoritative. Template Haskell dependency registration tells GHC which input files
must trigger recompilation.


## Plan of Work

Milestone 1 adds `pg-migrate/src/Database/PostgreSQL/Migrate/Sql/Scanner.hs` and
`pg-migrate/src/Database/PostgreSQL/Migrate/Sql.hs`. Scan bytes only after strict UTF-8 decoding has
succeeded, while retain byte offsets where useful for errors. Parse only the leading
whitespace/comment region for `-- pg-migrate: no-transaction`; accept it at most once and
reject every unknown `pg-migrate` directive. Reject psql meta-command lines and `COPY ...
FROM STDIN`. Classify top-level statements, reject `BEGIN`, `START TRANSACTION`, `COMMIT`,
`END`, `ROLLBACK`, `ABORT`, `SAVEPOINT`, `RELEASE SAVEPOINT`, `PREPARE TRANSACTION`,
`COMMIT PREPARED`, and `ROLLBACK PREPARED`. Transactional SQL may contain multiple safe
statements. Nontransactional SQL must contain exactly one non-empty statement.

Complete `sqlMigration` in
`pg-migrate/src/Database/PostgreSQL/Migrate/Definition.hs`. It validates
the name, runs the scanner, selects `Transactional` unless the leading directive says
otherwise, computes `Crypto.Hash.SHA256` over the original bytes, and stores `SqlKind` and
`SqlAction`. Errors name the directive, top-level command, statement count, or invalid
UTF-8 offset rather than returning free-form exceptions.

Milestone 2 creates `pg-migrate-embed/pg-migrate-embed.cabal` and
`pg-migrate-embed/src/Database/PostgreSQL/Migrate/Embed.hs`, then adds that package to
`cabal.project`. Implement a pure manifest parser and an `IO` checker that rejects missing
files, duplicate entries, absolute paths, parent traversal, nested paths, non-`.sql`
entries, and `.sql` files in the manifest directory that are unlisted. The Template
Haskell `embedMigrationManifest` reads the manifest during compilation, calls
`Language.Haskell.TH.Syntax.addDependentFile` for the manifest and every listed file, and
emits `NonEmpty (FilePath, ByteString)` in manifest order. Do not use directory iteration
order as execution order.

Milestone 3 implements `migrationComponentFromEmbeddedSql` in the core facade. It strips
only the `.sql` suffix to obtain each local migration name, calls `sqlMigration` for every
entry, and calls `migrationComponent`; it preserves the manifest order and all structured
definition errors. Add example fixtures under
`pg-migrate-embed/test/fixtures/valid/migrations/` and malformed fixture directories for
each rejection class.

Milestone 4 adds authoring functions to the embed package. When every existing basename
starts with one zero-padded numeric sequence of the same width, calculate the next number;
otherwise require an explicit `--name` value from the future CLI. Validate the resulting
basename with the same manifest rules. Create the SQL file exclusively, write the caller's
template, write a sibling temporary manifest, flush and rename it atomically, and remove
the newly created empty/template file if manifest replacement fails. Never apply SQL.
Tests use a temporary directory and include collision and interrupted-update cases.

Milestone 5 adds a compile-time regression fixture. A small test package or generated
module splices `embedMigrationManifest`, prints embedded checksums, then changes a listed
file and the manifest in turn. The test must prove Cabal/GHC rebuilds without touching the
Haskell module. Keep this test deterministic and restore fixtures after each run.


## Concrete Steps

Work from `/Users/shinzui/Keikaku/bokuno/pg-migrate` after
`docs/plans/1-bootstrap-the-pg-migrate-workspace-and-pure-model.md` is complete:

```bash
mori registry show hasql/hasql --full
mori registry show kazu-yamamoto/crypton --full
nix develop
cabal build pg-migrate pg-migrate-embed
cabal test pg-migrate:pg-migrate-unit pg-migrate-embed:pg-migrate-embed-test
```

Run the compile-time fixture separately so its forced rebuild is visible:

```bash
cabal test pg-migrate-embed:pg-migrate-embed-recompilation
```

Expected summary:

```text
Test suite pg-migrate-unit: PASS
Test suite pg-migrate-embed-test: PASS
Test suite pg-migrate-embed-recompilation: PASS
```

Format with `nix fmt` and update this document at every stopping point. Every commit uses
Conventional Commits plus:

```text
MasterPlan: docs/masterplans/1-build-pg-migrate-v1-core-engine.md
ExecPlan: docs/plans/2-validate-sql-and-embed-ordered-manifests.md
Intention: intention_01kx6bkse1end9hcygcaemmtqc
```


## Validation and Acceptance

The scanner tests must show that a directive in a leading comment selects
`NonTransactional`, the same text inside a string or after `SELECT 1` does not, and an
unknown leading `pg-migrate` directive fails. Semicolons inside strings, dollar-quoted
functions, quoted identifiers, line comments, and nested block comments do not split
statements. A top-level transaction command fails. One `CREATE INDEX CONCURRENTLY`
statement with the directive succeeds; two statements fail. Invalid UTF-8, psql
meta-commands, and `COPY FROM STDIN` fail before any Hasql value is built.

Two SQL payloads differing only in one whitespace byte must have different SHA-256
checksums. The valid manifest embeds bytes in manifest order even when filenames sort
differently. Every malformed fixture must return the corresponding structured error.
Adding an unlisted `.sql` file fails the checker. The authoring test must produce the next
numeric file, append exactly one line, refuse an existing name, and leave the original
manifest byte-for-byte unchanged after simulated failure. The recompilation suite must
observe changed embedded output after changing either tracked input.


## Idempotence and Recovery

Parsing, checking, embedding, building, and tests are repeatable. The authoring helper is
intentionally not idempotent for the same new name: exclusive creation returns a structured
collision instead of overwriting. If file creation succeeds but manifest replacement
fails, cleanup removes only the file created by that call and retains the original
manifest. A crash after atomic manifest rename may leave a complete file and manifest
entry, which is a successful operation; a temporary manifest may be removed safely on the
next run. Never delete an existing migration to recover.


## Interfaces and Dependencies

The core package uses crypton SHA-256 and the types delivered by
`docs/plans/1-bootstrap-the-pg-migrate-workspace-and-pure-model.md`. The embed package
depends on `base`, `bytestring`, `directory`, `filepath`, `template-haskell`, `text`, and
`pg-migrate`; it does not depend on Hasql directly. Required interfaces are:

```haskell
sqlMigration :: Text -> ByteString -> Either DefinitionError Migration
embedMigrationManifest :: FilePath -> Q Exp
checkMigrationManifest :: FilePath -> IO (Either ManifestError (NonEmpty (FilePath, ByteString)))
migrationComponentFromEmbeddedSql :: Text -> Set Text -> NonEmpty (FilePath, ByteString) -> Either DefinitionError MigrationComponent
newMigration :: NewMigrationOptions -> IO (Either AuthoringError FilePath)
```

`NewMigrationOptions` must carry the manifest path, optional explicit basename, and initial
SQL bytes. Its constructor or smart constructor validates paths; no API accepts a runtime
migration directory for execution.


## Revision Note

2026-07-10: Recorded completion of crash-conservative authoring, its deterministic
failure-injection boundary, and the GHC 9.12 compile-time naming discovery.
