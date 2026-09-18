---
type: Reference
title: Release policy
description: PVP versioning policy for the pg-migrate packages and independent versioning of each public contract.
docId: DOC-7
tags: [release, pvp, versioning, compatibility]
generated:
  by: human:nadeem
  at: 2026-07-13T20:57:39Z
---

# Release policy

The six packages use coherent PVP-style versions. An `A.B` series bounds internal public
dependencies to `>= A.B && < A.(B+1)`; the 1.1 release uses `>= 1.1 && < 1.2`. Public
Haskell API, ledger schema, manifest format, JSON schema, and import mapping/evidence
semantics are independent compatibility surfaces.

- Patch: fixes that preserve every public contract.
- Minor: backward-compatible API additions, new tested PostgreSQL major, or advance notice
  of a future compatibility removal.
- Major: breaking public API or semantic changes.

Ledger, manifest, and JSON version numbers change only when their own contract changes; a
package major does not automatically increment all three. Every release updates package
changelogs, compatibility, acceptance evidence, Haddocks, source distributions, and the
release checklist. Publish/upload is an explicit operator action after these local gates.
