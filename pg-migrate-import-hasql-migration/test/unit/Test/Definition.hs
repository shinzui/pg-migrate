module Test.Definition (tests) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.HasqlMigration
import Database.PostgreSQL.Migrate.History.HasqlMigration.Internal
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "definition"
    [ testCase "qualified tables require exactly two safe identifiers" testQualifiedTable,
      testCase "qualified tables quote both identifiers" testQuoting,
      testCase "source selections require unique names and exact payloads" testSourceConfig,
      testCase "evidence keys are explicit and stable" testEvidenceKey
    ]

testQualifiedTable :: Assertion
testQualifiedTable = do
  assertLeft (qualifiedTable "schema_migrations")
  assertLeft (qualifiedTable "a.b.c")
  assertLeft (qualifiedTable ".table")
  assertLeft (qualifiedTable "schema.")
  qualifiedTable "public.schema_migrations" @?= Right defaultHasqlMigrationTable

testQuoting :: Assertion
testQuoting =
  renderQualifiedTable (expectRight (qualifiedTable "legacy data.migration\"history"))
    @?= "\"legacy data\".\"migration\"\"history\""

testSourceConfig :: Assertion
testSourceConfig = do
  assertLeft (hasqlMigrationSourceConfig unusedProvider defaultHasqlMigrationTable ("one.sql" :| ["one.sql"]) False payloads [] "reason")
  assertLeft (hasqlMigrationSourceConfig unusedProvider defaultHasqlMigrationTable ("missing.sql" :| []) False payloads [] "reason")
  case hasqlMigrationSourceConfig unusedProvider defaultHasqlMigrationTable ("one.sql" :| []) False payloads [] "reason" of
    Right _ -> pure ()
    Left err -> assertFailure (show err)

testEvidenceKey :: Assertion
testEvidenceKey = do
  expectRight (hasqlMigrationEvidenceKey "one.sql") @?= expectRight (evidenceKey "hasql-migration:one.sql")
  assertLeft (hasqlMigrationEvidenceKey "")

payloads :: Map.Map FilePath ByteString
payloads = Map.singleton "one.sql" "SELECT 1"

unusedProvider :: ConnectionProvider
unusedProvider = connectionProvider (\_ -> error "connection provider must not be used")

assertLeft :: Either error value -> Assertion
assertLeft = either (const (pure ())) (const (assertFailure "expected Left, received Right"))

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
