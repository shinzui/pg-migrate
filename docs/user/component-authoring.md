# Component authoring

A `MigrationComponent` is the unit of migration ownership. A reusable library exports its
component; the final application composes that component with the rest of the system. The
library does not connect to PostgreSQL, run migrations, or own a global plan.

## Component identity

Every component contains:

- a stable component name;
- a set of component names it depends on;
- a non-empty, ordered sequence of migrations.

Migration names are local to the component. The durable identity combines both names:

```text
accounts/0001-create-accounts
billing/0001-create-invoices
```

Component and migration names must be non-empty printable ASCII, must not contain `/` or
surrounding whitespace, and may contain at most 200 UTF-8 bytes. Keep names short,
descriptive, and stable. Changing a component name after release changes the identity of
every migration it owns.

## Prefer an embedded SQL component

Most components should use an ordered manifest:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module Accounts.Migrations (accountsMigrations) where

import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Embed

accountsMigrations :: Either DefinitionError MigrationComponent
accountsMigrations =
  migrationComponentFromEmbeddedSql
    "accounts"
    Set.empty
    $(embedMigrationManifest "migrations/accounts/manifest")
```

Export the value from a stable library module and include the manifest and SQL in the
package's source files. `migrationComponentFromEmbeddedSql` removes `.sql` from each
filename, validates the SQL, derives transaction mode, and computes a SHA-256 checksum
over the exact bytes.

See [manifest authoring](manifest-authoring.md) for format, validation, and safe append
rules.

## Declare dependencies

Dependencies describe schema prerequisites owned by other components. If billing creates
a foreign key to a table owned by accounts, declare the relationship by name:

```haskell
billingMigrations :: Either DefinitionError MigrationComponent
billingMigrations =
  migrationComponentFromEmbeddedSql
    "billing"
    (Set.singleton "accounts")
    $(embedMigrationManifest "migrations/billing/manifest")
```

The billing library does not import, embed, or run the accounts migrations. It only states
that an application must provide `accounts` earlier in the final plan. This keeps ownership
and package dependencies explicit.

Declare only real ordering requirements. Unrelated components remain free to preserve the
application's chosen order.

## Construct SQL migrations directly

When SQL does not come from a manifest, construct each migration from its exact bytes and
assemble a non-empty sequence:

```haskell
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate

component :: Either DefinitionError MigrationComponent
component = do
  createWidget <-
    sqlMigration
      "0001-create-widget"
      "CREATE TABLE widget (id bigint PRIMARY KEY)"
  migrationComponent "widget" Set.empty (createWidget :| [])
```

This is useful for generated definitions or very small components. An embedded manifest
is usually easier to review and append safely.

## Nontransactional SQL

SQL is transactional unless its leading comment region contains:

```sql
-- pg-migrate: no-transaction
```

A nontransactional SQL migration must contain exactly one statement. Use it only for a
command that PostgreSQL prohibits in a transaction, such as an appropriate `CREATE INDEX
CONCURRENTLY`. A failed or interrupted nontransactional migration may require human
inspection and a confirmed repair; read the
[repair runbook](../operations/nontransactional-repair.md) before shipping one.

## Haskell migrations

For work that cannot be expressed as static SQL, core exposes two advanced constructors:

```haskell
transactionMigration
  :: Text
  -> MigrationChecksum
  -> Hasql.Transaction.Transaction ()
  -> Either DefinitionError Migration

sessionMigration
  :: Text
  -> MigrationChecksum
  -> Hasql.Session.Session ()
  -> Either DefinitionError Migration
```

`transactionMigration` runs inside the same transaction as its ledger transition.
`sessionMigration` is nontransactional and has the same crash ambiguity as
nontransactional SQL.

Because an executable Haskell action has no canonical source bytes, the author must supply
a stable fingerprint. Derive it from a versioned, reviewable description of the action:

```haskell
backfillFingerprint :: MigrationChecksum
backfillFingerprint =
  migrationFingerprint
    "accounts/0003-backfill-status:v1:set-null-status-to-active"
```

Change the fingerprint whenever the action's durable behavior changes. Do not use a
timestamp, random value, build identifier, or compiler output: the fingerprint must remain
identical across builds that represent the same migration.

Prefer embedded SQL when possible. Haskell migrations are harder to review outside the
application source and put more responsibility on the author to maintain fingerprint
discipline.

## Definition errors

Smart constructors reject invalid definitions before the runner acquires a database
connection. Handle `DefinitionError` when assembling application startup state. Common
causes are:

| Error category | What to check |
| --- | --- |
| invalid component or migration name | empty value, surrounding whitespace, `/`, non-printable or non-ASCII characters, or excessive length |
| invalid embedded migration file | the manifest filename must end in `.sql` and have a non-empty basename |
| invalid SQL | UTF-8, directives, transaction commands, statement count, psql commands, or an unterminated SQL construct |
| invalid ledger schema | empty or reserved `pg_` name, NUL, or PostgreSQL's 63-byte limit |

Keep the error structured in application logs. Rendered `Show` text is diagnostic output,
not a stable machine-readable contract.

## Append-only evolution

After a migration is applied, never change its component name, local name, position,
checksum, kind, or transaction mode. In practice:

- append new migrations to the component's end;
- never reorder or remove an applied migration;
- never change an applied SQL file, including comments or whitespace;
- never replace an SQL migration with a Haskell action or change its transaction mode;
- append a corrective migration when old behavior needs changing.

The plan verifier detects these changes before running new work. This strictness protects
the database from an artifact that no longer describes the history it claims to extend.

Next, read [plan composition](plan-composition.md) for combining components and diagnosing
dependency errors.
