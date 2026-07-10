# Manifest authoring

Manifest format v1 is a UTF-8 file containing exactly one migration filename per line. The
file order is migration order. Entries are plain, relative, top-level `.sql` filenames:

```text
0001-create-accounts.sql
0002-add-account-status.sql
```

Blank lines, comments, surrounding whitespace, absolute paths, `..`, nested paths,
non-SQL names, duplicates, missing files, invalid UTF-8, and unlisted sibling SQL files are
errors. The format has no header; `manifestFormatVersion == 1` states the library-supported
contract.

`embedMigrationManifest` registers the manifest and each SQL file as Template Haskell
dependencies and embeds exact bytes. Byte changes therefore change the SHA-256 migration
checksum and trigger recompilation. Use `pg-migrate check --manifest PATH` to inspect
checksums and `pg-migrate new --manifest PATH [--name NAME] DESCRIPTION` for exclusive file
creation plus atomic manifest replacement. Numeric manifests use a zero-padded sequence;
irregular manifests require an explicit name.
