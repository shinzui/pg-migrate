module Database.PostgreSQL.Migrate.Ledger.Types
  ( PostgresIdentifier (..),
    LedgerConfig (..),
    defaultLedgerConfig,
    ledgerConfig,
    postgresIdentifier,
    postgresIdentifierText,
    ledgerSchemaText,
    ledgerLockKey,
    MigrationStatus (..),
    UnknownMigrationsPolicy (..),
    StoredMigration (..),
    LedgerMetadata (..),
    LedgerSnapshot (..),
    VerificationIssue (..),
    VerificationReport (..),
    StatusReport (..),
    LedgerError (..),
  )
where

import Data.ByteString qualified as ByteString
import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (UTCTime)
import Database.PostgreSQL.Migrate.Definition
  ( DefinitionError (..),
    PostgresIdentifierError (..),
  )
import Database.PostgreSQL.Migrate.Types
import PgMigrate.Prelude

newtype PostgresIdentifier = PostgresIdentifier
  { unPostgresIdentifier :: Text
  }
  deriving stock (Generic, Eq, Ord, Show)

data LedgerConfig = LedgerConfig
  { schema :: !PostgresIdentifier,
    lockKey :: !Int64
  }
  deriving stock (Generic, Eq, Show)

data MigrationStatus
  = Running
  | Applied
  | Failed
  deriving stock (Generic, Eq, Ord, Show)

data UnknownMigrationsPolicy
  = RejectUnknownMigrations
  | AllowUnknownMigrations
  deriving stock (Generic, Eq, Ord, Show)

data StoredMigration = StoredMigration
  { storedMigrationId :: !MigrationId,
    position :: !Int,
    checksum :: !MigrationChecksum,
    kind :: !MigrationKind,
    transactionMode :: !TransactionMode,
    status :: !MigrationStatus,
    startedAt :: !UTCTime,
    finishedAt :: !(Maybe UTCTime),
    executionTimeMilliseconds :: !(Maybe Int64),
    errorMessage :: !(Maybe Text),
    runnerVersion :: !Text
  }
  deriving stock (Generic, Eq, Show)

data LedgerMetadata = LedgerMetadata
  { schemaVersion :: !Int32,
    runnerVersion :: !Text
  }
  deriving stock (Generic, Eq, Show)

data LedgerSnapshot = LedgerSnapshot
  { metadata :: !(Maybe LedgerMetadata),
    storedMigrations :: ![StoredMigration]
  }
  deriving stock (Generic, Eq, Show)

data VerificationIssue
  = DuplicateStoredMigration !MigrationId
  | DuplicateStoredPosition !ComponentName !Int
  | StoredMigrationRunning !MigrationId
  | StoredMigrationFailed !MigrationId
  | MigrationPositionMismatch !MigrationId !Int !Int
  | MigrationChecksumMismatch !MigrationId !MigrationChecksum !MigrationChecksum
  | MigrationKindMismatch !MigrationId !MigrationKind !MigrationKind
  | MigrationTransactionModeMismatch !MigrationId !TransactionMode !TransactionMode
  | AppliedMigrationAfterGap !MigrationId !MigrationId
  | UnknownStoredMigration !MigrationId
  | PendingMigration !MigrationId
  deriving stock (Generic, Eq, Show)

data VerificationReport = VerificationReport
  { issues :: ![VerificationIssue],
    appliedMigrations :: ![MigrationId],
    pendingMigrations :: ![MigrationId],
    unknownMigrations :: ![StoredMigration]
  }
  deriving stock (Generic, Eq, Show)

data StatusReport = StatusReport
  { issues :: ![VerificationIssue],
    appliedMigrations :: ![MigrationId],
    pendingMigrations :: ![MigrationId],
    unknownMigrations :: ![StoredMigration]
  }
  deriving stock (Generic, Eq, Show)

data LedgerError
  = LedgerTooNew
      { databaseVersion :: !Int32,
        supportedVersion :: !Int32
      }
  | InvalidLedgerVersion !Int32
  deriving stock (Generic, Eq, Show)

defaultLedgerConfig :: LedgerConfig
defaultLedgerConfig =
  LedgerConfig
    { schema = PostgresIdentifier "pgmigrate",
      lockKey = 0x70675F6D69677261
    }

ledgerConfig :: Text -> Int64 -> Either DefinitionError LedgerConfig
ledgerConfig schemaInput lockKey = do
  schema <- postgresIdentifier schemaInput
  pure LedgerConfig {schema, lockKey}

postgresIdentifier :: Text -> Either DefinitionError PostgresIdentifier
postgresIdentifier input
  | Text.null input = invalid EmptyPostgresIdentifier
  | Text.any (== '\NUL') input = invalid PostgresIdentifierContainsNul
  | "pg_" `Text.isPrefixOf` input = invalid PostgresIdentifierHasReservedPrefix
  | byteLength > maximumPostgresIdentifierBytes =
      invalid
        PostgresIdentifierTooLong
          { actualBytes = byteLength,
            maximumBytes = maximumPostgresIdentifierBytes
          }
  | otherwise = Right (PostgresIdentifier input)
  where
    byteLength = ByteString.length (Text.Encoding.encodeUtf8 input)
    invalid postgresIdentifierReason =
      Left InvalidLedgerSchema {input, postgresIdentifierReason}

postgresIdentifierText :: PostgresIdentifier -> Text
postgresIdentifierText (PostgresIdentifier value) = value

ledgerSchemaText :: LedgerConfig -> Text
ledgerSchemaText LedgerConfig {schema} = postgresIdentifierText schema

ledgerLockKey :: LedgerConfig -> Int64
ledgerLockKey LedgerConfig {lockKey} = lockKey

maximumPostgresIdentifierBytes :: Int
maximumPostgresIdentifierBytes = 63
