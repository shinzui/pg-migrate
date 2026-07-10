module Database.PostgreSQL.Migrate.Internal
  ( MigrationKind (..),
    TransactionMode (..),
    MigrationDescription (..),
    ComponentDescription (..),
    PlanDescription (..),
    planDescription,
    migrationChecksumBytes,
  )
where

import Database.PostgreSQL.Migrate.Plan
  ( ComponentDescription (..),
    MigrationDescription (..),
    PlanDescription (..),
    planDescription,
  )
import Database.PostgreSQL.Migrate.Types
  ( MigrationChecksum (..),
    MigrationKind (..),
    TransactionMode (..),
  )
import PgMigrate.Prelude

migrationChecksumBytes :: MigrationChecksum -> ByteString
migrationChecksumBytes (MigrationChecksum bytes) = bytes
