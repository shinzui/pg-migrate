-- | Manifest format v1 validation, exact-byte Template Haskell embedding, and exclusive
-- migration authoring helpers.
module Database.PostgreSQL.Migrate.Embed
  ( manifestFormatVersion,
    ManifestError (..),
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
    manifestFormatVersion,
  )
