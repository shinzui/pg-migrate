# Nontransactional repair

Use repair only for a `Running` or `Failed` nontransactional migration after inspecting the
database result, logs, and PostgreSQL catalogs. A `Running` row after a crash is ambiguous:
the effect may be absent, partial, or complete.

Before repair, take a backup, quiesce competing writers, run `status`, and record the
evidence. Then choose exactly one confirmed operation with a non-empty reason:

- `--mark-applied`: only when the intended effect is completely present and safe.
- `--retry`: only when retrying the current action is safe after prerequisites/corrections.

The repair writes an append-only audit row with operation, old/new state, reason, role,
runner version, and time. Retry returns the row to `Running` and executes the action; a
second failure remains durable. Repair never changes transactional history and never
bypasses checksum, kind, mode, identity, position, or plan-prefix mismatches. Finish with
strict `verify` and preserve the audit output with deployment records.
