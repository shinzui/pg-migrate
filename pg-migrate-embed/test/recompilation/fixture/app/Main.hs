module Main (main) where

import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.List.NonEmpty (NonEmpty)
import Database.PostgreSQL.Migrate qualified as Migrate
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)
import Database.PostgreSQL.Migrate.Internal qualified as Internal

main :: IO ()
main = traverse_ printChecksum embeddedMigrations
  where
    printChecksum =
      print
        . Internal.migrationChecksumBytes
        . Migrate.migrationFingerprint
        . snd

embeddedMigrations :: NonEmpty (FilePath, ByteString)
embeddedMigrations =
  $(embedMigrationManifest "migrations/manifest")
