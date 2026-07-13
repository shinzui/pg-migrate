# JSON schema v1

`jsonSchemaVersion == 1`. Every command value contains `schemaVersion`, `command`, and
`ok`, followed by either `data` or structured `error`. Field names, enum spelling, nulls,
array ordering, exact checksum hex, and UTC timestamp rendering are golden-tested.

Plan/list/check output describes immutable plan metadata. Status/verify output separates
issues, applied, pending, and unknown rows. Up reports start/finish times and per-migration
`alreadyApplied` or `appliedNow`. Repair reports target, operation, and old/new state.
Errors contain a stable type namespace plus diagnostic message.
Invalid command input uses the `input.invalid` type; for example, `new --description`
rejects control characters before creating a file. Manifest syntax errors and manifest IO
errors retain the `manifest.invalid` type, while the command's exit class distinguishes
usage failures from runtime execution failures.

History import JSON is rendered with `renderHistoryImportJson`:

```json
{
  "schemaVersion": 1,
  "command": "import",
  "ok": true,
  "data": {
    "source": "codd",
    "results": [
      {"id": "accounts/0001", "outcome": "imported"},
      {"id": "accounts/0002", "outcome": "alreadyImported"}
    ]
  }
}
```

The canonical examples live in `pg-migrate-cli/test/golden/json`. Additive fields require
consumer review; removing/renaming fields or changing meaning requires a new schema version.
