# Release policy

The six packages use coherent PVP-style versions. The 1.0 release bounds internal public
dependencies to `>= 1.0 && < 1.1`. Public Haskell API, ledger schema, manifest format, JSON
schema, and import mapping/evidence semantics are independent compatibility surfaces.

- Patch: fixes that preserve every public contract.
- Minor: backward-compatible API additions, new tested PostgreSQL major, or advance notice
  of a future compatibility removal.
- Major: breaking public API or semantic changes.

Ledger, manifest, and JSON version numbers change only when their own contract changes; a
package major does not automatically increment all three. Every release updates package
changelogs, compatibility, acceptance evidence, Haddocks, source distributions, and the
release checklist. Publish/upload is an explicit operator action after these local gates.
