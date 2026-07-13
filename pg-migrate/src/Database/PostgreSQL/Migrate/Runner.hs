module Database.PostgreSQL.Migrate.Runner
  ( runMigrationPlan,
    runMigrationPlanWith,
    withRunLifecycle,
    resumeNonTransactionalMigration,
    invokeEvent,
  )
where

import Control.Exception
  ( AsyncException,
    SomeException,
    displayException,
    fromException,
    mask,
    throwIO,
    try,
  )
import Data.Int (Int32, Int64)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (NominalDiffTime, UTCTime, getCurrentTime)
import Data.Version (showVersion)
import Data.Word (Word64)
import Database.PostgreSQL.Migrate.Ledger
import Database.PostgreSQL.Migrate.Ledger.Migrations
import Database.PostgreSQL.Migrate.Ledger.Sql
import Database.PostgreSQL.Migrate.Ledger.Types
import Database.PostgreSQL.Migrate.Plan (planDescription)
import Database.PostgreSQL.Migrate.Runner.Connection
import Database.PostgreSQL.Migrate.Runner.Lock
import Database.PostgreSQL.Migrate.Runner.Types
import Database.PostgreSQL.Migrate.Types
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Errors
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions qualified as Transaction.Sessions
import Paths_pg_migrate qualified as Package
import PgMigrate.Prelude

data PlannedMigration = PlannedMigration
  { plannedId :: !MigrationId,
    plannedPosition :: !Int32,
    plannedMigration :: !Migration
  }

-- | Run a plan with a freshly acquired connection from concrete settings.
runMigrationPlan ::
  RunOptions ->
  Settings.Settings ->
  MigrationPlan ->
  IO (Either MigrationError MigrationReport)
runMigrationPlan options settings =
  runMigrationPlanWith options (connectionProviderFromSettings settings)

-- | Run a plan under the lock and timeout lifecycle using a provider.
runMigrationPlanWith ::
  RunOptions ->
  ConnectionProvider ->
  MigrationPlan ->
  IO (Either MigrationError MigrationReport)
runMigrationPlanWith options ConnectionProvider {useDedicatedConnection} plan = do
  (result, observedCleanupIssues) <-
    withRunLifecycle
      options
      (ConnectionProvider useDedicatedConnection)
      (\connection -> runLocked options connection plan)
  pure $ case attachCleanup observedCleanupIssues result of
    Left migrationError -> Left migrationError
    Right report -> Right report {cleanupIssues = observedCleanupIssues}

withRunLifecycle ::
  RunOptions ->
  ConnectionProvider ->
  (Connection.Connection -> IO (Either MigrationError value)) ->
  IO (Either MigrationError value, [CleanupIssue])
withRunLifecycle options ConnectionProvider {useDedicatedConnection} action =
  case validateOptions options of
    Left optionsError -> pure (Left optionsError, [])
    Right () -> do
      acquired <- useDedicatedConnection (\connection -> runOnConnection options connection action)
      pure $ case acquired of
        Left connectionError -> (Left (ConnectionAcquisitionFailed connectionError), [])
        Right result -> result

runOnConnection ::
  RunOptions ->
  Connection.Connection ->
  (Connection.Connection -> IO (Either MigrationError value)) ->
  IO (Either MigrationError value, [CleanupIssue])
runOnConnection options connection action = do
  serverVersion <- checkServerVersion connection
  case serverVersion of
    Left migrationError -> pure (Left migrationError, [])
    Right _ ->
      withStatementTimeoutResource options connection $ do
        waitEvent <- invokeEvent options (LockWaitStarted (runLockWait options))
        case waitEvent of
          Left eventError -> pure (Left eventError, [])
          Right () ->
            withAdvisoryLockResource options connection $ \lockDuration -> do
              acquiredEvent <- invokeEvent options (LockAcquired lockDuration)
              case acquiredEvent of
                Left eventError -> pure (Left eventError)
                Right () -> action connection

withStatementTimeoutResource ::
  RunOptions ->
  Connection.Connection ->
  IO (Either MigrationError value, [CleanupIssue]) ->
  IO (Either MigrationError value, [CleanupIssue])
withStatementTimeoutResource options connection action =
  mask $ \restore -> do
    applied <- applyStatementTimeout connection (runStatementTimeout options)
    case applied of
      Left migrationError -> pure (Left migrationError, [])
      Right previous -> do
        captured <- try @SomeException (restore action)
        cleanup <- restoreStatementTimeout connection previous
        finishResource captured [cleanup]

