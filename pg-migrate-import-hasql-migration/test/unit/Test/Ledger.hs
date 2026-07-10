module Test.Ledger (tests) where

import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (LocalTime)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.HasqlMigration
import Database.PostgreSQL.Migrate.History.HasqlMigration.Internal
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "ledger model"
    [ testCase "valid legacy MD5 is accepted in selected order" testValid,
      testCase "invalid legacy MD5 reports both encodings" testMismatch,
      testCase "duplicate ledger filenames are rejected" testDuplicate,
      testCase "lenient selection reports extras and strict selection rejects" testStrict,
      testCase "missing selected filenames are distinct" testMissing
    ]

testValid :: Assertion
testValid =
  case validateHasqlMigrationRows (config False ("two.sql" :| ["one.sql"])) [rowOne, rowTwo] of
    Right history -> do
      (filename <$> toList (selectedRows history)) @?= ["two.sql", "one.sql"]
      unselectedRows history @?= []
    Left err -> assertFailure (show err)

testMismatch :: Assertion
testMismatch =
  case validateHasqlMigrationRows (config False ("one.sql" :| [])) [rowOne {storedMd5 = "wrong"}] of
    Left (HasqlMigrationChecksumMismatch "one.sql" "wrong" actual) -> actual @?= md5One
    other -> assertFailure ("unexpected mismatch result: " <> show other)

testDuplicate :: Assertion
testDuplicate =
  assertError
    (\case HasqlMigrationDuplicateLedgerFilename "one.sql" -> True; _ -> False)
    (validateHasqlMigrationRows (config False ("one.sql" :| [])) [rowOne, rowOne])

testStrict :: Assertion
testStrict = do
  case validateHasqlMigrationRows (config False ("one.sql" :| [])) [rowOne, rowTwo] of
    Right history -> (filename <$> unselectedRows history) @?= ["two.sql"]
    Left err -> assertFailure (show err)
  assertError
    (\case HasqlMigrationStrictSourceHasUnselected ["two.sql"] -> True; _ -> False)
    (validateHasqlMigrationRows (config True ("one.sql" :| [])) [rowOne, rowTwo])

testMissing :: Assertion
testMissing =
  assertError
    (\case HasqlMigrationSelectedFilenameMissing "two.sql" -> True; _ -> False)
    (validateHasqlMigrationRows (config False ("two.sql" :| [])) [rowOne])

config :: Bool -> NonEmpty FilePath -> HasqlMigrationSourceConfig
config strict filenames =
  expectRight
    ( hasqlMigrationSourceConfig
        unusedProvider
        defaultHasqlMigrationTable
        filenames
        strict
        payloads
        []
        "fixture import"
    )

rowOne, rowTwo :: HasqlMigrationRow
rowOne = HasqlMigrationRow "one.sql" md5One timestamp
rowTwo = HasqlMigrationRow "two.sql" md5Two timestamp

md5One, md5Two :: Text
md5One = "sWmOUqDxYgNIlFQZagxjBw=="
md5Two = "/Bx6C9zjErILw3gN1tQaqg=="

payloads :: Map.Map FilePath ByteString
payloads = Map.fromList [("one.sql", "SELECT 1"), ("two.sql", "SELECT 2")]

timestamp :: LocalTime
timestamp = read "2024-01-02 03:04:05"

unusedProvider :: ConnectionProvider
unusedProvider = connectionProvider (\_ -> error "connection provider must not be used")

assertError :: (HasqlMigrationImportError -> Bool) -> Either HasqlMigrationImportError value -> Assertion
assertError matches result =
  case result of
    Left err | matches err -> pure ()
    Left err -> assertFailure ("unexpected error: " <> show err)
    Right _ -> assertFailure "expected error, received Right"

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
