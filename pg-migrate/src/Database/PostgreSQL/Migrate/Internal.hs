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
    LedgerConfig (..),
    ledgerSchemaText,
    comparePlanWithLedger,
    loadLedger,
    statusFromSnapshot,
    statusFromSnapshotWith,
    verifyFromSnapshot,
    loadStatus,
    loadVerification,
    runLedgerConfig,
    runLockWait,
    runStatementTimeout,
    runUnknownMigrationsPolicy,
    runEventHandler,
    checkServerVersion,
    classifyServerVersion,
    acquireAdvisoryLock,
    releaseAdvisoryLock,
    applyStatementTimeout,
    restoreStatementTimeout,
    readStatementTimeout,
    ResolvedHistoryMapping (..),
    resolveHistoryImport,
    stateVerifiedEvidence,
  )
where

import Database.PostgreSQL.Migrate.History.Validation
  ( ResolvedHistoryMapping (..),
    resolveHistoryImport,
    stateVerifiedEvidence,
  )
import Database.PostgreSQL.Migrate.Ledger
  ( comparePlanWithLedger,
    loadLedger,
    loadStatus,
    loadVerification,
    statusFromSnapshot,
    statusFromSnapshotWith,
    verifyFromSnapshot,
  )
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
  ( LedgerConfig (..),
    LedgerError (..),
    LedgerMetadata (..),
    LedgerSnapshot (..),
    PostgresIdentifier (..),
    ledgerSchemaText,
  )
import Database.PostgreSQL.Migrate.Plan
  ( ComponentDescription (..),
    MigrationDescription (..),
    PlanDescription (..),
    planDescription,
  )
import Database.PostgreSQL.Migrate.Runner.Connection
  ( checkServerVersion,
    classifyServerVersion,
  )
import Database.PostgreSQL.Migrate.Runner.Lock
  ( acquireAdvisoryLock,
    applyStatementTimeout,
    readStatementTimeout,
    releaseAdvisoryLock,
    restoreStatementTimeout,
  )
import Database.PostgreSQL.Migrate.Runner.Types
  ( runEventHandler,
    runLedgerConfig,
    runLockWait,
    runStatementTimeout,
    runUnknownMigrationsPolicy,
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