withAdvisoryLockResource ::
  RunOptions ->
  Connection.Connection ->
  (NominalDiffTime -> IO (Either MigrationError value)) ->
  IO (Either MigrationError value, [CleanupIssue])
withAdvisoryLockResource options connection action =
  mask $ \restore -> do
    acquired <-
      restore
        ( acquireAdvisoryLock
            connection
            (ledgerLockKey (runLedgerConfig options))
            (runLockWait options)
        )
    case acquired of
      Left migrationError -> pure (Left migrationError, [])
      Right lockDuration -> do
        captured <- try @SomeException (restore ((,[]) <$> action lockDuration))
        cleanup <-
          releaseAdvisoryLock connection (ledgerLockKey (runLedgerConfig options))
        finishResource captured [cleanup]

finishResource ::
  Either SomeException (Either MigrationError value, [CleanupIssue]) ->
  [Either CleanupIssue ()] ->
  IO (Either MigrationError value, [CleanupIssue])
finishResource captured cleanupResults = do
  let (observedCleanupIssues, _) = partitionEithers cleanupResults
  case captured of
    Left exception
      | isAsyncException exception -> throwIO exception
      | otherwise -> pure (Left (MigrationActionFailed exception), observedCleanupIssues)
    Right (result, existingCleanupIssues) ->
      pure (result, existingCleanupIssues <> observedCleanupIssues)

attachCleanup ::
  [CleanupIssue] ->
  Either MigrationError value ->
  Either MigrationError value
attachCleanup cleanupIssues result =
  case NonEmpty.nonEmpty cleanupIssues of
    Nothing -> result
    Just issues -> case result of
      Left primary -> Left (CleanupFailed primary issues)
      Right value -> Right value

runLocked ::
  RunOptions ->
  Connection.Connection ->
  MigrationPlan ->
  IO (Either MigrationError MigrationReport)
runLocked options connection plan = do
  initialized <-
    runSession
      connection
      (initializeOrUpgradeLedger (runLedgerConfig options) libraryRunnerVersion)
  case initialized of
    Left migrationError -> pure (Left migrationError)
    Right (Left ledgerError) -> pure (Left (LedgerInitializationFailed ledgerError))
    Right (Right ()) -> do
      loaded <- runSession connection (loadLedger (runLedgerConfig options))
      case loaded of
        Left migrationError -> pure (Left migrationError)
        Right snapshot -> runVerified options connection plan snapshot

runVerified ::
  RunOptions ->
  Connection.Connection ->
  MigrationPlan ->
  LedgerSnapshot ->
  IO (Either MigrationError MigrationReport)
runVerified options connection plan snapshot = do
  let verification =
        comparePlanWithLedger
          (runUnknownMigrationsPolicy options)
          (planDescription plan)
          (storedMigrations snapshot)
  case verification of
    VerificationReport {issues = _ : _} ->
      pure (Left (PlanVerificationFailed verification))
    VerificationReport {appliedMigrations, pendingMigrations} -> do
      let planned = flattenPlan plan
          plannedById = Map.fromList ((\migration -> (plannedId migration, migration)) <$> planned)
          pending = mapMaybe (`Map.lookup` plannedById) pendingMigrations
      validatedEvent <-
        invokeEvent
          options
          PlanValidated
            { alreadyAppliedCount = length appliedMigrations,
              pendingCount = length pending
            }
      case validatedEvent of
        Left eventError -> pure (Left eventError)
        Right () -> executeVerified options connection planned appliedMigrations pending

executeVerified ::
  RunOptions ->
  Connection.Connection ->
  [PlannedMigration] ->
  [MigrationId] ->
  [PlannedMigration] ->
  IO (Either MigrationError MigrationReport)
