module Database.PostgreSQL.Migrate.Repair
  ( repairMigration,
  )
where

import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Data.Version (showVersion)
import Database.PostgreSQL.Migrate.Ledger
import Database.PostgreSQL.Migrate.Ledger.Migrations
import Database.PostgreSQL.Migrate.Ledger.Sql
import Database.PostgreSQL.Migrate.Ledger.Types
import Database.PostgreSQL.Migrate.Plan (planDescription)
import Database.PostgreSQL.Migrate.Repair.Types
import Database.PostgreSQL.Migrate.Runner
import Database.PostgreSQL.Migrate.Runner.Types
import Database.PostgreSQL.Migrate.Types
import Hasql.Connection qualified as Connection
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions qualified as Transaction.Sessions
import Paths_pg_migrate qualified as Package
import PgMigrate.Prelude

repairMigration ::
  RunOptions ->
  ConnectionProvider ->
  MigrationPlan ->
  RepairRequest ->
  IO (Either RepairError RepairReport)
repairMigration options provider plan request = do
  result <-
    withRunLifecycle options provider $ \connection ->
      Right <$> repairLocked options connection plan request
  pure $ case result of
    Left migrationError -> Left (RepairRunnerError migrationError)
    Right repairResult -> repairResult

repairLocked ::
  RunOptions ->
  Connection.Connection ->
  MigrationPlan ->
  RepairRequest ->
  IO (Either RepairError RepairReport)
repairLocked options connection plan request = do
  initialized <-
    runSession
      connection
      (initializeOrUpgradeLedger (runLedgerConfig options) repairRunnerVersion)
  case initialized of
    Left migrationError -> pure (Left (RepairRunnerError migrationError))
    Right (Left ledgerError) ->
      pure (Left (RepairRunnerError (LedgerInitializationFailed ledgerError)))
    Right (Right ()) -> do
      loaded <- runSession connection (loadLedger (runLedgerConfig options))
      case loaded of
        Left migrationError -> pure (Left (RepairRunnerError migrationError))
        Right snapshot -> repairVerified options connection plan request snapshot

repairVerified ::
  RunOptions ->
  Connection.Connection ->
  MigrationPlan ->
  RepairRequest ->
  LedgerSnapshot ->
  IO (Either RepairError RepairReport)
repairVerified options connection plan request snapshot =
  case find ((== targetId) . storedMigrationId) (storedMigrations snapshot) of
    Nothing -> pure (Left (RepairTargetMissing targetId))
    Just stored ->
      case findPlannedMigration targetId plan of
        Nothing -> pure (Left (RepairTargetNotInPlan targetId))
        Just (position, migration) ->
          case validateRepairTarget targetId position migration stored verification of
            Left repairError -> pure (Left repairError)
            Right oldStatus ->
              case repairOperation request of
                MarkApplied -> markApplied options connection request oldStatus
                Retry -> retry options connection request oldStatus position migration
  where
    targetId = repairMigrationId request
    verification =
      comparePlanWithLedger
        RejectUnknownMigrations
        (planDescription plan)
        (storedMigrations snapshot)

validateRepairTarget ::
  MigrationId ->
  Int32 ->
  Migration ->
  StoredMigration ->
  VerificationReport ->
  Either RepairError MigrationStatus
validateRepairTarget targetId expectedPosition migration stored verification = do
  let StoredMigration
        { position = storedPosition,
          checksum = storedChecksum,
          kind = storedKind,
          transactionMode = storedMode,
          status = storedStatus
        } = stored
  if storedMode /= NonTransactional || migrationModeOf migration /= NonTransactional
    then Left (RepairTargetTransactional targetId)
    else Right ()
  if storedPosition /= fromIntegral expectedPosition
    || storedChecksum /= migrationChecksumOf migration
    || storedKind /= migrationKindOf migration
    || storedMode /= migrationModeOf migration
    then Left (RepairTargetMetadataMismatch targetId)
    else Right ()
  let unrelatedIssues = filter (not . targetStatusIssue targetId) (verificationIssues verification)
  case unrelatedIssues of
    [] -> Right ()
    _ -> Left (RepairBlockedByVerification (withVerificationIssues unrelatedIssues verification))
  case storedStatus of
    Applied -> Left (RepairTargetAlreadyApplied targetId)
    Running -> Right ()
    Failed -> Right ()
  Right storedStatus

markApplied ::
  RunOptions ->
  Connection.Connection ->
  RepairRequest ->
  MigrationStatus ->
  IO (Either RepairError RepairReport)
