module Database.PostgreSQL.Migrate.Embed
  ( ManifestError (..),
    checkMigrationManifest,
    embedMigrationManifest,
    NewMigrationOptions,
    AuthoringError (..),
    newMigrationOptions,
    newMigration,
  )
where

import Database.PostgreSQL.Migrate.Embed.Authoring
  ( AuthoringError (..),
    NewMigrationOptions,
    newMigration,
    newMigrationOptions,
  )
import Database.PostgreSQL.Migrate.Embed.Manifest
  ( ManifestError (..),
    checkMigrationManifest,
    embedMigrationManifest,
  )
