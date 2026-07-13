# Manifest authoring

A manifest makes migration order explicit and lets `pg-migrate-embed` validate file
membership and embed SQL at compile time. Production code reads the embedded bytes from
the executable; it does not scan a migrations directory at runtime. The core component
constructor validates the embedded SQL when the application constructs its plan.

## Directory layout

Keep one manifest beside the SQL files for one component:

```text
migrations/accounts/
├── 0001-create-accounts.sql
├── 0002-add-account-status.sql
└── manifest
```

The manifest is a UTF-8 text file containing exactly one filename per line, in execution
order:

```text
0001-create-accounts.sql
0002-add-account-status.sql
```

The final newline is optional. The manifest must contain at least one entry.

## Format rules

Manifest format v1 intentionally has no directives, comments, or header. Every entry must
be a plain, relative, top-level filename ending in lowercase `.sql`.

The validator rejects:

- an empty manifest or a blank line;
- lines beginning with `#` or `--`, including indented comment lines;
- leading or trailing whitespace;
- absolute paths, `..`, and nested paths such as `archive/0001.sql`;
- a filename without `.sql` or with an empty basename;
- duplicate entries or an entry whose file is missing;
- any sibling `.sql` file not listed in the manifest;
- a manifest that is not valid UTF-8.

Rejecting unlisted SQL files catches a common mistake: creating a migration file but
forgetting to put it in the ordered plan. Non-SQL files may live beside the manifest and
are ignored.

`manifestFormatVersion == 1` identifies the supported contract. The normative details are
in the [manifest v1 reference](../reference/manifest-v1.md).

## Embed a manifest

Enable `TemplateHaskell`, then splice the manifest into a component:

```haskell
{-# LANGUAGE TemplateHaskell #-}

import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Embed

accountsComponent :: Either DefinitionError MigrationComponent
accountsComponent =
  migrationComponentFromEmbeddedSql
    "accounts"
    Set.empty
    $(embedMigrationManifest "migrations/accounts/manifest")
```

The path is resolved relative to the Cabal project during compilation. The splice:

1. validates the manifest and all referenced files;
2. registers the manifest and every SQL file as compiler dependencies;
3. embeds each filename and its exact `ByteString` payload in manifest order.

Changing a listed file or the manifest therefore triggers recompilation. Cabal source
distributions still need the files, so include them with `extra-source-files` or
`data-files` in the package definition.

The `.sql` suffix is removed to derive the local migration name. For example,
`0002-add-account-status.sql` in component `accounts` becomes the durable identity
`accounts/0002-add-account-status`.

## Write transactional SQL

SQL is transactional by default and a file may contain multiple statements:

```sql
ALTER TABLE accounts
  ADD COLUMN status text NOT NULL DEFAULT 'active';

CREATE INDEX accounts_status_idx ON accounts (status);
```

The runner executes this payload and records its ledger row in one PostgreSQL transaction.
If either statement fails, neither the schema change nor the applied ledger state commits.

The validator understands line comments, nested block comments, quoted strings and
identifiers, and dollar-quoted function bodies when identifying statements. It rejects
empty SQL, invalid UTF-8, unterminated constructs, explicit transaction-control commands,
psql meta-commands, and `COPY FROM STDIN`.

Do not put `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, or similar transaction control in a
migration. The runner owns the transaction boundary.

## Write nontransactional SQL

Some PostgreSQL commands cannot run inside a transaction. Put this exact directive in the
leading comment region:

```sql
-- pg-migrate: no-transaction
CREATE INDEX CONCURRENTLY accounts_email_idx ON accounts (email);
```

A nontransactional file must contain exactly one SQL statement. Leading whitespace and
ordinary leading comments are allowed, but the directive must appear before SQL begins.
Unknown `pg-migrate:` directives and duplicate `no-transaction` directives are rejected.

Nontransactional migrations have an intentionally conservative failure model. A process
crash can leave the database effect ambiguous, so the ledger may remain `Running` or
record `Failed`. Before deploying one, read the
[nontransactional repair runbook](../operations/nontransactional-repair.md).

Prefer normal transactional SQL whenever PostgreSQL permits it.

## Check a manifest

The mounted CLI can validate a manifest without connecting to PostgreSQL:

```console
my-service-migrate check --manifest migrations/accounts/manifest
my-service-migrate check --manifest migrations/accounts/manifest --json
```

Successful output lists the files and the SHA-256 checksum of each exact payload. It checks
manifest syntax, membership, and file readability; SQL syntax and transaction-mode rules
are validated when `migrationComponentFromEmbeddedSql` constructs the component. Run both
the manifest check and plan-construction tests in CI.

The library API is also available for authoring tools:

```haskell
checked <- checkMigrationManifest "migrations/accounts/manifest"
```

`checked` is either a structured `ManifestError` or a non-empty, ordered collection of
filenames and exact bytes.

## Create the next migration

Use `new` to avoid file and manifest races:

```console
my-service-migrate new \
  --manifest migrations/accounts/manifest \
  --description "Add account status"
```

For a consistently zero-padded numeric manifest, the command increments the largest
prefix while preserving its width. Given `0001-create-accounts.sql`, the inferred next
name is `0002.sql`. To choose the descriptive basename in the same atomic operation, pass:

```console
my-service-migrate new \
  --manifest migrations/accounts/manifest \
  --name 0002-add-account-status \
  --description "Add account status"
```

The `.sql` suffix on `--name` is optional. The command creates the SQL file exclusively,
writes the description as an initial SQL comment, and replaces the manifest atomically.
It will not overwrite an existing file. If manifest replacement fails, it removes the new
file when possible and returns a structured cleanup error otherwise.

Automatic numbering requires every existing basename to start with a zero-padded number
of the same width. Irregular manifests must use `--name`. When the next number no longer
fits the established width, choose an explicit project migration strategy rather than
silently changing naming conventions.

## Evolve an applied manifest safely

Once a migration has been applied, its filename-derived name, exact bytes, position, kind,
and transaction mode are durable history. Follow these rules:

- append a new filename to the end of the manifest;
- never edit or rename an applied SQL file, even for formatting or comments;
- never insert a migration before an applied entry;
- never remove or reorder an applied entry;
- review both the new SQL and the resulting `list` or `check` checksum.

If an unapplied migration is wrong, correct it before any environment applies it. If any
environment already applied it, append a corrective migration. A checksum mismatch is a
signal that the artifact and durable history differ; do not bypass it or edit the ledger.
