---
type: Reference
title: Manifest format v1
description: The version 1 migration manifest format, covering encoding, filename rules, rejections, and checksum semantics.
docId: DOC-5
tags: [manifest, format, checksums, contracts]
generated:
  by: human:nadeem
  at: 2026-07-13T19:27:29Z
---

# Manifest format v1

`manifestFormatVersion == 1`. A manifest has no in-file version marker. It is UTF-8 and
contains a non-empty ordered sequence of unique top-level relative `.sql` filenames, one
per line, with no surrounding whitespace.

Version 1 rejects blank/comment lines, absolute paths, parent traversal, nested paths,
non-SQL or empty basenames, duplicates, missing files, invalid UTF-8, a leading UTF-8
byte-order mark, and any sibling SQL file omitted from the manifest. CRLF is normalized
only at the line terminator. SQL file bytes themselves are embedded unchanged and SHA-256
is computed over those exact bytes.

Changing these parsing or ordering rules is a manifest contract change. Adding a future
format requires a new exported supported version and migration/release documentation; v1
files do not acquire a header retroactively.
