# Manifest format v1

`manifestFormatVersion == 1`. A manifest has no in-file version marker. It is UTF-8 and
contains a non-empty ordered sequence of unique top-level relative `.sql` filenames, one
per line, with no surrounding whitespace.

Version 1 rejects blank/comment lines, absolute paths, parent traversal, nested paths,
non-SQL or empty basenames, duplicates, missing files, invalid UTF-8, and any sibling SQL
file omitted from the manifest. CRLF is normalized only at the line terminator. SQL file
bytes themselves are embedded unchanged and SHA-256 is computed over those exact bytes.

Changing these parsing or ordering rules is a manifest contract change. Adding a future
format requires a new exported supported version and migration/release documentation; v1
files do not acquire a header retroactively.
