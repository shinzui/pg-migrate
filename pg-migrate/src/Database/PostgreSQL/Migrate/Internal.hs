module Database.PostgreSQL.Migrate.Internal
  ( MigrationKind (..),
    TransactionMode (..),
    MigrationDescription (..),
    ComponentDescription (..),
    PlanDescription (..),
    planDescription,
    migrationChecksumBytes,
    migrationTransactionMode,
    migrationKind,
    migrationSqlBytes,
    PostgresIdentifier (..),
    LedgerMetadata (..),
    LedgerSnapshot (..),
    LedgerError (..),
    currentLedgerVersion,
    ledgerMigrationVersions,
    ledgerUpgradePath,
    initializeOrUpgradeLedger,
    quotePostgresIdentifier,
    ledgerVersionOneDdl,
  )
where

import Database.PostgreSQL.Migrate.Ledger.Migrations
  ( currentLedgerVersion,
    initializeOrUpgradeLedger,
    ledgerMigrationVersions,
    ledgerUpgradePath,
  )
import Database.PostgreSQL.Migrate.Ledger.Sql
  ( ledgerVersionOneDdl,
    quotePostgresIdentifier,
  )
import Database.PostgreSQL.Migrate.Ledger.Types
  ( LedgerError (..),
    LedgerMetadata (..),
    LedgerSnapshot (..),
    PostgresIdentifier (..),
  )
import Database.PostgreSQL.Migrate.Plan
  ( ComponentDescription (..),
    MigrationDescription (..),
    PlanDescription (..),
    planDescription,
  )
import Database.PostgreSQL.Migrate.Types
  ( Migration,
    MigrationAction (..),
    MigrationChecksum (..),
    MigrationKind (..),
    TransactionMode (..),
    migrationActionOf,
    migrationKindOf,
    migrationModeOf,
  )
import PgMigrate.Prelude

migrationChecksumBytes :: MigrationChecksum -> ByteString
migrationChecksumBytes (MigrationChecksum bytes) = bytes

migrationTransactionMode :: Migration -> TransactionMode
migrationTransactionMode = migrationModeOf

migrationKind :: Migration -> MigrationKind
migrationKind = migrationKindOf

migrationSqlBytes :: Migration -> Maybe ByteString
migrationSqlBytes migration =
  case migrationActionOf migration of
    SqlAction bytes -> Just bytes
    TransactionAction _ -> Nothing
    SessionAction _ -> Nothing