markApplied options connection request oldStatus = do
  transitioned <-
    runRepairTransaction
      connection
      (runLedgerConfig options)
      (repairLedgerRow request oldStatus Applied)
      prepareMarkAppliedStatement
  pure $ case transitioned of
    Left migrationError -> Left (RepairRunnerError migrationError)
    Right False -> Left (RepairTransitionFailed (repairMigrationId request))
    Right True ->
      Right
        RepairReport
          { repairedMigration = repairMigrationId request,
            operation = MarkApplied,
            oldStatus,
            newStatus = Applied
          }

retry ::
  RunOptions ->
  Connection.Connection ->
  RepairRequest ->
  MigrationStatus ->
  Int32 ->
  Migration ->
  IO (Either RepairError RepairReport)
retry options connection request oldStatus position migration = do
  started <- invokeEvent options (MigrationStarted (repairMigrationId request))
  case started of
    Left migrationError -> pure (Left (RepairRunnerError migrationError))
    Right () -> do
      prepared <-
        runRepairTransaction
          connection
          (runLedgerConfig options)
          (repairLedgerRow request oldStatus Running)
          prepareRetryStatement
      case prepared of
        Left migrationError -> pure (Left (RepairRunnerError migrationError))
        Right False -> pure (Left (RepairTransitionFailed (repairMigrationId request)))
        Right True -> do
          executed <-
            resumeNonTransactionalMigration
              options
              connection
              (repairMigrationId request)
              position
              migration
          pure $ case executed of
            Left migrationError -> Left (RepairRunnerError migrationError)
            Right _ ->
              Right
                RepairReport
                  { repairedMigration = repairMigrationId request,
                    operation = Retry,
                    oldStatus,
                    newStatus = Applied
                  }

runRepairTransaction ::
  Connection.Connection ->
  LedgerConfig ->
  RepairLedgerRow ->
  (LedgerConfig -> Statement.Statement RepairLedgerRow Int64) ->
  IO (Either MigrationError Bool)
runRepairTransaction connection config repairRow transitionStatement = do
  result <-
    Connection.use
      connection
      ( Transaction.Sessions.transactionNoRetry
          Transaction.Sessions.ReadCommitted
          Transaction.Sessions.Write
          $ do
            Transaction.statement repairRow (insertRepairAuditStatement config)
            affected <- Transaction.statement repairRow (transitionStatement config)
            when (affected /= 1) Transaction.condemn
            pure affected
      )
  pure $ first DatabaseSessionFailed ((== 1) <$> result)

repairLedgerRow ::
  RepairRequest ->
  MigrationStatus ->
  MigrationStatus ->
  RepairLedgerRow
repairLedgerRow request oldStatus newStatus =
  RepairLedgerRow
    { repairLedgerMigrationId = repairMigrationId request,
      repairLedgerOperation = case repairOperation request of MarkApplied -> "mark-applied"; Retry -> "retry",
      repairLedgerOldStatus = oldStatus,
      repairLedgerNewStatus = newStatus,
      repairLedgerReason = repairReason request,
      repairLedgerRunnerVersion = repairRunnerVersion
    }

findPlannedMigration :: MigrationId -> MigrationPlan -> Maybe (Int32, Migration)
findPlannedMigration targetId plan =
  find ((== targetId) . plannedId) (concatMap componentMigrations (toList (planComponentsOf plan)))
    >>= \(_, position, migration) -> Just (position, migration)
  where
    componentMigrations component =
      zipWith
        (\position migration -> (MigrationId (componentNameOf component) (migrationNameOf migration), position, migration))
        [1 ..]
        (toList (componentMigrationsOf component))
    plannedId (identifier, _, _) = identifier

targetStatusIssue :: MigrationId -> VerificationIssue -> Bool
targetStatusIssue targetId = \case
  StoredMigrationRunning identifier -> identifier == targetId
  StoredMigrationFailed identifier -> identifier == targetId
  _ -> False

verificationIssues :: VerificationReport -> [VerificationIssue]
verificationIssues VerificationReport {issues} = issues

withVerificationIssues :: [VerificationIssue] -> VerificationReport -> VerificationReport
withVerificationIssues issues VerificationReport {appliedMigrations, pendingMigrations, unknownMigrations} =
  VerificationReport {issues, appliedMigrations, pendingMigrations, unknownMigrations}

runSession ::
  Connection.Connection ->
  Session.Session value ->
  IO (Either MigrationError value)
runSession connection session = first DatabaseSessionFailed <$> Connection.use connection session

repairRunnerVersion :: Text
repairRunnerVersion = Text.pack (showVersion Package.version)
