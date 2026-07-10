module Test.Ledger (tests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.Codd
import Database.PostgreSQL.Migrate.History.Codd.Internal
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ledger model"
    [ testCase "V1 through V5 require exact documented columns" testShapes,
      testCase "both schema generations are rejected" testBothSchemas,
      testCase "unknown columns are rejected" testUnknownShape,
      testCase "selection preserves requested order and reports unselected rows" testSelection,
      testCase "strict selection rejects unselected rows" testStrictSelection,
      testCase "duplicate filenames are rejected" testDuplicate,
      testCase "partial nontransactional rows are rejected" testPartial,
      testCase "missing selected filenames are distinct" testMissing
    ]

testShapes :: Assertion
testShapes = do
  assertRight (CoddV1, "codd_schema") (classifyCoddSchema (qualified "codd_schema" v1Columns))
  assertRight (CoddV2, "codd_schema") (classifyCoddSchema (qualified "codd_schema" v2Columns))
  assertRight (CoddV3, "codd_schema") (classifyCoddSchema (qualified "codd_schema" v3Columns))
  assertRight (CoddV4, "codd_schema") (classifyCoddSchema (qualified "codd_schema" v4Columns))
  assertRight (CoddV5, "codd") (classifyCoddSchema (qualified "codd" v4Columns))

testBothSchemas :: Assertion
testBothSchemas =
  assertLeft CoddBothSchemasPresent (classifyCoddSchema (qualified "codd_schema" v1Columns <> qualified "codd" v4Columns))

testUnknownShape :: Assertion
testUnknownShape =
  assertLeft
    (CoddUnsupportedShape "codd" (v4Columns <> ["unexpected"]))
    (classifyCoddSchema (qualified "codd" (v4Columns <> ["unexpected"])))

testSelection :: Assertion
testSelection = do
  let config = sourceConfig ("second.sql" :| ["first.sql"]) False
  case validateCoddRows config CoddV5 [row "first.sql", row "extra.sql", row "second.sql"] of
    Left err -> assertFailure (show err)
    Right CoddHistory {selectedRows, unselectedRows} -> do
      fmap filename selectedRows @?= ("second.sql" :| ["first.sql"])
      fmap filename unselectedRows @?= ["extra.sql"]

testStrictSelection :: Assertion
testStrictSelection =
  assertLeft
    (CoddStrictSourceHasUnselected ["extra.sql"])
    (validateCoddRows (sourceConfig ("first.sql" :| []) True) CoddV1 [row "first.sql", row "extra.sql"])

testDuplicate :: Assertion
testDuplicate =
  assertLeft
    (CoddDuplicateLedgerFilename "first.sql")
    (validateCoddRows (sourceConfig ("first.sql" :| []) False) CoddV1 [row "first.sql", row "first.sql"])

testPartial :: Assertion
testPartial =
  assertLeft
    (CoddPartialMigration "first.sql")
    (validateCoddRows (sourceConfig ("first.sql" :| []) False) CoddV3 [partialRow "first.sql"])

testMissing :: Assertion
testMissing =
  assertLeft
    (CoddSelectedFilenameMissing "missing.sql")
    (validateCoddRows (sourceConfig ("missing.sql" :| []) False) CoddV2 [row "first.sql"])

sourceConfig :: NonEmpty FilePath -> Bool -> CoddSourceConfig
sourceConfig selected strictSource =
  expectRight
    ( coddSourceConfig
        (connectionProvider (\_ -> error "unused source provider"))
        selected
        strictSource
        Map.empty
        Nothing
        "fixture import"
        NotConfirmed
    )

row :: FilePath -> CoddHistoryRow
row filename = CoddHistoryRow filename timestamp (Just timestamp) 1 Nothing

partialRow :: FilePath -> CoddHistoryRow
partialRow filename = CoddHistoryRow filename timestamp Nothing 2 (Just timestamp)

timestamp :: UTCTime
timestamp = read "2026-07-10 12:00:00 UTC"

qualified :: Text -> [Text] -> [(Text, Text)]
qualified schemaName = fmap (\column -> (schemaName, column))

v1Columns, v2Columns, v3Columns, v4Columns :: [Text]
v1Columns = ["id", "migration_timestamp", "applied_at", "name"]
v2Columns = v1Columns <> ["application_duration"]
v3Columns = v2Columns <> ["num_applied_statements", "no_txn_failed_at"]
v4Columns = v3Columns <> ["txnid", "connid"]

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id

assertRight :: (Eq value, Show value, Show error) => value -> Either error value -> Assertion
assertRight expected actual =
  case actual of
    Left err -> assertFailure ("expected success, received: " <> show err)
    Right value -> value @?= expected

assertLeft :: (Show error, Show value) => error -> Either error value -> Assertion
assertLeft expected actual =
  case actual of
    Left err -> show err @?= show expected
    Right value -> assertFailure ("expected error, received: " <> show value)