executeVerified options connection planned appliedIds pending = do
  reportStartedAt <- getCurrentTime
  reportStartedMonotonic <- getMonotonicTimeNSec
  executed <- executePending Map.empty pending
  case executed of
    Left migrationError -> pure (Left migrationError)
    Right executedById -> do
      reportFinishedAt <- getCurrentTime
      reportDuration <- elapsedSince reportStartedMonotonic
      completedEvent <- invokeEvent options (MigrationPlanCompleted reportDuration)
      case completedEvent of
        Left eventError -> pure (Left eventError)
        Right () ->
          case NonEmpty.nonEmpty (resultsInPlanOrder executedById) of
            Nothing -> error "migration plan unexpectedly produced no results"
            Just results ->
              pure
                ( Right
                    MigrationReport
                      { startedAt = reportStartedAt,
                        finishedAt = reportFinishedAt,
                        results,
                        cleanupIssues = []
                      }
                )
  where
    alreadyApplied =
      Map.fromList
        [ (identifier, MigrationResult identifier AlreadyApplied Nothing)
        | identifier <- appliedIds
        ]
    resultsInPlanOrder executedById =
      mapMaybe
        (\migration -> Map.lookup (plannedId migration) (Map.union executedById alreadyApplied))
        planned
    executePending accumulated [] = pure (Right accumulated)
    executePending accumulated (migration : rest) = do
      executed <- executePlannedMigration options connection migration
      case executed of
        Left migrationError -> pure (Left migrationError)
        Right result ->
          executePending (Map.insert (plannedId migration) result accumulated) rest

executePlannedMigration ::
  RunOptions ->
  Connection.Connection ->
  PlannedMigration ->
  IO (Either MigrationError MigrationResult)
executePlannedMigration options connection planned =
  case migrationModeOf (plannedMigration planned) of
    Transactional -> executeTransactional options connection planned
    NonTransactional -> executeNonTransactional options connection planned

executeTransactional ::
  RunOptions ->
  Connection.Connection ->
  PlannedMigration ->
  IO (Either MigrationError MigrationResult)
executeTransactional options connection planned = do
  startedEvent <- invokeEvent options (MigrationStarted identifier)
  case startedEvent of
    Left eventError -> pure (Left eventError)
    Right () -> do
      startedAt <- getCurrentTime
      startedMonotonic <- getMonotonicTimeNSec
      case transactionalAction (runLedgerConfig options) planned startedAt of
        Left migrationError -> finishFailure startedMonotonic migrationError
        Right transaction -> do
          attempted <- try @SomeException (Connection.use connection (runTransaction transaction))
          case attempted of
            Left exception
              | isAsyncException exception -> throwIO exception
              | otherwise -> finishFailure startedMonotonic (MigrationActionFailed exception)
            Right (Left sessionError) ->
              finishFailure startedMonotonic (DatabaseSessionFailed sessionError)
            Right (Right ()) -> do
              loaded <- runSession connection (loadLedger (runLedgerConfig options))
              case loaded of
                Left migrationError -> finishFailure startedMonotonic migrationError
                Right snapshot
                  | any ((== identifier) . storedMigrationId) (storedMigrations snapshot) ->
                      finishSuccess startedMonotonic
                  | otherwise -> finishFailure startedMonotonic (TransactionCondemned identifier)
  where
    identifier = plannedId planned
    finishSuccess started = do
      duration <- elapsedSince started
      completed <- invokeEvent options (MigrationCompleted identifier duration)
      pure $ case completed of
        Left eventError -> Left eventError
        Right () -> Right (MigrationResult identifier AppliedNow (Just duration))
    finishFailure started primary = do
      duration <- elapsedSince started
      observed <-
        invokeEventWithPrimary
          options
          primary
          (MigrationFailureObserved identifier duration)
      pure $ case observed of
        Left eventError -> Left eventError
        Right () -> Left primary

transactionalAction ::
  LedgerConfig ->
  PlannedMigration ->
  UTCTime ->
  Either MigrationError (Transaction ())
transactionalAction config PlannedMigration {plannedId, plannedPosition, plannedMigration} startedAt = do
  action <- case migrationActionOf plannedMigration of
    SqlAction bytes -> Right (Transaction.sql bytes)
    TransactionAction transaction -> Right transaction
    SessionAction _ -> Left (InvalidMigrationAction plannedId)
  pure $ do
    action
    Transaction.statement
      AppliedLedgerRow
        { appliedMigrationId = plannedId,
          appliedPosition = plannedPosition,
          appliedChecksum = migrationChecksumOf plannedMigration,
          appliedKind = migrationKindOf plannedMigration,
          appliedTransactionMode = migrationModeOf plannedMigration,
          appliedStartedAt = startedAt,
          appliedRunnerVersion = libraryRunnerVersion
        }
      (insertAppliedMigrationStatement config)

executeNonTransactional ::
  RunOptions ->
  Connection.Connection ->
  PlannedMigration ->
  IO (Either MigrationError MigrationResult)
