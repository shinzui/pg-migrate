module Test.Evidence (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.HasqlMigration
import Database.PostgreSQL.Migrate.History.HasqlMigration.Internal
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "evidence"
    [ testCase "verified ledger evidence carries exact source SHA-256" testEvidence,
      testCase "unknown targets fail before connection acquisition" testTargetPreflight
    ]

testEvidence :: Assertion
testEvidence =
  case buildHasqlMigrationEvidence config history of
    Left err -> assertFailure (show err)
    Right evidence -> Map.size evidence @?= 1

testTargetPreflight :: Assertion
testTargetPreflight = do
  let key = expectRight (hasqlMigrationEvidenceKey "one.sql")
      unknown = expectRight (migrationId "target" "missing")
      mapping = historyMapping unknown (Evidence key) (SamePayload key)
  result <- importHasqlMigrationHistory defaultImportOptions config unusedProvider targetPlan (mapping :| [])
  case result of
    Left (HasqlMigrationTargetImportFailed (HistoryImportValidationFailed (HistoryTargetUnknown actual))) -> actual @?= unknown
    other -> assertFailure ("expected preflight failure, received: " <> show other)

config :: HasqlMigrationSourceConfig
config =
  expectRight
    ( hasqlMigrationSourceConfig
        unusedProvider
        defaultHasqlMigrationTable
        ("one.sql" :| [])
        False
        (Map.singleton "one.sql" "SELECT 1")
        []
        "fixture import"
    )

history :: HasqlMigrationHistory
history = HasqlMigrationHistory (HasqlMigrationRow "one.sql" "sWmOUqDxYgNIlFQZagxjBw==" (read "2024-01-02 03:04:05") :| []) []

targetPlan :: MigrationPlan
targetPlan =
  expectRight
    ( migrationPlan
        (expectRight (migrationComponent "target" Set.empty (expectRight (sqlMigration "0001" "SELECT 1") :| [])) :| [])
    )

unusedProvider :: ConnectionProvider
unusedProvider = connectionProvider (\_ -> error "connection provider must not be used")

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
