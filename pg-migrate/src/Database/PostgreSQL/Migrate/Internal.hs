{-# OPTIONS_HADDOCK hide #-}

module Database.PostgreSQL.Migrate.Internal
  ( MigrationKind (..),
    TransactionMode (..),
    MigrationDescription (..),
    ComponentDescription (..),
    PlanDescription (..),
    planDescription,
    componentNameText,
    migrationNameText,
    migrationIdComponent,
    migrationIdName,
    migrationChecksumBytes,
    migrationTransactionMode,
    migrationKind,
    migrationSqlBytes,
    PostgresIdentifier (..),
    postgresIdentifier,
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
    useConnectionProvider,
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
    postgresIdentifier,
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
  ( ConnectionProvider (..),
    runEventHandler,
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
    componentNameText,
    migrationActionOf,
    migrationIdComponent,
    migrationIdName,
    migrationKindOf,
    migrationModeOf,
    migrationNameText,
  )
import Hasql.Connection qualified as Connection
import Hasql.Errors qualified as Errors
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

useConnectionProvider ::
  ConnectionProvider ->
  (Connection.Connection -> IO value) ->
  IO (Either Errors.ConnectionError value)
useConnectionProvider ConnectionProvider {useDedicatedConnection} = useDedicatedConnection
