module Test.Runner (tests) where

import Data.Function ((&))
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
      testCase "report values remain immutable structured data" testReportValues
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

requireRight :: (Show error) => Either error value -> value
requireRight = \case
  Left err -> error (show err)
  Right value -> value
