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
import Data.Foldable (toList)
import Data.Function ((&))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (NominalDiffTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
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
      testCase "nontransactional preflight happens before every mutation" (testNonTransactionalPreflight settings),
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
    majorVersion @?= 17
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
                Text.unwords
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

testNonTransactionalPreflight :: Settings.Settings -> IO ()
testNonTransactionalPreflight settings =
  withTestLedger settings "preflight" $ \connection config -> do
    let transactional =
          requireRight
            ( sqlMigration
                "0001-must-not-run"
                (Text.Encoding.encodeUtf8 ("CREATE TABLE " <> quotedSchema config <> ".must_not_run (value integer)"))
            )
        nontransactional =
          requireRight
            ( sqlMigration
                "0002-concurrent"
                "-- pg-migrate: no-transaction\nCREATE INDEX CONCURRENTLY never_runs ON missing_table (value)"
            )
        plan = planFromMigrations "preflight" [transactional, nontransactional]
    runMigrationPlan (withLedger config defaultRunOptions) settings plan
      >>= assertUnsupportedNonTransactional
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    assertBool "preflight allowed an earlier pending migration to run" ("must_not_run" `notElem` tableNames)
    snapshot <- useSession connection (loadLedger config)
    storedMigrations snapshot @?= []

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

assertUnsupportedNonTransactional :: Either MigrationError MigrationReport -> IO ()
assertUnsupportedNonTransactional = \case
  Left UnsupportedNonTransactionalMigration {} -> pure ()
  Left migrationError -> assertFailure ("expected UnsupportedNonTransactionalMigration, received " <> show migrationError)
  Right report -> assertFailure ("expected UnsupportedNonTransactionalMigration, received " <> show report)

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

integrationRunnerVersion :: Text
integrationRunnerVersion = "pg-migrate-integration"

testLockKey :: Int64
testLockKey = 0x70675F6D74657374
