# Deployment runbook

1. Back up the database and verify restore procedures.
2. Build the same artifact that owns the reviewed embedded plan.
3. Run `plan`, `status`, and strict `verify` against the intended database and role.
4. Stop or quiesce application writers when the migration or cutover requires it.
5. Run the full `up` command as an explicit deployment job. Do not select a subset.
6. Record JSON/text output, release identity, database, role, and timestamps.
7. Run strict `verify` again before starting the new application version.

The runner acquires a session advisory lock, initializes/upgrades ledger schema v1, checks
the declared plan against durable history, and then advances in order. Transactional SQL
and its ledger row commit atomically. A nontransactional action uses durable `Running`,
`Applied`, or `Failed` states and needs the repair runbook after ambiguity.

Recovery is forward-only. Correct a pending migration or append a new migration. Never edit
ledger rows manually, downgrade the ledger, bypass a checksum mismatch, or assume `verify`
proves live-schema equality.
