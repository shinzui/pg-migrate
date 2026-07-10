module Database.PostgreSQL.Migrate.Ledger.Migrations
  ( LedgerMigration,
    currentLedgerVersion,
    ledgerMigrationVersions,
    ledgerUpgradePath,
    initializeOrUpgradeLedger,
  )
where

import Data.Int (Int32)
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate.Ledger.Sql
import Database.PostgreSQL.Migrate.Ledger.Types
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions qualified as Transaction.Sessions
import PgMigrate.Prelude

data LedgerMigration = LedgerMigration
  { targetVersion :: !Int32,
    action :: !(Transaction ())
  }

currentLedgerVersion :: Int32
currentLedgerVersion = 1

ledgerMigrationVersions :: [Int32]
ledgerMigrationVersions = [1]

ledgerUpgradePath :: Int32 -> Either LedgerError [Int32]
ledgerUpgradePath databaseVersion
  | databaseVersion < 0 = Left (InvalidLedgerVersion databaseVersion)
  | databaseVersion > currentLedgerVersion =
      Left LedgerTooNew {databaseVersion, supportedVersion = currentLedgerVersion}
  | otherwise = Right (filter (> databaseVersion) ledgerMigrationVersions)

initializeOrUpgradeLedger :: LedgerConfig -> Text -> Session (Either LedgerError ())
initializeOrUpgradeLedger config runnerVersion = do
  ledgerExists <-
    Session.statement
      (ledgerSchemaText config)
      ledgerMetadataExistsStatement
  databaseVersion <-
    if ledgerExists
      then schemaVersion <$> Session.statement () (loadLedgerMetadataStatement config)
      else pure 0
  case ledgerUpgradePath databaseVersion of
    Left ledgerError -> pure (Left ledgerError)
    Right versions -> do
      traverse_ runMigration (migrationForVersion <$> versions)
      pure (Right ())
  where
    runMigration LedgerMigration {action} =
      Transaction.Sessions.transactionNoRetry
        Transaction.Sessions.Serializable
        Transaction.Sessions.Write
        action
    migrationForVersion = \case
      1 -> versionOneMigration config runnerVersion
      unsupported -> error ("missing ledger migration version " <> show unsupported)

versionOneMigration :: LedgerConfig -> Text -> LedgerMigration
versionOneMigration config runnerVersion =
  LedgerMigration
    { targetVersion = 1,
      action = do
        Transaction.sql (Text.Encoding.encodeUtf8 (ledgerVersionOneDdl config))
        Transaction.statement runnerVersion (insertLedgerMetadataStatement config)
    }
