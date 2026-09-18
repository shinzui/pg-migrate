---
okf_version: "0.2"
---

# Guide

- [CLI integration](cli-integration.md) - Mount the reusable pg-migrate-cli commands in a service executable and integrate them with application configuration.
- [Component authoring](component-authoring.md) - Author a MigrationComponent with a stable identity, dependencies, SQL or Haskell migrations, and append-only evolution.
- [Manifest authoring](manifest-authoring.md) - Write, embed, check, and safely evolve an ordered SQL migration manifest with pg-migrate-embed.
- [Plan composition](plan-composition.md) - Compose library components into one application-owned MigrationPlan, resolve dependency order, and evolve the plan after deployment.
- [Testing](testing.md) - Test migrations without PostgreSQL, against fresh ephemeral databases, and in shared integration suites and CI.
- [Troubleshooting](troubleshooting.md) - Diagnose manifest, validation, plan, verification, locking, and CLI failures from their structured errors.

# Navigation

- [User guide](README.md) - Entry point that explains how pg-migrate fits into an application, which packages to choose, and where to find each task.

# Tutorial

- [Quickstart](quickstart.md) - Build a small application-owned migration plan, mount the standard commands, apply one migration, and verify the result.

