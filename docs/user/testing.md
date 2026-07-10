# Testing

`pg-migrate-test-support` is an optional test-only dependency. It never enters the normal
core, embed, CLI, or adapter production closures.

```haskell
withMigratedDatabase plan $ \connection ->
  Connection.use connection assertionSession
```

The helper starts a fresh `ephemeral-pg` instance, runs the complete plan, releases the
runner's dedicated connection, acquires a different Hasql connection, runs the callback,
and brackets cleanup. `MigratedDatabaseError` distinguishes startup, migration, callback
acquisition, callback, cleanup, and combined callback/cleanup failures. Use
`withMigratedDatabaseOptions` for a custom ledger/lock policy and
`withMigratedDatabaseConfig` for an explicit ephemeral server configuration.

Repository integration suites can instead use `PG_CONNECTION_STRING` and unique ledger
schemas. `just acceptance` owns the full aggregate and production-closure checks; explicit
Nix shells `postgresql17` and `postgresql18` select the supported server majors.