executeNonTransactional options connection planned = do
  startedEvent <- invokeEvent options (MigrationStarted identifier)
  case startedEvent of
    Left eventError -> pure (Left eventError)
    Right () -> do
      startedAt <- getCurrentTime
      startedMonotonic <- getMonotonicTimeNSec
      let ledgerRow = appliedLedgerRow planned startedAt
      inserted <-
        runSession
          connection
          ( runTransaction
              ( Transaction.statement
                  ledgerRow
                  (insertRunningMigrationStatement (runLedgerConfig options))
              )
          )
      case inserted of
        Left migrationError -> finishFailureEvent startedMonotonic migrationError
        Right () ->
          executeNonTransactionalAfterRunning
            options
            connection
            planned
            ledgerRow
            startedMonotonic
  where
    identifier = plannedId planned
    finishFailureEvent started primary = do
      duration <- elapsedSince started
      observed <-
        invokeEventWithPrimary
          options
          primary
          (MigrationFailureObserved identifier duration)
      pure $ case observed of
        Left eventError -> Left eventError
        Right () -> Left primary

resumeNonTransactionalMigration ::
  RunOptions ->
  Connection.Connection ->
  MigrationId ->
  Int32 ->
  Migration ->
  IO (Either MigrationError MigrationResult)
resumeNonTransactionalMigration options connection identifier position migration = do
  startedAt <- getCurrentTime
  startedMonotonic <- getMonotonicTimeNSec
  let planned = PlannedMigration identifier position migration
      ledgerRow = appliedLedgerRow planned startedAt
  executeNonTransactionalAfterRunning options connection planned ledgerRow startedMonotonic

executeNonTransactionalAfterRunning ::
  RunOptions ->
  Connection.Connection ->
  PlannedMigration ->
  AppliedLedgerRow ->
  Word64 ->
  IO (Either MigrationError MigrationResult)
executeNonTransactionalAfterRunning options connection planned ledgerRow startedMonotonic = do
  action <- nonTransactionalAction connection planned
  case action of
    Left migrationError ->
      recordObservedFailure migrationError (renderMigrationError migrationError)
    Right runAction -> do
      attempted <- try @SomeException runAction
      case attempted of
        Left exception
          | isAsyncException exception -> throwIO exception
          | otherwise ->
              let primary = MigrationActionFailed exception
               in recordObservedFailure
                    primary
                    (Text.pack (displayException exception))
        Right (Left sessionError) ->
          let primary = NonTransactionalMigrationFailed identifier sessionError
           in recordObservedFailure primary (Errors.toDetailedText sessionError)
        Right (Right ()) -> do
          transitioned <- markRunningApplied options connection ledgerRow
          case transitioned of
            Left migrationError -> pure (Left migrationError)
            Right () -> finishSuccess
  where
    identifier = plannedId planned
    finishSuccess = do
      duration <- elapsedSince startedMonotonic
      completed <- invokeEvent options (MigrationCompleted identifier duration)
      pure $ case completed of
        Left eventError -> Left eventError
        Right () -> Right (MigrationResult identifier AppliedNow (Just duration))
    finishFailureEvent primary = do
      duration <- elapsedSince startedMonotonic
      observed <-
        invokeEventWithPrimary
          options
          primary
          (MigrationFailureObserved identifier duration)
      pure $ case observed of
        Left eventError -> Left eventError
        Right () -> Left primary
    recordObservedFailure primary diagnostic = do
      recorded <- markRunningFailed options connection ledgerRow diagnostic
      case recorded of
        Left recordingError ->
          pure
            ( Left
                (NonTransactionalFailureRecordingFailed identifier primary recordingError)
            )
        Right () -> finishFailureEvent primary

nonTransactionalAction ::
  Connection.Connection ->
  PlannedMigration ->
  IO
    ( Either
        MigrationError
        (IO (Either Errors.SessionError ()))
    )
nonTransactionalAction connection PlannedMigration {plannedId, plannedMigration} =
  pure $ case migrationActionOf plannedMigration of
    SqlAction bytes ->
      Right
        ( Connection.use
            connection
            ( Session.statement
                ()
                ( Statement.unpreparable
                    (Text.Encoding.decodeUtf8 bytes)
                    Encoders.noParams
                    Decoders.noResult
                )
            )
        )
    SessionAction session -> Right (Connection.use connection session)
    TransactionAction _ -> Left (InvalidMigrationAction plannedId)

markRunningApplied ::
  RunOptions ->
  Connection.Connection ->
  AppliedLedgerRow ->
  IO (Either MigrationError ())
