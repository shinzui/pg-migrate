# Plan composition

The final application owns the complete `MigrationPlan`. Libraries contribute components;
they do not choose a global order or run each other. This makes the artifact sent to an
environment the single declaration of the migration history that environment should have.

## Compose an explicitly ordered plan

Use `migrationPlan` when the application wants the source order to be authoritative:

```haskell
import Data.List.NonEmpty (NonEmpty (..))
import Database.PostgreSQL.Migrate

applicationPlan
  :: MigrationComponent
  -> MigrationComponent
  -> Either PlanError MigrationPlan
applicationPlan accounts billing =
  migrationPlan (accounts :| [billing])
```

`migrationPlan` preserves this order and verifies that every dependency appears before its
consumer. This is the clearest default because a reviewer can read the final order directly
from application code.

The input is `NonEmpty`: a plan must contain at least one component, and every component
must contain at least one migration.

## Dependencies and order

Suppose billing declares a dependency on component `accounts`:

```haskell
migrationComponentFromEmbeddedSql
  "billing"
  (Set.singleton "accounts")
  billingEntries
```

Then this order is valid:

```haskell
migrationPlan (accounts :| [billing])
```

and this one returns `DependencyPlacedAfterConsumer`:

```haskell
migrationPlan (billing :| [accounts])
```

A dependency is a component-level ordering constraint, not an instruction to import or
execute another package. The application must supply the concrete dependency component in
the same plan.

Unrelated components retain their input order. Use stable, intentional source order even
when no dependency forces it, because that order decides which pending component runs
first. Migration positions are durable within each component; component positions are not
stored as migration metadata.

## Resolve an unordered collection

`resolveMigrationPlan` performs a stable topological sort before validation:

```haskell
resolveMigrationPlan (billing :| [accounts])
```

With billing depending on accounts, the result orders accounts first. Among components
whose dependencies are already satisfied, the resolver preserves input order.

This helper is useful when components arrive from a registration layer and the application
cannot naturally list them in dependency order. Prefer `migrationPlan` for a small,
hand-written composition because its order is immediately visible and an accidental order
change becomes a construction error.

## Plan validation errors

Plan construction is pure and occurs before a database connection is acquired.

| `PlanError` | Meaning | Typical fix |
| --- | --- | --- |
| `DuplicateComponentName` | two components claim the same stable name | keep one owner or assign distinct stable names before release |
| `DuplicateMigrationName` | one component repeats a local migration name | rename the unapplied duplicate |
| `MissingComponentDependency` | a declared dependency is absent from the plan | add the concrete component or correct the dependency name |
| `DependencyPlacedAfterConsumer` | `migrationPlan` received a dependency after its consumer | reorder the input or intentionally use `resolveMigrationPlan` |
| `ComponentDependencyCycle` | the dependency graph cannot be ordered | remove or redesign the circular schema ownership |

Do not catch one of these errors and continue with a partial plan. Fail application
initialization and fix the declaration.

## A multi-package pattern

Each library exports a construction result from a stable public module:

```haskell
-- package accounts
accountsMigrations :: Either DefinitionError MigrationComponent

-- package billing
billingMigrations :: Either DefinitionError MigrationComponent
```

The application resolves definition errors and composes the values once:

```haskell
applicationPlan :: Either DefinitionError (Either PlanError MigrationPlan)
applicationPlan = do
  accounts <- accountsMigrations
  billing <- billingMigrations
  pure (migrationPlan (accounts :| [billing]))
```

Keeping this boundary has useful consequences:

- a library can release a new appended migration without owning deployment policy;
- the application artifact fixes the exact component versions and complete order;
- operators use one lock, one ledger comparison, and one `up` for the whole system;
- no component silently migrates a database when imported or initialized.

Avoid exposing raw SQL file paths from a library and asking the application to rediscover
them. Export the validated `MigrationComponent` so exact bytes and order are fixed at the
owner's compile boundary.

## Inspect the resolved plan

Use the standard local commands before contacting a database:

```console
my-service-migrate plan
my-service-migrate list
my-service-migrate plan --component billing
my-service-migrate list --migration 0001-create-invoices --json
```

`plan` shows component order and dependencies. `list` flattens migrations and displays
their identity, component-local position, checksum, kind, and transaction mode. Filters
only change displayed inspection output; they never change execution. `up` always applies
the complete validated pending plan.

## Evolve a plan after deployment

Within each component, the stored ledger must remain an applied prefix of the declared
migration sequence. After deployment:

- append migrations within their existing component;
- keep existing dependency relationships and component order stable unless a reviewed
  change is required for future pending work;
- do not remove a component whose migrations are stored;
- do not move a migration between components;
- do not reuse an old component or migration name for different behavior.

Adding a brand-new component at the end is the least surprising choice. Component position
is not stored in the ledger, so placing a new component elsewhere does not by itself cause
a metadata mismatch; it does change the order in which pending work runs. Place the new
component after every dependency and review its order relative to other pending components.

Unknown ledger rows—stored migrations absent from the plan—are preserved and reported.
`migrationStatus` honors the configured `UnknownMigrationsPolicy`, while
`verifyMigrationPlan` is always strict. Execution, repair, and history import also honor
the policy in their `RunOptions`: the default `RejectUnknownMigrations` rejects unknown
history, and applications that intentionally share a ledger may explicitly select
`AllowUnknownMigrations`. Allowing unknown rows never relaxes verification of migrations
owned by the active plan.

## Verification and pending migrations

`status` is the operational summary: it separates applied, pending, and unknown
migrations and reports inconsistencies. `verify` is strict: pending migrations are also
verification issues, so a reviewed new artifact normally fails pre-deployment verification
with the expected pending suffix, then succeeds after `up`.

Both commands compare the declared plan with the migration ledger. Neither proves that a
table or index still exists, nor that a manual database change matches a migration. Add
application-specific schema assertions where that distinction matters.

See [CLI integration](cli-integration.md) to expose these views and
[testing](testing.md) to validate composed plans against a fresh PostgreSQL instance.
