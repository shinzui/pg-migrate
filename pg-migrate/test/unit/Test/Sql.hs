module Test.Sql (tests) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Internal
  ( MigrationKind (..),
    TransactionMode (..),
    migrationKind,
    migrationSqlBytes,
    migrationTransactionMode,
  )
import PgMigrate.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "SQL definitions"
    [ testCase "SQL is transactional by default" $
        modeOf "SELECT 1" @?= Right Transactional,
      testCase "a leading directive selects nontransactional execution" $
        modeOf "-- pg-migrate: no-transaction\nCREATE INDEX CONCURRENTLY example_idx ON example (id)"
          @?= Right NonTransactional,
      testCase "a directive inside a string is ordinary payload" $
        modeOf "SELECT '-- pg-migrate: no-transaction'"
          @?= Right Transactional,
      testCase "a directive after the first SQL token is ignored" $
        modeOf "SELECT 1;\n-- pg-migrate: no-transaction\nSELECT 2"
          @?= Right Transactional,
      testCase "an unknown leading directive fails" $
        assertDefinitionLeft
          (InvalidSql (UnknownDirective "pg-migrate: eventually"))
          (sqlMigration "0001-test" "-- pg-migrate: eventually\nSELECT 1"),
      testCase "a duplicate transaction directive fails" $
        assertDefinitionLeft
          (InvalidSql DuplicateNoTransactionDirective)
          ( sqlMigration
              "0001-test"
              "-- pg-migrate: no-transaction\n-- pg-migrate: no-transaction\nSELECT 1"
          ),
      testCase "semicolons in standard strings do not split statements" $
        modeOf "SELECT 'one;two'; SELECT 2"
          @?= Right Transactional,
      testCase "semicolons in escape strings do not split statements" $
        modeOf "SELECT E'one\\';two'; SELECT 2"
          @?= Right Transactional,
      testCase "semicolons in quoted identifiers do not split statements" $
        modeOf "SELECT 1 AS \"one;two\"; SELECT 2"
          @?= Right Transactional,
      testCase "semicolons in dollar-quoted bodies do not split statements" $
        modeOf
          "CREATE FUNCTION example() RETURNS void LANGUAGE plpgsql AS $body$ BEGIN PERFORM 1; END $body$; SELECT 2"
          @?= Right Transactional,
      testCase "semicolons in line and nested block comments do not split statements" $
        modeOf "/* outer; /* inner; */ done; */ SELECT 1; -- ignored;\nSELECT 2"
          @?= Right Transactional,
      testGroup
        "transaction control is prohibited"
        (fmap prohibitedCase prohibitedCommands),
      testCase "one nontransactional statement succeeds" $
        modeOf "-- pg-migrate: no-transaction\nCREATE INDEX CONCURRENTLY example_idx ON example (id);"
          @?= Right NonTransactional,
      testCase "multiple nontransactional statements fail" $
        assertDefinitionLeft
          (InvalidSql (NonTransactionalStatementCount 2))
          ( sqlMigration
              "0001-test"
              "-- pg-migrate: no-transaction\nSELECT 1; SELECT 2"
          ),
      testCase "empty SQL fails" $
        assertDefinitionLeft
          (InvalidSql EmptySql)
          (sqlMigration "0001-test" " -- only a comment"),
      testCase "invalid UTF-8 reports the offending byte" $
        assertDefinitionLeft
          (InvalidSql (InvalidUtf8 2))
          (sqlMigration "0001-test" (ByteString.pack [0x61, 0xE2, 0x28, 0xA1])),
      testCase "a leading UTF-8 byte-order mark is rejected" $
        assertDefinitionLeft
          (InvalidSql ByteOrderMarkFound)
          (sqlMigration "0001-test" (ByteString.pack [0xEF, 0xBB, 0xBF] <> "SELECT 1")),
      testCase "a byte-order mark cannot hide a leading directive" $
        assertDefinitionLeft
          (InvalidSql ByteOrderMarkFound)
          ( sqlMigration
              "0001-test"
              ( ByteString.pack [0xEF, 0xBB, 0xBF]
                  <> "-- pg-migrate: no-transaction\nCREATE INDEX CONCURRENTLY example_idx ON example (id)"
              )
          ),
      -- U+FEFF away from byte offset zero is not an editor-added leading BOM, so
      -- definition-time validation leaves its PostgreSQL meaning unchanged.
      testCase "U+FEFF inside SQL remains ordinary payload" $
        modeOf ("SELECT 1" <> ByteString.pack [0xEF, 0xBB, 0xBF])
          @?= Right Transactional,
      testCase "psql meta-commands fail with their line" $
        assertDefinitionLeft
          (InvalidSql (PsqlMetaCommand 2))
          (sqlMigration "0001-test" "SELECT 1;\n  \\echo unsupported"),
      testCase "COPY FROM STDIN is unsupported" $
        assertDefinitionLeft
          (InvalidSql CopyFromStdin)
          (sqlMigration "0001-test" "COPY example (id) FROM STDIN"),
      testCase "unterminated lexical constructs fail safely" $
        assertDefinitionLeft
          (InvalidSql (UnterminatedSqlConstruct "single-quoted string"))
          (sqlMigration "0001-test" "SELECT 'unfinished"),
      testCase "SQL migrations retain exact bytes and SQL kind" $ do
        migration <- assertRight (sqlMigration "0001-test" "SELECT 1  \n")
        migrationKind migration @?= SqlKind
        migrationSqlBytes migration @?= Just "SELECT 1  \n",
      testCase "whitespace changes the SQL checksum" $ do
        firstMigration <- assertRight (sqlMigration "0001-test" "SELECT 1")
        secondMigration <- assertRight (sqlMigration "0001-test" "SELECT  1")
        migrationFingerprint "SELECT 1"
          @?= migrationFingerprint (fromMaybe ByteString.empty (migrationSqlBytes firstMigration))
        migrationFingerprint "SELECT 1"
          /= migrationFingerprint (fromMaybe ByteString.empty (migrationSqlBytes secondMigration))
          @?= True
    ]

