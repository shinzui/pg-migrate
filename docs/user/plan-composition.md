# Plan composition

Libraries export `MigrationComponent`, not a runner or a global plan. The application puts
the components in one explicit `NonEmpty` sequence and calls `migrationPlan`. Input order is
preserved for unrelated components; dependency declarations constrain only required order.

```haskell
applicationPlan accounts billing =
  migrationPlan (accounts :| [billing])
```

Plan validation rejects duplicate component names, duplicate local migration names,
missing dependencies, dependencies placed after consumers, and dependency cycles. The
result is opaque and immutable. `plan`/`list` expose descriptions for humans and tools
without exposing executable actions.

Changing an applied prefix by removal, insertion, reordering, kind, transaction mode, or
exact-byte checksum is a verification error. Appending is the normal evolution path. A
database row unknown to the plan is preserved and reported; status can be configured to
allow it for inspection, while strict verification rejects it.
