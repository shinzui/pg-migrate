# Component authoring

A component has a validated ASCII name, an explicit dependency set, and a non-empty ordered
list of migrations. Migration names are local to the component; their stable identity is
`component/migration`. Construct SQL migrations with `sqlMigration` or use
`migrationComponentFromEmbeddedSql` so a manifest owns names and ordering.

SQL is transactional unless its first directive is:

```sql
-- pg-migrate: no-transaction
```

A nontransactional SQL migration must contain exactly one statement. PostgreSQL transaction
control, psql meta-commands, and `COPY FROM STDIN` are rejected. Haskell transaction and
session migrations require an explicit stable fingerprint because their executable action
cannot be hashed.

Never reorder, insert into, remove from, or edit an applied component prefix. Append new
migrations. A dependent component names its dependencies explicitly; it does not embed or
run their files. The final application composes concrete components in dependency order,
and `migrationPlan` rejects missing, later, duplicate, or cyclic dependencies.