prohibitedCommands :: [(ByteString, Text)]
prohibitedCommands =
  [ ("BEGIN", "BEGIN"),
    ("START TRANSACTION", "START TRANSACTION"),
    ("COMMIT", "COMMIT"),
    ("END", "END"),
    ("ROLLBACK", "ROLLBACK"),
    ("ABORT", "ABORT"),
    ("SAVEPOINT before_change", "SAVEPOINT"),
    ("RELEASE SAVEPOINT before_change", "RELEASE SAVEPOINT"),
    ("PREPARE TRANSACTION 'transaction-id'", "PREPARE TRANSACTION"),
    ("COMMIT PREPARED 'transaction-id'", "COMMIT PREPARED"),
    ("ROLLBACK PREPARED 'transaction-id'", "ROLLBACK PREPARED")
  ]

prohibitedCase :: (ByteString, Text) -> TestTree
prohibitedCase (sql, command) =
  testCase (ByteString.Char8.unpack sql) $
    assertDefinitionLeft
      (InvalidSql (ProhibitedTransactionCommand command))
      (sqlMigration "0001-test" sql)

modeOf :: ByteString -> Either DefinitionError TransactionMode
modeOf sql = migrationTransactionMode <$> sqlMigration "0001-test" sql

assertRight :: (Show error) => Either error value -> IO value
assertRight = \case
  Left err -> assertFailure ("expected Right, received Left " <> show err)
  Right value -> pure value

assertDefinitionLeft :: DefinitionError -> Either DefinitionError value -> IO ()
assertDefinitionLeft expected = \case
  Left actual -> actual @?= expected
  Right _ -> assertFailure ("expected Left " <> show expected <> ", received Right")
