module Main (main) where

import Control.Exception qualified as Exception
import Data.ByteString (ByteString)
import Data.IORef qualified as IORef
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Session qualified as Session
import System.Environment (lookupEnv)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = do
  maybeConnectionString <- lookupEnv "PG_CONNECTION_STRING"
  case maybeConnectionString of
    Nothing ->
      putStrLn
        "pg-migrate-cli integration tests skipped: PG_CONNECTION_STRING is not set"
    Just connectionString ->
      defaultMain (tests (Settings.connectionString (Text.pack connectionString)))

tests :: Settings.Settings -> TestTree
tests settings =
  testGroup
    "pg-migrate CLI PostgreSQL"
    [ testCase "status verify and full up preserve their contracts" (testCommandLifecycle settings),
      testCase "confirmed repair dispatches through the shared lifecycle" (testRepairLifecycle settings),
      testCase "filtered verification keeps full-report exit classification" (testFilteredVerification settings)
    ]

testCommandLifecycle :: Settings.Settings -> Assertion
testCommandLifecycle settings =
  withCleanLedger settings "pgmigrate_cli_commands" 0x70676D636C690001 $ \options -> do
    observedEvents <- IORef.newIORef []
    let configuredOptions =
          withEventHandler (IORef.modifyIORef' observedEvents . (:)) $
            withStatementTimeout (Just 5) $
              withLockWait NoWait options
        environment = cliEnvironment settings commandPlan configuredOptions

    statusBefore <- runMigrationCommand environment statusCommand
    exitClass statusBefore @?= ExitSucceeded
    case payload statusBefore of
      Right (StatusPayload (StatusReport issues applied pending unknown)) -> do
        issues @?= []
        applied @?= []
        length pending @?= 1
        unknown @?= []
      other -> assertFailure ("unexpected status outcome: " <> show other)

    verifyBefore <- runMigrationCommand environment verifyCommand
    exitClass verifyBefore @?= ExitVerificationFailed
    case payload verifyBefore of
      Right (VerifyPayload (VerificationReport issues _ pending _)) -> do
        length issues @?= 1
        length pending @?= 1
      other -> assertFailure ("unexpected pre-run verify outcome: " <> show other)

    firstUp <- runMigrationCommand environment upCommand
    exitClass firstUp @?= ExitSucceeded
    assertSingleOutcome AppliedNow firstUp
    events <- IORef.readIORef observedEvents
    assertBool "application lock-wait setting survives absent CLI flags" (LockWaitStarted NoWait `elem` events)

    verifyAfter <- runMigrationCommand environment verifyCommand
    exitClass verifyAfter @?= ExitSucceeded
    case payload verifyAfter of
      Right (VerifyPayload (VerificationReport issues applied pending unknown)) -> do
        issues @?= []
        length applied @?= 1
        pending @?= []
        unknown @?= []
      other -> assertFailure ("unexpected post-run verify outcome: " <> show other)

    secondUp <- runMigrationCommand environment upCommand
    exitClass secondUp @?= ExitSucceeded
    assertSingleOutcome AlreadyApplied secondUp

testRepairLifecycle :: Settings.Settings -> Assertion
testRepairLifecycle settings =
  withCleanLedger settings "pgmigrate_cli_repair" 0x70676D636C690002 $ \options -> do
    let environment = cliEnvironment settings failingPlan options

    failedUp <- runMigrationCommand environment upCommand
    exitClass failedUp @?= ExitExecutionFailed

    repaired <-
      runMigrationCommand
        environment
        ( Repair
            ( RepairOptions
                failingMigrationId
                MarkApplied
                "operator inspected the database result"
                Confirmed
                noConnectionOverride
                defaultExecution
                jsonOutput
            )
        )
    exitClass repaired @?= ExitSucceeded
    case payload repaired of
      Right (RepairPayload (RepairReport identifier MarkApplied Failed Applied)) ->
        identifier @?= failingMigrationId
      other -> assertFailure ("unexpected repair outcome: " <> show other)

    verified <- runMigrationCommand environment verifyCommand
    exitClass verified @?= ExitSucceeded

testFilteredVerification :: Settings.Settings -> Assertion
testFilteredVerification settings =
  withCleanLedger settings "pgmigrate_cli_filters" 0x70676D636C690003 $ \options -> do
    let originalEnvironment = cliEnvironment settings (filteredPlan "SELECT 2") options
        changedEnvironment = cliEnvironment settings (filteredPlan "SELECT 3") options
        selectedInspection = InspectionOptions (Just filterAccounts) Nothing
        selectedVerification = Verify (VerifyOptions selectedInspection noConnectionOverride jsonOutput)

    applied <- runMigrationCommand originalEnvironment upCommand
    exitClass applied @?= ExitSucceeded

    filtered <- runMigrationCommand changedEnvironment selectedVerification
    exitClass filtered @?= ExitVerificationFailed
    case payload filtered of
      Right (VerifyPayload (VerificationReport issues appliedMigrations pending unknown)) -> do
        issues @?= []
        appliedMigrations @?= [filterAccountsMigration]
        pending @?= []
        unknown @?= []
      other -> assertFailure ("unexpected filtered verification outcome: " <> show other)

assertSingleOutcome :: MigrationOutcome -> CliOutcome -> Assertion
assertSingleOutcome expected outcome =
  case payload outcome of
    Right (UpPayload (MigrationReport _ _ (MigrationResult _ actual _ :| []))) ->
      actual @?= expected
    other -> assertFailure ("unexpected up outcome: " <> show other)

statusCommand :: MigrationCommand
statusCommand = Status (StatusOptions noInspection noConnectionOverride jsonOutput)

verifyCommand :: MigrationCommand
verifyCommand = Verify (VerifyOptions noInspection noConnectionOverride jsonOutput)

upCommand :: MigrationCommand
upCommand = Up (UpOptions noConnectionOverride defaultExecution jsonOutput)

noInspection :: InspectionOptions
noInspection = InspectionOptions Nothing Nothing

noConnectionOverride :: ConnectionOptions
noConnectionOverride = ConnectionOptions Nothing

defaultExecution :: ExecutionOptions
defaultExecution = ExecutionOptions Nothing Nothing

jsonOutput :: OutputOptions
jsonOutput = OutputOptions JsonOutput

commandPlan :: MigrationPlan
commandPlan =
  expectRight
    ( migrationPlan
        ( expectRight
            ( migrationComponent
                "cli-commands"
                Set.empty
                ( expectRight
                    ( sqlMigration
                        "0001"
                        """
                        DO $$
                        BEGIN
                          IF current_setting('statement_timeout') <> '5s' THEN
                            RAISE EXCEPTION 'application statement timeout was overridden';
                          END IF;
                        END
                        $$;
                        CREATE TABLE pgmigrate_cli_commands.cli_command_probe (id bigint PRIMARY KEY)
                        """
                    )
                    :| []
                )
            )
            :| []
        )
    )

filteredPlan :: ByteString -> MigrationPlan
filteredPlan billingSql =
  expectRight
    ( migrationPlan
        ( expectRight
            ( migrationComponent
                "filter-accounts"
                Set.empty
                (expectRight (sqlMigration "0001" "SELECT 1") :| [])
            )
            :| [ expectRight
                   ( migrationComponent
                       "filter-billing"
                       (Set.singleton "filter-accounts")
                       (expectRight (sqlMigration "0001" billingSql) :| [])
                   )
               ]
        )
    )

filterAccounts :: ComponentName
filterAccounts = expectRight (componentName "filter-accounts")

filterAccountsMigration :: MigrationId
filterAccountsMigration = expectRight (migrationId "filter-accounts" "0001")

failingPlan :: MigrationPlan
failingPlan =
  expectRight
    ( migrationPlan
        ( expectRight
            ( migrationComponent
                "cli-repair"
                Set.empty
                (failingMigration :| [])
            )
            :| []
        )
    )

failingMigration :: Migration
failingMigration =
  expectRight
    ( sessionMigration
        "0001"
        (migrationFingerprint "cli-repair-v1")
        (Session.script "SELECT * FROM pgmigrate_cli_deliberately_missing_table")
    )

failingMigrationId :: MigrationId
failingMigrationId = expectRight (migrationId "cli-repair" "0001")

withCleanLedger ::
  Settings.Settings ->
  Text.Text ->
  Int64 ->
  (RunOptions -> IO value) ->
  IO value
withCleanLedger settings schemaName lockKey action = do
  let config = expectRight (ledgerConfig schemaName lockKey)
  Exception.bracket_
    (dropSchema settings schemaName)
    (dropSchema settings schemaName)
    (action (withLedger config defaultRunOptions))

dropSchema :: Settings.Settings -> Text.Text -> IO ()
dropSchema settings schemaName = do
  acquired <- Connection.acquire settings
  case acquired of
    Left connectionError -> assertFailure ("could not acquire integration connection: " <> show connectionError)
    Right connection ->
      Exception.finally
        ( do
            result <- Connection.use connection (Session.script ("DROP SCHEMA IF EXISTS " <> schemaName <> " CASCADE"))
            case result of
              Left sessionError -> assertFailure ("could not clean integration schema: " <> show sessionError)
              Right () -> pure ()
        )
        (Connection.release connection)

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
