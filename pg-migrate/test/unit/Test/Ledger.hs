module Test.Ledger (tests) where

import Data.Int (Int64)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ledger"
    [ testCase "default configuration is valid" testDefaultConfiguration,
      testCase "custom quoted identifiers are valid" testQuotedIdentifier,
      testCase "empty schema identifiers are rejected" testEmptyIdentifier,
      testCase "NUL schema identifiers are rejected" testNulIdentifier,
      testCase "schema identifiers use PostgreSQL's byte limit" testIdentifierLength
    ]

testDefaultConfiguration :: IO ()
testDefaultConfiguration =
  defaultLedgerConfig @?= requireRight (ledgerConfig "pg_migrate" defaultLockKey)

testQuotedIdentifier :: IO ()
testQuotedIdentifier =
  assertRight (ledgerConfig "application \"migrations\"" 17)

testEmptyIdentifier :: IO ()
testEmptyIdentifier =
  ledgerConfig "" 17
    @?= Left
      InvalidLedgerSchema
        { input = "",
          postgresIdentifierReason = EmptyPostgresIdentifier
        }

testNulIdentifier :: IO ()
testNulIdentifier =
  ledgerConfig "invalid\NULschema" 17
    @?= Left
      InvalidLedgerSchema
        { input = "invalid\NULschema",
          postgresIdentifierReason = PostgresIdentifierContainsNul
        }

testIdentifierLength :: IO ()
testIdentifierLength =
  ledgerConfig tooLong 17
    @?= Left
      InvalidLedgerSchema
        { input = tooLong,
          postgresIdentifierReason =
            PostgresIdentifierTooLong
              { actualBytes = 64,
                maximumBytes = 63
              }
        }
  where
    tooLong = Text.replicate 64 "a"

defaultLockKey :: Int64
defaultLockKey = 0x70675F6D69677261

requireRight :: (Show error) => Either error value -> value
requireRight = \case
  Left err -> error (show err)
  Right value -> value

assertRight :: (Show error) => Either error value -> IO ()
assertRight = \case
  Left err -> assertFailure (show err)
  Right _ -> pure ()
