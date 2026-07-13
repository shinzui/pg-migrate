module Test.Runner (tests) where

import Data.Function ((&))
import Data.Int (Int32)
import Data.Time (NominalDiffTime)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate qualified as Migrate
import Database.PostgreSQL.Migrate.Internal
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "runner"
    [ testCase "default options are conservative" testDefaultOptions,
      testCase "functional option updates compose" testOptionUpdates,
      testCase "report values remain immutable structured data" testReportValues,
      testCase "server version classification accepts only 17 and 18" testServerVersions,
      testCase "statement timeout of zero is rejected before connection acquisition" testZeroStatementTimeout,
      testCase "repair requests require confirmation" testRepairConfirmation,
      testCase "repair requests require a non-empty reason" testRepairReason
    ]

testDefaultOptions :: IO ()
testDefaultOptions = do
  runLedgerConfig defaultRunOptions @?= defaultLedgerConfig
  runLockWait defaultRunOptions @?= WaitIndefinitely
  runStatementTimeout defaultRunOptions @?= Nothing
  runUnknownMigrationsPolicy defaultRunOptions @?= RejectUnknownMigrations

testOptionUpdates :: IO ()
testOptionUpdates = do
  let customLedger = requireRight (ledgerConfig "application_migrations" 99)
      timeout = 12.5 :: NominalDiffTime
      options =
        defaultRunOptions
          & withLedger customLedger
          & withLockWait (WaitFor 3)
          & withStatementTimeout (Just timeout)
          & withUnknownMigrationsPolicy AllowUnknownMigrations
  runLedgerConfig options @?= customLedger
  runLockWait options @?= WaitFor 3
  runStatementTimeout options @?= Just timeout
  runUnknownMigrationsPolicy options @?= AllowUnknownMigrations

testReportValues :: IO ()
testReportValues = do
  let identifier = requireRight (Migrate.migrationId "component" "0001")
      result = MigrationResult identifier AppliedNow (Just 0.5)
  result @?= MigrationResult identifier AppliedNow (Just 0.5)
  MigrationCompleted identifier 0.5 @?= MigrationCompleted identifier 0.5

testServerVersions :: IO ()
testServerVersions = do
  requireRight (classifyServerVersion (170010 :: Int32)) @?= 17
  requireRight (classifyServerVersion (180000 :: Int32)) @?= 18
  assertUnsupported 16 (classifyServerVersion 160010)
  assertUnsupported 19 (classifyServerVersion 190000)

testZeroStatementTimeout :: IO ()
testZeroStatementTimeout = do
  let options = defaultRunOptions & withStatementTimeout (Just 0)
      provider = connectionProvider (\_ -> error "zero timeout acquired a connection")
  runMigrationPlanWith options provider (error "zero timeout evaluated the migration plan")
    >>= assertInvalidStatementTimeout
  applyStatementTimeout (error "zero timeout used a connection") (Just 0)
    >>= assertInvalidStatementTimeout

assertInvalidStatementTimeout :: (Show value) => Either MigrationError value -> IO ()
assertInvalidStatementTimeout = \case
  Left (InvalidStatementTimeout timeout) -> timeout @?= 0
  other -> error ("expected InvalidStatementTimeout 0, received " <> show other)

assertUnsupported :: Int -> Either MigrationError Int -> IO ()
assertUnsupported expected = \case
  Left (UnsupportedPostgresVersion actual) -> actual @?= expected
  other -> error ("expected unsupported PostgreSQL version, received " <> show other)

testRepairConfirmation :: IO ()
testRepairConfirmation = do
  let identifier = requireRight (Migrate.migrationId "component" "0001")
  repairRequest identifier MarkApplied "operator verified state" NotConfirmed
    @?= Left RepairNotConfirmed
  case repairRequest identifier MarkApplied "operator verified state" Confirmed of
    Left repairError -> error (show repairError)
    Right _ -> pure ()

testRepairReason :: IO ()
testRepairReason = do
  let identifier = requireRight (Migrate.migrationId "component" "0001")
  repairRequest identifier Retry "   " Confirmed @?= Left EmptyRepairReason

requireRight :: (Show error) => Either error value -> value
requireRight = \case
  Left err -> error (show err)
  Right value -> value
