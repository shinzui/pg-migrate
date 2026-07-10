module Database.PostgreSQL.Migrate.Inspection
  ( migrationStatus,
    migrationStatusWith,
    verifyMigrationPlan,
    verifyMigrationPlanWith,
  )
where

import Database.PostgreSQL.Migrate.Ledger (loadStatus, loadVerification)
import Database.PostgreSQL.Migrate.Ledger.Types (StatusReport, VerificationReport)
import Database.PostgreSQL.Migrate.Runner.Connection
  ( checkServerVersion,
    connectionProviderFromSettings,
  )
import Database.PostgreSQL.Migrate.Runner.Types
  ( ConnectionProvider (..),
    MigrationError (..),
    RunOptions,
    runLedgerConfig,
    runUnknownMigrationsPolicy,
  )
import Database.PostgreSQL.Migrate.Types (MigrationPlan)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Session (Session)

migrationStatus ::
  RunOptions ->
  Settings.Settings ->
  MigrationPlan ->
  IO (Either MigrationError StatusReport)
migrationStatus options settings =
  migrationStatusWith options (connectionProviderFromSettings settings)

migrationStatusWith ::
  RunOptions ->
  ConnectionProvider ->
  MigrationPlan ->
  IO (Either MigrationError StatusReport)
migrationStatusWith options provider plan =
  runReadOnlySession
    provider
    (loadStatus (runLedgerConfig options) (runUnknownMigrationsPolicy options) plan)

verifyMigrationPlan ::
  RunOptions ->
  Settings.Settings ->
  MigrationPlan ->
  IO (Either MigrationError VerificationReport)
verifyMigrationPlan options settings =
  verifyMigrationPlanWith options (connectionProviderFromSettings settings)

verifyMigrationPlanWith ::
  RunOptions ->
  ConnectionProvider ->
  MigrationPlan ->
  IO (Either MigrationError VerificationReport)
verifyMigrationPlanWith options provider plan =
  runReadOnlySession provider (loadVerification (runLedgerConfig options) plan)

runReadOnlySession ::
  ConnectionProvider ->
  Session value ->
  IO (Either MigrationError value)
runReadOnlySession ConnectionProvider {useDedicatedConnection} session = do
  acquired <-
    useDedicatedConnection $ \connection -> do
      supported <- checkServerVersion connection
      case supported of
        Left migrationError -> pure (Left migrationError)
        Right _ -> do
          result <- Connection.use connection session
          pure $ case result of
            Left sessionError -> Left (DatabaseSessionFailed sessionError)
            Right value -> Right value
  pure $ case acquired of
    Left connectionError -> Left (ConnectionAcquisitionFailed connectionError)
    Right result -> result
