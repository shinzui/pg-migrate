module Main (main) where

import Control.Concurrent
  ( forkIO,
    killThread,
    newEmptyMVar,
    putMVar,
    readMVar,
    takeMVar,
    threadDelay,
    tryPutMVar,
  )
import Control.Exception (SomeException, bracket, finally, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Function ((&))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (NominalDiffTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Time.LocalTime (LocalTime)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate qualified as Migrate
import Database.PostgreSQL.Migrate.Internal
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Transaction
import System.Environment (lookupEnv)
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process (createProcess, getPid, proc, waitForProcess)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

main :: IO ()
main = do
  maybeConnectionString <- lookupEnv "PG_CONNECTION_STRING"
  case maybeConnectionString of
    Nothing ->
      putStrLn
        "pg-migrate integration tests skipped: PG_CONNECTION_STRING is not set"
    Just connectionString ->
      defaultMain (tests (Settings.connectionString (Text.pack connectionString)))

tests :: Settings.Settings -> TestTree
tests settings =
  testGroup
    "pg-migrate PostgreSQL ledger"
    [ testCase "installation is complete, constrained, and idempotent" (testInstallation settings),
      testCase "quoted custom schemas are safe" (testQuotedSchema settings),
      testCase "read-only loading leaves a missing ledger missing" (testMissingReadOnly settings),
      testCase "a future schema version is refused without mutation" (testFutureVersion settings),
      testCase "server version and statement timeout lifecycle are supported" (testConnectionLifecycle settings),
      testCase "lock no-wait and finite timeout preserve session settings" (testLockLifecycle settings),
      testCase "transactional plans apply once and then report applied" (testTransactionalRunner settings),
      testCase "transactional SQL failure rolls back action and ledger" (testTransactionalRollback settings),
      testCase "condemned Haskell transactions are detected" (testTransactionCondemn settings),
      testCase "nontransactional CREATE INDEX CONCURRENTLY applies" (testNonTransactionalSuccess settings),
      testCase "nontransactional observed failure records Failed" (testNonTransactionalFailure settings),
      testCase "repair mark-applied audits and unblocks the plan" (testRepairMarkApplied settings),
      testCase "repair retry audits and executes the current action once" (testRepairRetry settings),
      testCase "repair retry failure remains audited and Failed" (testRepairRetryFailure settings),
      testCase "repair rejects invalid targets" (testRepairValidation settings),
      testCase "terminated nontransactional helper leaves Running" (testCrashAmbiguity settings),
      testCase "nontransactional callback failure leaves Applied" (testNonTransactionalCallback settings),
      testCase "history import is atomic, audited, and idempotent" (testHistoryImport settings),
      testCase "history import conflicts with ordinary applied rows" (testHistoryExistingConflict settings),
      testCase "history audit failure rolls back target rows" (testHistoryAtomicity settings),
      testCase "equivalent history uses read-only state validation" (testHistoryEquivalentState settings),
      testCase "events follow durable migration boundaries" (testEventOrder settings),
      testCase "callback failure restores timeout and releases the lock" (testCallbackCleanup settings),
      testCase "two concurrent runners execute each effect once" (testConcurrentRunners settings),
      testCase "asynchronous interruption restores and unlocks before returning" (testAsyncCleanup settings)
    ]

testInstallation :: Settings.Settings -> IO ()
testInstallation settings =
  withTestLedger settings "install" $ \connection config -> do
    initialize connection config >>= (@?= Right ())
    initialize connection config >>= (@?= Right ())
    snapshot <- useSession connection (loadLedger config)
    case snapshot of
      LedgerSnapshot
        { metadata =
            Just
              LedgerMetadata
                { schemaVersion,
                  runnerVersion
                },
          storedMigrations = []
        } -> do
          schemaVersion @?= currentLedgerVersion
          runnerVersion @?= integrationRunnerVersion
      other -> assertFailure ("unexpected initialized snapshot: " <> show other)
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    tableNames
      @?= ["history_imports", "ledger_metadata", "migrations", "repairs"]
    mapM_ (assertConstraintRejects connection config) invalidMigrationRows
    migrationCount <- useSession connection (Session.statement () (migrationCountStatement config))
    migrationCount @?= 0

testQuotedSchema :: Settings.Settings -> IO ()
testQuotedSchema settings =
  withTestLedgerNamed settings (\suffix -> "application \"migrations\" " <> suffix) $ \connection config -> do
    initialize connection config >>= (@?= Right ())
    snapshot <- useSession connection (loadLedger config)
    case snapshot of
      LedgerSnapshot {metadata = Just LedgerMetadata {schemaVersion}} ->
        schemaVersion @?= currentLedgerVersion
      other -> assertFailure ("unexpected quoted-schema snapshot: " <> show other)

testMissingReadOnly :: Settings.Settings -> IO ()
testMissingReadOnly settings =
  withTestLedger settings "missing" $ \connection config -> do
    snapshot <- useSession connection (loadLedger config)
    snapshot @?= LedgerSnapshot {metadata = Nothing, storedMigrations = []}
    case statusFromSnapshot integrationPlan snapshot of
      StatusReport {issues, appliedMigrations, pendingMigrations, unknownMigrations} -> do
        issues @?= []
        appliedMigrations @?= []
        length pendingMigrations @?= 1
        unknownMigrations @?= []
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    tableNames @?= []

testFutureVersion :: Settings.Settings -> IO ()
testFutureVersion settings =
  withTestLedger settings "future" $ \connection config -> do
    initialize connection config >>= (@?= Right ())
    tableNamesBefore <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    useSession connection (Session.script (setFutureVersionSql config))
    initialize connection config
      >>= ( @?=
              Left
                LedgerTooNew
                  { databaseVersion = currentLedgerVersion + 1,
                    supportedVersion = currentLedgerVersion
                  }
          )
    tableNamesAfter <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    tableNamesAfter @?= tableNamesBefore
    snapshot <- useSession connection (loadLedger config)
    case snapshot of
      LedgerSnapshot {metadata = Just LedgerMetadata {schemaVersion}} ->
        schemaVersion @?= currentLedgerVersion + 1
      other -> assertFailure ("unexpected future-version snapshot: " <> show other)

testConnectionLifecycle :: Settings.Settings -> IO ()
testConnectionLifecycle settings =
  withConnection settings $ \connection -> do
    majorVersion <- checkServerVersion connection >>= requireMigrationRight
    assertBool ("unsupported accepted server major: " <> show majorVersion) (majorVersion `elem` [17, 18])
    before <- readStatementTimeout connection >>= requireMigrationRight
    saved <- applyStatementTimeout connection (Just 0.075) >>= requireMigrationRight
    saved @?= Just before
    during <- readStatementTimeout connection >>= requireMigrationRight
    during @?= "75ms"
    restoreStatementTimeout connection saved >>= requireCleanupRight
    after <- readStatementTimeout connection >>= requireMigrationRight
    after @?= before

testLockLifecycle :: Settings.Settings -> IO ()
testLockLifecycle settings = do
  lockKey <- uniqueLockKey
  withConnection settings $ \holder ->
    withConnection settings $ \contender -> do
      timeoutBefore <- readStatementTimeout contender >>= requireMigrationRight
      _ <- acquireAdvisoryLock holder lockKey WaitIndefinitely >>= requireMigrationRight
      acquireAdvisoryLock contender lockKey NoWait >>= assertLockUnavailable
      started <- getMonotonicTimeNSec
      acquireAdvisoryLock contender lockKey (WaitFor 0.12) >>= assertLockTimedOut
      finished <- getMonotonicTimeNSec
      let elapsed = fromIntegral (finished - started) / (1000000000 :: Double)
      assertBool ("finite lock wait returned too early: " <> show elapsed) (elapsed >= 0.10)
      assertBool ("finite lock wait returned too late: " <> show elapsed) (elapsed < 1.0)
      releaseAdvisoryLock holder lockKey >>= requireCleanupRight
      _ <- acquireAdvisoryLock contender lockKey NoWait >>= requireMigrationRight
      releaseAdvisoryLock contender lockKey >>= requireCleanupRight
      timeoutAfter <- readStatementTimeout contender >>= requireMigrationRight
      timeoutAfter @?= timeoutBefore

testTransactionalRunner :: Settings.Settings -> IO ()
testTransactionalRunner settings =
  withTestLedger settings "runner" $ \connection config -> do
    let plan =
          sqlPlan
            "runner"
            [ ("0001-create", "CREATE TABLE " <> quotedSchema config <> ".effects (value integer NOT NULL)"),
              ("0002-insert", "INSERT INTO " <> quotedSchema config <> ".effects (value) VALUES (1)")
            ]
        options = withLedger config defaultRunOptions
    firstReport <- runMigrationPlan options settings plan >>= requireRunRight
    reportOutcomes firstReport @?= [AppliedNow, AppliedNow]
    secondReport <- runMigrationPlan options settings plan >>= requireRunRight
    reportOutcomes secondReport @?= [AlreadyApplied, AlreadyApplied]
    effectCount <- useSession connection (Session.statement () (effectCountStatement config))
    effectCount @?= 1
    snapshot <- useSession connection (loadLedger config)
    length (storedMigrations snapshot) @?= 2

testTransactionalRollback :: Settings.Settings -> IO ()
testTransactionalRollback settings =
  withTestLedger settings "rollback" $ \connection config -> do
    let plan =
          sqlPlan
            "rollback"
            [ ( "0001-fail",
                Text.unlines
                  [ "CREATE TABLE",
                    quotedSchema config <> ".rolled_back (value integer);",
                    "SELECT 1 / 0"
                  ]
              )
            ]
    runMigrationPlan (withLedger config defaultRunOptions) settings plan
      >>= assertDatabaseSessionFailure
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    assertBool "failed transaction left its user table" ("rolled_back" `notElem` tableNames)
    snapshot <- useSession connection (loadLedger config)
    storedMigrations snapshot @?= []

testTransactionCondemn :: Settings.Settings -> IO ()
testTransactionCondemn settings =
  withTestLedger settings "condemn" $ \connection config -> do
    let action = do
          Transaction.sql
            (Text.Encoding.encodeUtf8 ("CREATE TABLE " <> quotedSchema config <> ".condemned (value integer)"))
          Transaction.condemn
        migration =
          requireRight
            (transactionMigration "0001-condemn" (migrationFingerprint "condemn-v1") action)
        plan = planFromMigrations "condemn" [migration]
    runMigrationPlan (withLedger config defaultRunOptions) settings plan
      >>= assertTransactionCondemned
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    assertBool "condemned transaction left its user table" ("condemned" `notElem` tableNames)
    snapshot <- useSession connection (loadLedger config)
    storedMigrations snapshot @?= []

testNonTransactionalSuccess :: Settings.Settings -> IO ()
testNonTransactionalSuccess settings =
  withTestLedger settings "nontransactional_success" $ \connection config -> do
    let plan =
          sqlPlan
            "nontransactional-success"
            [ ( "0001-table",
                Text.unlines
                  [ "CREATE TABLE",
                    quotedSchema config <> ".indexed_values (value integer NOT NULL);",
                    "INSERT INTO",
                    quotedSchema config <> ".indexed_values (value) VALUES (1)"
                  ]
              ),
              ( "0002-index",
                Text.unlines
                  [ "-- pg-migrate: no-transaction",
                    "CREATE INDEX CONCURRENTLY idx_nontransactional ON",
                    quotedSchema config <> ".indexed_values (value)"
                  ]
              )
            ]
    report <-
      runMigrationPlan (withLedger config defaultRunOptions) settings plan
        >>= requireRunRight
    reportOutcomes report @?= [AppliedNow, AppliedNow]
    indexExists <-
      useSession connection (Session.statement (ledgerSchema config) indexExistsStatement)
    indexExists @?= True
    snapshot <- useSession connection (loadLedger config)
    storedStatuses snapshot @?= [Applied, Applied]

testNonTransactionalFailure :: Settings.Settings -> IO ()
testNonTransactionalFailure settings =
  withTestLedger settings "nontransactional_failure" $ \connection config -> do
    let plan =
          sqlPlan
            "nontransactional-failure"
            [ ("0001-table", "CREATE TABLE " <> quotedSchema config <> ".existing_values (value integer NOT NULL)"),
              ( "0002-fail",
                Text.unlines
                  [ "-- pg-migrate: no-transaction",
                    "CREATE INDEX CONCURRENTLY idx_missing ON",
                    quotedSchema config <> ".missing_values (value)"
                  ]
              )
            ]
        options = withLedger config defaultRunOptions
    runMigrationPlan options settings plan >>= assertNonTransactionalFailure
    snapshot <- useSession connection (loadLedger config)
    storedStatuses snapshot @?= [Applied, Failed]
    case reverse (storedMigrations snapshot) of
      StoredMigration {errorMessage = Just diagnostic} : _ ->
        assertBool "Failed row did not preserve a diagnostic" (not (Text.null diagnostic))
      rows -> assertFailure ("unexpected failed rows: " <> show rows)
    runMigrationPlan options settings plan >>= assertPlanVerificationFailure

testRepairMarkApplied :: Settings.Settings -> IO ()
testRepairMarkApplied settings =
  withTestLedger settings "repair_mark" $ \connection config -> do
    let component = "repair-mark"
        plan = missingIndexPlan config component "idx_repair_mark" "mark_missing"
        options = withLedger config defaultRunOptions
        targetId = requireRight (Migrate.migrationId component "0001-index")
        request =
          requireRight
            (repairRequest targetId MarkApplied "index was verified out of band" Confirmed)
    runMigrationPlan options settings plan >>= assertNonTransactionalFailure
    repaired <-
      repairMigration options (connectionProviderFromSettings settings) plan request
        >>= requireRepairRight
    repaired
      @?= RepairReport
        { repairedMigration = targetId,
          operation = MarkApplied,
          oldStatus = Failed,
          newStatus = Applied
        }
    snapshot <- useSession connection (loadLedger config)
    storedStatuses snapshot @?= [Applied]
    repairCount <- useSession connection (Session.statement () (repairAuditCountStatement config))
    repairCount @?= 1
    repairAudit <- useSession connection (Session.statement () (repairAuditStatement config))
    repairAudit @?= ("mark-applied", "failed", "applied", "index was verified out of band")
    report <- runMigrationPlan options settings plan >>= requireRunRight
    reportOutcomes report @?= [AlreadyApplied]

testRepairRetry :: Settings.Settings -> IO ()
testRepairRetry settings =
  withTestLedger settings "repair_retry" $ \connection config -> do
    let component = "repair-retry"
        plan = missingIndexPlan config component "idx_repair_retry" "retry_values"
        options = withLedger config defaultRunOptions
        targetId = requireRight (Migrate.migrationId component "0001-index")
        request =
          requireRight
            (repairRequest targetId Retry "created the missing prerequisite table" Confirmed)
    runMigrationPlan options settings plan >>= assertNonTransactionalFailure
    useSession
      connection
      (Session.script ("CREATE TABLE " <> quotedSchema config <> ".retry_values (value integer NOT NULL)"))
    repaired <-
      repairMigration options (connectionProviderFromSettings settings) plan request
        >>= requireRepairRight
    repaired
      @?= RepairReport
        { repairedMigration = targetId,
          operation = Retry,
          oldStatus = Failed,
          newStatus = Applied
        }
    snapshot <- useSession connection (loadLedger config)
    storedStatuses snapshot @?= [Applied]
    repairCount <- useSession connection (Session.statement () (repairAuditCountStatement config))
    repairCount @?= 1
    repairAudit <- useSession connection (Session.statement () (repairAuditStatement config))
    repairAudit @?= ("retry", "failed", "running", "created the missing prerequisite table")
    indexExists <- useSession connection (Session.statement (ledgerSchema config) retryIndexExistsStatement)
    indexExists @?= True

testRepairRetryFailure :: Settings.Settings -> IO ()
testRepairRetryFailure settings =
  withTestLedger settings "repair_retry_failure" $ \connection config -> do
    let component = "repair-retry-failure"
        plan = missingIndexPlan config component "idx_retry_failure" "still_missing"
        options = withLedger config defaultRunOptions
        targetId = requireRight (Migrate.migrationId component "0001-index")
        request = requireRight (repairRequest targetId Retry "retry once for audit" Confirmed)
    runMigrationPlan options settings plan >>= assertNonTransactionalFailure
    repairMigration options (connectionProviderFromSettings settings) plan request
      >>= assertRepairRunFailure
    snapshot <- useSession connection (loadLedger config)
    storedStatuses snapshot @?= [Failed]
    repairCount <- useSession connection (Session.statement () (repairAuditCountStatement config))
    repairCount @?= 1
    repairAudit <- useSession connection (Session.statement () (repairAuditStatement config))
    repairAudit @?= ("retry", "failed", "running", "retry once for audit")

testRepairValidation :: Settings.Settings -> IO ()
testRepairValidation settings = do
  withTestLedger settings "repair_transactional" $ \_ config -> do
    let transactionalPlan =
          sqlPlan
            "repair-transactional"
            [("0001-table", "CREATE TABLE " <> quotedSchema config <> ".transactional_target (value integer)")]
        options = withLedger config defaultRunOptions
        transactionalId = requireRight (Migrate.migrationId "repair-transactional" "0001-table")
        transactionalRequest =
          requireRight (repairRequest transactionalId MarkApplied "must reject" Confirmed)
    _ <- runMigrationPlan options settings transactionalPlan >>= requireRunRight
    repairMigration options (connectionProviderFromSettings settings) transactionalPlan transactionalRequest
      >>= assertRepairTransactional
  withTestLedger settings "repair_checksum" $ \_ config -> do
    let component = "repair-checksum"
        originalPlan = missingIndexPlan config component "idx_original" "checksum_missing"
        changedPlan = missingIndexPlan config component "idx_changed" "checksum_missing"
        options = withLedger config defaultRunOptions
        targetId = requireRight (Migrate.migrationId component "0001-index")
        request = requireRight (repairRequest targetId Retry "must reject changed SQL" Confirmed)
    runMigrationPlan options settings originalPlan >>= assertNonTransactionalFailure
    repairMigration options (connectionProviderFromSettings settings) changedPlan request
      >>= assertRepairMetadataMismatch
  withTestLedger settings "repair_missing" $ \_ config -> do
    let component = "repair-missing"
        plan = missingIndexPlan config component "idx_missing_target" "missing_target"
        options = withLedger config defaultRunOptions
        unknownId = requireRight (Migrate.migrationId component "9999-unknown")
        request = requireRight (repairRequest unknownId MarkApplied "must reject unknown target" Confirmed)
    repairMigration options (connectionProviderFromSettings settings) plan request
      >>= assertRepairMissing
  withTestLedger settings "repair_applied" $ \connection config -> do
    initialize connection config >>= (@?= Right ())
    useSession connection (Session.script ("CREATE TABLE " <> quotedSchema config <> ".applied_values (value integer NOT NULL)"))
    let component = "repair-applied"
        plan = missingIndexPlan config component "idx_applied_target" "applied_values"
        options = withLedger config defaultRunOptions
        targetId = requireRight (Migrate.migrationId component "0001-index")
        request = requireRight (repairRequest targetId MarkApplied "must reject applied target" Confirmed)
    _ <- runMigrationPlan options settings plan >>= requireRunRight
    repairMigration options (connectionProviderFromSettings settings) plan request
      >>= assertRepairAlreadyApplied

testCrashAmbiguity :: Settings.Settings -> IO ()
testCrashAmbiguity settings =
  withTestLedger settings "crash" $ \connection config ->
    withConnection settings $ \contender -> do
      (_, _, _, processHandle) <-
        createProcess
          ( proc
              "pg-migrate-crash-helper"
              [ Text.unpack (ledgerSchema config),
                show (lockKey config)
              ]
          )
      waitForRunning connection config 200
      processId <- getPid processHandle >>= maybe (fail "crash helper has no process id") pure
      signalProcess sigKILL processId
      _ <- waitForProcess processHandle
      snapshot <- useSession connection (loadLedger config)
      storedStatuses snapshot @?= [Running]
      runMigrationPlan
        (withLedger config defaultRunOptions)
        settings
        (crashMigrationPlan config)
        >>= assertPlanVerificationFailure
      _ <- acquireAdvisoryLock contender (lockKey config) NoWait >>= requireMigrationRight
      releaseAdvisoryLock contender (lockKey config) >>= requireCleanupRight

testNonTransactionalCallback :: Settings.Settings -> IO ()
testNonTransactionalCallback settings =
  withTestLedger settings "nontransactional_callback" $ \connection config ->
    withConnection settings $ \contender -> do
      initialize connection config >>= (@?= Right ())
      useSession connection (Session.script ("CREATE TABLE " <> quotedSchema config <> ".callback_values (value integer NOT NULL)"))
      let component = "nontransactional-callback"
          plan = missingIndexPlan config component "idx_nontransactional_callback" "callback_values"
          handler = \case
            MigrationCompleted {} -> throwIO (userError "nontransactional callback failure")
            _ -> pure ()
          options = defaultRunOptions & withLedger config & withEventHandler handler
      runMigrationPlan options settings plan >>= assertEventHandlerFailure
      snapshot <- useSession connection (loadLedger config)
      storedStatuses snapshot @?= [Applied]
      _ <- acquireAdvisoryLock contender (lockKey config) NoWait >>= requireMigrationRight
      releaseAdvisoryLock contender (lockKey config) >>= requireCleanupRight

testHistoryImport :: Settings.Settings -> IO ()
testHistoryImport settings =
  withTestLedger settings "history_import" $ \connection config -> do
    let plan = historySqlPlan config
        imported = historySqlImport config False
        options = historyOptions config
        provider = connectionProviderFromSettings settings
        expectedIds = historyTarget <$> [1, 2]
    firstReport <- importMigrationHistory options provider plan imported >>= requireHistoryRight
    historyOutcomes firstReport @?= zip expectedIds (repeat Imported)
    snapshot <- useSession connection (loadLedger config)
    storedStatuses snapshot @?= [Applied, Applied]
    [storedPosition | StoredMigration {position = storedPosition} <- storedMigrations snapshot] @?= [1, 2]
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    assertBool "history import executed a target action" (all (`notElem` tableNames) ["import_action_1", "import_action_2"])
    auditEvidence <- useSession connection (Session.statement () (historyAuditEvidenceStatement config))
    auditEvidence @?= (2, True, True)
    secondReport <- importMigrationHistory options provider plan imported >>= requireHistoryRight
    historyOutcomes secondReport @?= zip expectedIds (repeat AlreadyImported)
    migrationCount <- useSession connection (Session.statement () (migrationCountStatement config))
    migrationCount @?= 2
    importMigrationHistory options provider plan (historySqlImport config True)
      >>= assertHistoryConflict (historyTarget 1)

testHistoryExistingConflict :: Settings.Settings -> IO ()
testHistoryExistingConflict settings =
  withTestLedger settings "history_existing" $ \connection config -> do
    let firstSql = "CREATE TABLE " <> quotedSchema config <> ".import_action_1 (value integer)"
        existingPlan = sqlPlan "history-import" [("0001-one", firstSql)]
        fullPlan = historySqlPlan config
        runOptions = withLedger config defaultRunOptions
    _ <- runMigrationPlan runOptions settings existingPlan >>= requireRunRight
    importMigrationHistory
      (historyOptions config)
      (connectionProviderFromSettings settings)
      fullPlan
      (historySqlImport config False)
      >>= assertHistoryConflict (historyTarget 1)
    snapshot <- useSession connection (loadLedger config)
    length (storedMigrations snapshot) @?= 1
    auditCount <- useSession connection (Session.statement () (historyAuditCountStatement config))
    auditCount @?= 0

testHistoryAtomicity :: Settings.Settings -> IO ()
testHistoryAtomicity settings =
  withTestLedger settings "history_atomicity" $ \connection config -> do
    initialize connection config >>= (@?= Right ())
    useSession
      connection
      ( Session.script
          ( "ALTER TABLE "
              <> quotedSchema config
              <> ".history_imports ADD CONSTRAINT reject_second_history CHECK (migration <> '0002-two')"
          )
      )
    importMigrationHistory
      (historyOptions config)
      (connectionProviderFromSettings settings)
      (historySqlPlan config)
      (historySqlImport config False)
      >>= assertHistoryDatabaseFailure
    snapshot <- useSession connection (loadLedger config)
    storedMigrations snapshot @?= []
    auditCount <- useSession connection (Session.statement () (historyAuditCountStatement config))
    auditCount @?= 0

testHistoryEquivalentState :: Settings.Settings -> IO ()
testHistoryEquivalentState settings = do
  withTestLedger settings "history_equivalent" $ \connection config -> do
    initialize connection config >>= (@?= Right ())
    useSession connection (Session.script ("CREATE TABLE " <> quotedSchema config <> ".legacy_state (value integer)"))
    let (plan, imported) = equivalentHistoryPlan config successfulStateValidator
        baseOptions = historyOptions config
        allowedOptions = withEquivalentHistory AllowEquivalentHistory baseOptions
        provider = connectionProviderFromSettings settings
        successfulStateValidator =
          stateValidator historyStateKey $ do
            exists <- Transaction.statement (ledgerSchema config <> ".legacy_state") stateTableExistsStatement
            pure
              ( if exists
                  then Right (Aeson.object ["legacy_table" Aeson..= ("present" :: Text)])
                  else Left (requireRight (stateValidationError "legacy state is missing"))
              )
    importMigrationHistory baseOptions provider plan imported
      >>= assertEquivalentDisallowed (historyHaskellTarget)
    report <- importMigrationHistory allowedOptions provider plan imported >>= requireHistoryRight
    historyOutcomes report @?= [(historyHaskellTarget, Imported)]
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    assertBool "equivalent import executed the Haskell target" ("haskell_action" `notElem` tableNames)
  withTestLedger settings "history_validator_failure" $ \_ config -> do
    let failedValidator =
          stateValidator historyStateKey (pure (Left (requireRight (stateValidationError "domain state mismatch"))))
        (plan, imported) = equivalentHistoryPlan config failedValidator
    importMigrationHistory
      (withEquivalentHistory AllowEquivalentHistory (historyOptions config))
      (connectionProviderFromSettings settings)
      plan
      imported
      >>= assertStateValidationFailure historyStateKey
  withTestLedger settings "history_validator_read_only" $ \connection config -> do
    let writeValidator =
          stateValidator historyStateKey $ do
            Transaction.sql (Text.Encoding.encodeUtf8 ("CREATE TABLE " <> quotedSchema config <> ".validator_write (value integer)"))
            pure (Right Aeson.Null)
        (plan, imported) = equivalentHistoryPlan config writeValidator
    importMigrationHistory
      (withEquivalentHistory AllowEquivalentHistory (historyOptions config))
      (connectionProviderFromSettings settings)
      plan
      imported
      >>= assertHistoryDatabaseFailure
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    assertBool "read-only validator wrote state" ("validator_write" `notElem` tableNames)

testEventOrder :: Settings.Settings -> IO ()
testEventOrder settings =
  withTestLedger settings "events" $ \_ config -> do
    eventsRef <- newIORef []
    let plan =
          sqlPlan
            "events"
            [ ("0001-create", "CREATE TABLE " <> quotedSchema config <> ".event_effects (value integer NOT NULL)"),
              ("0002-insert", "INSERT INTO " <> quotedSchema config <> ".event_effects (value) VALUES (1)")
            ]
        handler event = atomicModifyIORef' eventsRef (\events -> (events <> [event], ()))
        options = defaultRunOptions & withLedger config & withEventHandler handler
    report <- runMigrationPlan options settings plan >>= requireRunRight
    reportOutcomes report @?= [AppliedNow, AppliedNow]
    events <- readIORef eventsRef
    assertSuccessfulEventOrder events

testCallbackCleanup :: Settings.Settings -> IO ()
testCallbackCleanup settings =
  withTestLedger settings "callback" $ \connection config ->
    withConnection settings $ \contender -> do
      timeoutBefore <- readStatementTimeout connection >>= requireMigrationRight
      let plan =
            sqlPlan
              "callback"
              [ ("0001-create", "CREATE TABLE " <> quotedSchema config <> ".callback_first (value integer)"),
                ("0002-never", "CREATE TABLE " <> quotedSchema config <> ".callback_second (value integer)")
              ]
          handler = \case
            MigrationCompleted {} -> throwIO (userError "callback failure")
            _ -> pure ()
          options =
            defaultRunOptions
              & withLedger config
              & withStatementTimeout (Just 0.5)
              & withEventHandler handler
          provider = connectionProvider (\action -> Right <$> action connection)
      runMigrationPlanWith options provider plan >>= assertEventHandlerFailure
      timeoutAfter <- readStatementTimeout connection >>= requireMigrationRight
      timeoutAfter @?= timeoutBefore
      _ <- acquireAdvisoryLock contender (lockKey config) NoWait >>= requireMigrationRight
      releaseAdvisoryLock contender (lockKey config) >>= requireCleanupRight
      snapshot <- useSession connection (loadLedger config)
      length (storedMigrations snapshot) @?= 1
      tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
      assertBool "first migration was not durable before callback" ("callback_first" `elem` tableNames)
      assertBool "runner continued after callback failure" ("callback_second" `notElem` tableNames)

testConcurrentRunners :: Settings.Settings -> IO ()
testConcurrentRunners settings =
  withTestLedger settings "concurrent" $ \connection config -> do
    let plan =
          sqlPlan
            "concurrent"
            [ ("0001-create", "CREATE TABLE " <> quotedSchema config <> ".concurrent_effects (value integer NOT NULL)"),
              ("0002-insert", "INSERT INTO " <> quotedSchema config <> ".concurrent_effects (value) VALUES (1)")
            ]
        options = defaultRunOptions & withLedger config
        run = runMigrationPlan options settings plan
    gate <- newEmptyMVar
    firstDone <- newEmptyMVar
    secondDone <- newEmptyMVar
    _ <- forkIO (readMVar gate >> try @SomeException run >>= putMVar firstDone)
    _ <- forkIO (readMVar gate >> try @SomeException run >>= putMVar secondDone)
    putMVar gate ()
    firstReport <- takeMVar firstDone >>= requireThreadRun
    secondReport <- takeMVar secondDone >>= requireThreadRun
    List.sort [reportOutcomes firstReport, reportOutcomes secondReport]
      @?= List.sort [[AppliedNow, AppliedNow], [AlreadyApplied, AlreadyApplied]]
    effectCount <- useSession connection (Session.statement () (concurrentEffectCountStatement config))
    effectCount @?= 1
    snapshot <- useSession connection (loadLedger config)
    length (storedMigrations snapshot) @?= 2

testAsyncCleanup :: Settings.Settings -> IO ()
testAsyncCleanup settings =
  withTestLedger settings "async" $ \connection config ->
    withConnection settings $ \contender -> do
      timeoutBefore <- readStatementTimeout connection >>= requireMigrationRight
      started <- newEmptyMVar
      done <- newEmptyMVar
      let action = Transaction.sql "SELECT pg_sleep(5)"
          migration =
            requireRight
              (transactionMigration "0001-sleep" (migrationFingerprint "sleep-v1") action)
          plan = planFromMigrations "async" [migration]
          handler = \case
            MigrationStarted {} -> do
              _ <- tryPutMVar started ()
              pure ()
            _ -> pure ()
          options =
            defaultRunOptions
              & withLedger config
              & withStatementTimeout (Just 2)
              & withEventHandler handler
          provider = connectionProvider (\use -> Right <$> use connection)
      runnerThread <-
        forkIO
          (try @SomeException (runMigrationPlanWith options provider plan) >>= putMVar done)
      takeMVar started
      threadDelay 50000
      killThread runnerThread
      interrupted <- takeMVar done
      case interrupted of
        Left _ -> pure ()
        Right result -> assertFailure ("expected asynchronous exception, received " <> show result)
      timeoutAfter <- readStatementTimeout connection >>= requireMigrationRight
      timeoutAfter @?= timeoutBefore
      _ <- acquireAdvisoryLock contender (lockKey config) NoWait >>= requireMigrationRight
      releaseAdvisoryLock contender (lockKey config) >>= requireCleanupRight
      snapshot <- useSession connection (loadLedger config)
      storedMigrations snapshot @?= []

withTestLedger ::
  Settings.Settings ->
  Text ->
  (Connection.Connection -> LedgerConfig -> IO a) ->
  IO a
withTestLedger settings label action =
  withTestLedgerNamed settings (\suffix -> "pgmigrate_test_" <> label <> "_" <> suffix) action

withTestLedgerNamed ::
  Settings.Settings ->
  (Text -> Text) ->
  (Connection.Connection -> LedgerConfig -> IO a) ->
  IO a
withTestLedgerNamed settings makeSchema action = do
  suffix <- uniqueSuffix
  let suffixNumber = read (Text.unpack suffix) :: Integer
      lockKey = testLockKey + fromIntegral (suffixNumber `mod` 1000000)
      config = requireRight (ledgerConfig (makeSchema suffix) lockKey)
  withConnection settings $ \connection -> do
    cleanupLedger connection config
    action connection config `finally` cleanupLedger connection config

withConnection :: Settings.Settings -> (Connection.Connection -> IO a) -> IO a
withConnection settings action = do
  acquired <- Connection.acquire settings
  case acquired of
    Left connectionError ->
      assertFailure ("failed to acquire PostgreSQL integration connection: " <> show connectionError)
        >> error "assertFailure returned"
    Right connection -> bracket (pure connection) Connection.release action

initialize :: Connection.Connection -> LedgerConfig -> IO (Either LedgerError ())
initialize connection config =
  useSession connection (initializeOrUpgradeLedger config integrationRunnerVersion)

useSession :: Connection.Connection -> Session a -> IO a
useSession connection session = do
  result <- Connection.use connection session
  case result of
    Left sessionError ->
      assertFailure ("PostgreSQL session failed: " <> show sessionError)
        >> error "assertFailure returned"
    Right value -> pure value

assertConstraintRejects :: Connection.Connection -> LedgerConfig -> Text -> IO ()
assertConstraintRejects connection config values = do
  result <- Connection.use connection (Session.script (invalidInsertSql config values))
  assertBool ("expected constraint failure for values: " <> Text.unpack values) (isLeft result)

cleanupLedger :: Connection.Connection -> LedgerConfig -> IO ()
cleanupLedger connection config =
  useSession
    connection
    (Session.script ("DROP SCHEMA IF EXISTS " <> quotedSchema config <> " CASCADE"))

invalidInsertSql :: LedgerConfig -> Text -> Text
invalidInsertSql config values =
  Text.unwords
    [ "INSERT INTO",
      qualifiedMigrationsTable config,
      "(component, migration, position, checksum, kind, transaction_mode, status,",
      "started_at, finished_at, execution_time_ms, error, runner_version)",
      "VALUES",
      values
    ]

invalidMigrationRows :: [Text]
invalidMigrationRows =
  [ "('owner', 'bad-position', 0, decode(repeat('00', 32), 'hex'), 'sql', 'transactional', 'applied', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'bad-checksum', 1, decode('00', 'hex'), 'sql', 'transactional', 'applied', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'bad-kind', 1, decode(repeat('00', 32), 'hex'), 'other', 'transactional', 'applied', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'bad-mode', 1, decode(repeat('00', 32), 'hex'), 'sql', 'other', 'applied', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'bad-status', 1, decode(repeat('00', 32), 'hex'), 'sql', 'transactional', 'other', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'transactional-running', 1, decode(repeat('00', 32), 'hex'), 'sql', 'transactional', 'running', clock_timestamp(), NULL, NULL, NULL, 'test')",
    "('owner', 'bad-status-shape', 1, decode(repeat('00', 32), 'hex'), 'sql', 'transactional', 'applied', clock_timestamp(), NULL, 0, NULL, 'test')"
  ]

tableNamesStatement :: Statement.Statement Text [Text]
tableNamesStatement =
  Statement.preparable
    """
    SELECT table_name::text
    FROM information_schema.tables
    WHERE table_schema = $1
    ORDER BY table_name
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

migrationCountStatement :: LedgerConfig -> Statement.Statement () Int64
migrationCountStatement config =
  Statement.unpreparable
    ("SELECT count(*) FROM " <> qualifiedMigrationsTable config)
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

effectCountStatement :: LedgerConfig -> Statement.Statement () Int64
effectCountStatement config =
  Statement.unpreparable
    ("SELECT count(*) FROM " <> quotedSchema config <> ".effects")
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

concurrentEffectCountStatement :: LedgerConfig -> Statement.Statement () Int64
concurrentEffectCountStatement config =
  Statement.unpreparable
    ("SELECT count(*) FROM " <> quotedSchema config <> ".concurrent_effects")
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

repairAuditCountStatement :: LedgerConfig -> Statement.Statement () Int64
repairAuditCountStatement config =
  Statement.unpreparable
    ("SELECT count(*) FROM " <> quotedSchema config <> ".repairs")
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

repairAuditStatement :: LedgerConfig -> Statement.Statement () (Text, Text, Text, Text)
repairAuditStatement config =
  Statement.unpreparable
    ("SELECT operation, old_status, new_status, reason FROM " <> quotedSchema config <> ".repairs")
    Encoders.noParams
    ( Decoders.singleRow
        ( (,,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
        )
    )

historyAuditCountStatement :: LedgerConfig -> Statement.Statement () Int64
historyAuditCountStatement config =
  Statement.unpreparable
    ("SELECT count(*) FROM " <> quotedSchema config <> ".history_imports")
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

historyAuditEvidenceStatement :: LedgerConfig -> Statement.Statement () (Int64, Bool, Bool)
historyAuditEvidenceStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "SELECT count(*),",
          "bool_and(h.source_evidence #>> '{satisfying_evidence,0,applied_at,kind}' = 'local-without-zone'),",
          "bool_and(m.started_at = m.finished_at AND m.started_at = h.imported_at)",
          "FROM",
          quotedSchema config <> ".history_imports h",
          "JOIN",
          quotedSchema config <> ".migrations m USING (component, migration)"
        ]
    )
    Encoders.noParams
    ( Decoders.singleRow
        ( (,,)
            <$> Decoders.column (Decoders.nonNullable Decoders.int8)
            <*> Decoders.column (Decoders.nonNullable Decoders.bool)
            <*> Decoders.column (Decoders.nonNullable Decoders.bool)
        )
    )

stateTableExistsStatement :: Statement.Statement Text Bool
stateTableExistsStatement =
  Statement.preparable
    "SELECT to_regclass($1) IS NOT NULL"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

indexExistsStatement :: Statement.Statement Text Bool
indexExistsStatement =
  Statement.preparable
    """
    SELECT EXISTS
    (
      SELECT 1
      FROM pg_indexes
      WHERE schemaname = $1
        AND indexname = 'idx_nontransactional'
    )
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

retryIndexExistsStatement :: Statement.Statement Text Bool
retryIndexExistsStatement =
  Statement.preparable
    """
    SELECT EXISTS
    (
      SELECT 1
      FROM pg_indexes
      WHERE schemaname = $1
        AND indexname = 'idx_repair_retry'
    )
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

setFutureVersionSql :: LedgerConfig -> Text
setFutureVersionSql config =
  "UPDATE "
    <> quotedSchema config
    <> ".\"ledger_metadata\" SET schema_version = "
    <> Text.pack (show (currentLedgerVersion + 1))

qualifiedMigrationsTable :: LedgerConfig -> Text
qualifiedMigrationsTable config = quotedSchema config <> ".\"migrations\""

quotedSchema :: LedgerConfig -> Text
quotedSchema config = quotePostgresIdentifier (PostgresIdentifier (ledgerSchemaText config))

ledgerSchema :: LedgerConfig -> Text
ledgerSchema = ledgerSchemaText

integrationPlan :: MigrationPlan
integrationPlan =
  requireRight
    ( migrationPlan
        ( requireRight
            ( migrationComponent
                "integration"
                Set.empty
                (requireRight (sqlMigration "0001" "SELECT 1") :| [])
            )
            :| []
        )
    )

uniqueSuffix :: IO Text
uniqueSuffix = do
  now <- getPOSIXTime
  pure (Text.pack (show (floor (realToFrac now * (1000000 :: Double)) :: Integer)))

requireRight :: (Show error) => Either error value -> value
requireRight = \case
  Left err -> error (show err)
  Right value -> value

isLeft :: Either left right -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

requireMigrationRight :: Either MigrationError value -> IO value
requireMigrationRight = \case
  Left migrationError -> assertFailure (show migrationError) >> error "assertFailure returned"
  Right value -> pure value

requireCleanupRight :: Either CleanupIssue () -> IO ()
requireCleanupRight = \case
  Left cleanupIssue -> assertFailure (show cleanupIssue)
  Right () -> pure ()

requireRunRight :: Either MigrationError MigrationReport -> IO MigrationReport
requireRunRight = \case
  Left migrationError -> assertFailure (show migrationError) >> error "assertFailure returned"
  Right report -> pure report

requireRepairRight :: Either RepairError RepairReport -> IO RepairReport
requireRepairRight = \case
  Left repairError -> assertFailure (show repairError) >> error "assertFailure returned"
  Right report -> pure report

requireHistoryRight :: Either HistoryImportError HistoryImportReport -> IO HistoryImportReport
requireHistoryRight = \case
  Left importError -> assertFailure (show importError) >> error "assertFailure returned"
  Right report -> pure report

requireThreadRun ::
  Either SomeException (Either MigrationError MigrationReport) ->
  IO MigrationReport
requireThreadRun = \case
  Left exception -> assertFailure (show exception) >> error "assertFailure returned"
  Right result -> requireRunRight result

assertDatabaseSessionFailure :: Either MigrationError MigrationReport -> IO ()
assertDatabaseSessionFailure = \case
  Left DatabaseSessionFailed {} -> pure ()
  Left migrationError -> assertFailure ("expected DatabaseSessionFailed, received " <> show migrationError)
  Right report -> assertFailure ("expected DatabaseSessionFailed, received " <> show report)

assertTransactionCondemned :: Either MigrationError MigrationReport -> IO ()
assertTransactionCondemned = \case
  Left TransactionCondemned {} -> pure ()
  Left migrationError -> assertFailure ("expected TransactionCondemned, received " <> show migrationError)
  Right report -> assertFailure ("expected TransactionCondemned, received " <> show report)

assertNonTransactionalFailure :: Either MigrationError MigrationReport -> IO ()
assertNonTransactionalFailure = \case
  Left NonTransactionalMigrationFailed {} -> pure ()
  Left migrationError -> assertFailure ("expected NonTransactionalMigrationFailed, received " <> show migrationError)
  Right report -> assertFailure ("expected NonTransactionalMigrationFailed, received " <> show report)

assertPlanVerificationFailure :: Either MigrationError MigrationReport -> IO ()
assertPlanVerificationFailure = \case
  Left PlanVerificationFailed {} -> pure ()
  Left migrationError -> assertFailure ("expected PlanVerificationFailed, received " <> show migrationError)
  Right report -> assertFailure ("expected PlanVerificationFailed, received " <> show report)

assertRepairTransactional :: Either RepairError RepairReport -> IO ()
assertRepairTransactional = \case
  Left RepairTargetTransactional {} -> pure ()
  Left repairError -> assertFailure ("expected RepairTargetTransactional, received " <> show repairError)
  Right report -> assertFailure ("expected RepairTargetTransactional, received " <> show report)

assertRepairMetadataMismatch :: Either RepairError RepairReport -> IO ()
assertRepairMetadataMismatch = \case
  Left RepairTargetMetadataMismatch {} -> pure ()
  Left repairError -> assertFailure ("expected RepairTargetMetadataMismatch, received " <> show repairError)
  Right report -> assertFailure ("expected RepairTargetMetadataMismatch, received " <> show report)

assertRepairMissing :: Either RepairError RepairReport -> IO ()
assertRepairMissing = \case
  Left RepairTargetMissing {} -> pure ()
  Left repairError -> assertFailure ("expected RepairTargetMissing, received " <> show repairError)
  Right report -> assertFailure ("expected RepairTargetMissing, received " <> show report)

assertRepairAlreadyApplied :: Either RepairError RepairReport -> IO ()
assertRepairAlreadyApplied = \case
  Left RepairTargetAlreadyApplied {} -> pure ()
  Left repairError -> assertFailure ("expected RepairTargetAlreadyApplied, received " <> show repairError)
  Right report -> assertFailure ("expected RepairTargetAlreadyApplied, received " <> show report)

assertRepairRunFailure :: Either RepairError RepairReport -> IO ()
assertRepairRunFailure = \case
  Left (RepairRunnerError NonTransactionalMigrationFailed {}) -> pure ()
  Left repairError -> assertFailure ("expected repaired action failure, received " <> show repairError)
  Right report -> assertFailure ("expected repaired action failure, received " <> show report)

assertHistoryConflict :: MigrationId -> Either HistoryImportError HistoryImportReport -> IO ()
assertHistoryConflict expected = \case
  Left (HistoryImportConflict actual) -> actual @?= expected
  Left importError -> assertFailure ("expected HistoryImportConflict, received " <> show importError)
  Right report -> assertFailure ("expected HistoryImportConflict, received " <> show report)

assertHistoryDatabaseFailure :: Either HistoryImportError HistoryImportReport -> IO ()
assertHistoryDatabaseFailure = \case
  Left (HistoryImportRunnerError DatabaseSessionFailed {}) -> pure ()
  Left importError -> assertFailure ("expected history database failure, received " <> show importError)
  Right report -> assertFailure ("expected history database failure, received " <> show report)

assertEquivalentDisallowed :: MigrationId -> Either HistoryImportError HistoryImportReport -> IO ()
assertEquivalentDisallowed expected = \case
  Left (HistoryImportValidationFailed (HistoryEquivalentStateDisallowed actual)) -> actual @?= expected
  Left importError -> assertFailure ("expected HistoryEquivalentStateDisallowed, received " <> show importError)
  Right report -> assertFailure ("expected HistoryEquivalentStateDisallowed, received " <> show report)

assertStateValidationFailure :: EvidenceKey -> Either HistoryImportError HistoryImportReport -> IO ()
assertStateValidationFailure expected = \case
  Left (HistoryStateValidationFailed actual _) -> actual @?= expected
  Left importError -> assertFailure ("expected HistoryStateValidationFailed, received " <> show importError)
  Right report -> assertFailure ("expected HistoryStateValidationFailed, received " <> show report)

assertEventHandlerFailure :: Either MigrationError MigrationReport -> IO ()
assertEventHandlerFailure = \case
  Left (EventHandlerFailed Nothing _) -> pure ()
  Left migrationError -> assertFailure ("expected EventHandlerFailed, received " <> show migrationError)
  Right report -> assertFailure ("expected EventHandlerFailed, received " <> show report)

assertLockUnavailable :: Either MigrationError value -> IO ()
assertLockUnavailable = \case
  Left AdvisoryLockUnavailable -> pure ()
  Left migrationError -> assertFailure ("expected AdvisoryLockUnavailable, received " <> show migrationError)
  Right _ -> assertFailure "expected AdvisoryLockUnavailable, received Right"

assertLockTimedOut :: Either MigrationError value -> IO ()
assertLockTimedOut = \case
  Left (AdvisoryLockTimedOut timeout) -> timeout @?= 0.12
  Left migrationError -> assertFailure ("expected AdvisoryLockTimedOut, received " <> show migrationError)
  Right _ -> assertFailure "expected AdvisoryLockTimedOut, received Right"

assertSuccessfulEventOrder :: [MigrationEvent] -> IO ()
assertSuccessfulEventOrder = \case
  [ LockWaitStarted WaitIndefinitely,
    LockAcquired lockDuration,
    PlanValidated 0 2,
    MigrationStarted firstId,
    MigrationCompleted firstCompleted firstDuration,
    MigrationStarted secondId,
    MigrationCompleted secondCompleted secondDuration,
    MigrationPlanCompleted planDuration
    ] -> do
      let expectedFirst = requireRight (Migrate.migrationId "events" "0001-create")
          expectedSecond = requireRight (Migrate.migrationId "events" "0002-insert")
      firstId @?= expectedFirst
      firstCompleted @?= expectedFirst
      secondId @?= expectedSecond
      secondCompleted @?= expectedSecond
      assertNonnegative "lock duration" lockDuration
      assertNonnegative "first migration duration" firstDuration
      assertNonnegative "second migration duration" secondDuration
      assertNonnegative "plan duration" planDuration
  events -> assertFailure ("unexpected event order: " <> show events)

assertNonnegative :: String -> NominalDiffTime -> IO ()
assertNonnegative label duration =
  assertBool (label <> " was negative: " <> show duration) (duration >= 0)

uniqueLockKey :: IO Int64
uniqueLockKey = do
  now <- getPOSIXTime
  let microseconds = floor (realToFrac now * (1000000 :: Double)) :: Integer
  pure (testLockKey + fromIntegral (microseconds `mod` 1000000))

reportOutcomes :: MigrationReport -> [MigrationOutcome]
reportOutcomes MigrationReport {results} =
  (\MigrationResult {outcome} -> outcome) <$> toList results

historyOutcomes :: HistoryImportReport -> [(MigrationId, HistoryImportOutcome)]
historyOutcomes HistoryImportReport {importResults} =
  [(importedMigration, importOutcome) | HistoryImportResult {importedMigration, importOutcome} <- toList importResults]

storedStatuses :: LedgerSnapshot -> [MigrationStatus]
storedStatuses LedgerSnapshot {storedMigrations} =
  (\StoredMigration {status} -> status) <$> storedMigrations

sqlPlan :: Text -> [(Text, Text)] -> MigrationPlan
sqlPlan component entries =
  planFromMigrations
    component
    [ requireRight (sqlMigration name (Text.Encoding.encodeUtf8 sql))
    | (name, sql) <- entries
    ]

planFromMigrations :: Text -> [Migration] -> MigrationPlan
planFromMigrations component migrations =
  case NonEmpty.nonEmpty migrations of
    Nothing -> error "planFromMigrations requires at least one migration"
    Just nonEmptyMigrations ->
      requireRight
        ( migrationPlan
            ( requireRight
                (migrationComponent component Set.empty nonEmptyMigrations)
                :| []
            )
        )

historyOptions :: LedgerConfig -> ImportOptions
historyOptions config =
  withImportRunOptions (withLedger config defaultRunOptions) defaultImportOptions

historySqlPlan :: LedgerConfig -> MigrationPlan
historySqlPlan config =
  sqlPlan
    "history-import"
    [ ("0001-one", "CREATE TABLE " <> quotedSchema config <> ".import_action_1 (value integer)"),
      ("0002-two", "CREATE TABLE " <> quotedSchema config <> ".import_action_2 (value integer)"),
      ("0003-three", "CREATE TABLE " <> quotedSchema config <> ".import_action_3 (value integer)")
    ]

historySqlImport :: LedgerConfig -> Bool -> HistoryImport
historySqlImport config changed =
  requireRight
    ( historyImport
        "legacy-engine"
        (Map.fromList [(historyEvidenceKey number, historyEvidence number) | number <- [1 .. 3]])
        []
        (historyMappingFor 1 :| [historyMappingFor 2])
        "verified staging cutover"
    )
  where
    historyEvidence number =
      requireRight
        ( sourceManifestVerifiedEvidence
            ("legacy/000" <> Text.pack (show number) <> ".sql")
            (Just (LocalTimeWithoutZone (read "2020-01-02 03:04:05" :: LocalTime)))
            (Just (migrationFingerprint (historySqlBytes config number)))
            ( Aeson.object
                [ "ordinal" Aeson..= number,
                  "revision" Aeson..= if changed && number == (1 :: Int) then (2 :: Int) else 1
                ]
            )
        )
    historyMappingFor number =
      historyMapping
        (historyTarget number)
        (Evidence (historyEvidenceKey number))
        (SamePayload (historyEvidenceKey number))

historySqlBytes :: LedgerConfig -> Int -> ByteString
historySqlBytes config number =
  Text.Encoding.encodeUtf8
    ( case number of
        1 -> "CREATE TABLE " <> quotedSchema config <> ".import_action_1 (value integer)"
        2 -> "CREATE TABLE " <> quotedSchema config <> ".import_action_2 (value integer)"
        _ -> "CREATE TABLE " <> quotedSchema config <> ".import_action_3 (value integer)"
    )

historyTarget :: Int -> MigrationId
historyTarget number =
  requireRight
    ( Migrate.migrationId
        "history-import"
        (case number of 1 -> "0001-one"; 2 -> "0002-two"; _ -> "0003-three")
    )

historyEvidenceKey :: Int -> EvidenceKey
historyEvidenceKey number = requireRight (evidenceKey ("legacy:000" <> Text.pack (show number)))

historyStateKey :: EvidenceKey
historyStateKey = requireRight (evidenceKey "legacy:state")

historyHaskellTarget :: MigrationId
historyHaskellTarget = requireRight (Migrate.migrationId "history-equivalent" "0001-haskell")

equivalentHistoryPlan :: LedgerConfig -> StateValidator -> (MigrationPlan, HistoryImport)
equivalentHistoryPlan config validator =
  ( planFromMigrations "history-equivalent" [migration],
    requireRight
      ( historyImport
          "legacy-engine"
          Map.empty
          [validator]
          (historyMapping historyHaskellTarget (Evidence historyStateKey) EquivalentState :| [])
          "domain state verified"
      )
  )
  where
    migration =
      requireRight
        ( transactionMigration
            "0001-haskell"
            (migrationFingerprint "history-haskell-v1")
            (Transaction.sql (Text.Encoding.encodeUtf8 ("CREATE TABLE " <> quotedSchema config <> ".haskell_action (value integer)")))
        )

missingIndexPlan :: LedgerConfig -> Text -> Text -> Text -> MigrationPlan
missingIndexPlan config component indexName tableName =
  sqlPlan
    component
    [ ( "0001-index",
        Text.unlines
          [ "-- pg-migrate: no-transaction",
            "CREATE INDEX CONCURRENTLY " <> indexName <> " ON",
            quotedSchema config <> "." <> tableName <> " (value)"
          ]
      )
    ]

crashMigrationPlan :: LedgerConfig -> MigrationPlan
crashMigrationPlan _ =
  sqlPlan
    "crash-helper"
    [ ( "0001-sleep",
        "-- pg-migrate: no-transaction\nSELECT pg_sleep(2)"
      )
    ]

waitForRunning :: Connection.Connection -> LedgerConfig -> Int -> IO ()
waitForRunning _ _ 0 = assertFailure "crash helper did not persist Running within five seconds"
waitForRunning connection config attempts = do
  snapshot <- useSession connection (loadLedger config)
  if storedStatuses snapshot == [Running]
    then pure ()
    else do
      threadDelay 25000
      waitForRunning connection config (attempts - 1)

integrationRunnerVersion :: Text
integrationRunnerVersion = "pg-migrate-integration"

testLockKey :: Int64
testLockKey = 0x70675F6D74657374