markRunningApplied options connection ledgerRow = do
  transitioned <-
    runSession
      connection
      ( runTransaction
          ( Transaction.statement
              ledgerRow
              (markRunningMigrationAppliedStatement (runLedgerConfig options))
          )
      )
  pure $ transitioned >>= expectOneTransition ledgerRow Applied

markRunningFailed ::
  RunOptions ->
  Connection.Connection ->
  AppliedLedgerRow ->
  Text ->
  IO (Either MigrationError ())
markRunningFailed options connection ledgerRow diagnostic = do
  transitioned <-
    runSession
      connection
      ( runTransaction
          ( Transaction.statement
              FailedLedgerRow
                { failedLedgerIdentity = ledgerRow,
                  failedLedgerError = diagnostic
                }
              (markRunningMigrationFailedStatement (runLedgerConfig options))
          )
      )
  pure $ transitioned >>= expectOneTransition ledgerRow Failed

expectOneTransition ::
  AppliedLedgerRow ->
  MigrationStatus ->
  Int64 ->
  Either MigrationError ()
expectOneTransition ledgerRow targetStatus affected
  | affected == 1 = Right ()
  | otherwise =
      Left
        ( LedgerTransitionDidNotMatch
            (appliedMigrationId ledgerRow)
            Running
            targetStatus
        )

appliedLedgerRow :: PlannedMigration -> UTCTime -> AppliedLedgerRow
appliedLedgerRow PlannedMigration {plannedId, plannedPosition, plannedMigration} startedAt =
  AppliedLedgerRow
    { appliedMigrationId = plannedId,
      appliedPosition = plannedPosition,
      appliedChecksum = migrationChecksumOf plannedMigration,
      appliedKind = migrationKindOf plannedMigration,
      appliedTransactionMode = migrationModeOf plannedMigration,
      appliedStartedAt = startedAt,
      appliedRunnerVersion = libraryRunnerVersion
    }

renderMigrationError :: MigrationError -> Text
renderMigrationError = Text.pack . show

runTransaction :: Transaction value -> Session value
runTransaction =
  Transaction.Sessions.transactionNoRetry
    Transaction.Sessions.ReadCommitted
    Transaction.Sessions.Write

flattenPlan :: MigrationPlan -> [PlannedMigration]
flattenPlan plan =
  concatMap flattenComponent (toList (planComponentsOf plan))
  where
    flattenComponent component =
      zipWith
        ( \position migration ->
            PlannedMigration
              (MigrationId (componentNameOf component) (migrationNameOf migration))
              position
              migration
        )
        [1 ..]
        (toList (componentMigrationsOf component))

runSession ::
  Connection.Connection ->
  Session value ->
  IO (Either MigrationError value)
runSession connection session = do
  result <- Connection.use connection session
  pure (first DatabaseSessionFailed result)

invokeEvent :: RunOptions -> MigrationEvent -> IO (Either MigrationError ())
invokeEvent options = invokeEventWithMaybePrimary options Nothing

invokeEventWithPrimary ::
  RunOptions ->
  MigrationError ->
  MigrationEvent ->
  IO (Either MigrationError ())
invokeEventWithPrimary options primary =
  invokeEventWithMaybePrimary options (Just primary)

invokeEventWithMaybePrimary ::
  RunOptions ->
  Maybe MigrationError ->
  MigrationEvent ->
  IO (Either MigrationError ())
invokeEventWithMaybePrimary options primary event = do
  attempted <- try @SomeException (runEventHandler options event)
  case attempted of
    Left exception
      | isAsyncException exception -> throwIO exception
      | otherwise -> pure (Left (EventHandlerFailed primary exception))
    Right () -> pure (Right ())

validateOptions :: RunOptions -> Either MigrationError ()
validateOptions options = do
  case runLockWait options of
    WaitFor timeout | timeout < 0 -> Left (InvalidLockWait timeout)
    _ -> Right ()
  case runStatementTimeout options of
    Just timeout | timeout < 0 -> Left (InvalidStatementTimeout timeout)
    _ -> Right ()

elapsedSince :: Word64 -> IO NominalDiffTime
elapsedSince started = do
  finished <- getMonotonicTimeNSec
  pure (realToFrac (fromIntegral (finished - started) / (1000000000 :: Double)))

isAsyncException :: SomeException -> Bool
isAsyncException exception = isJust (fromException exception :: Maybe AsyncException)

libraryRunnerVersion :: Text
libraryRunnerVersion = Text.pack (showVersion Package.version)
