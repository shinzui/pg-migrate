module Test.Manifest (tests) where

import Data.Text qualified
import Database.PostgreSQL.Migrate.History.Codd
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "manifest"
    [ testCase "lowercase SHA-256 entries parse" testValid,
      testCase "uppercase checksums are rejected" testUppercase,
      testCase "duplicate filenames are rejected" testDuplicate,
      testCase "evidence keys are explicit and stable" testEvidenceKey
    ]

testValid :: Assertion
testValid =
  case parseCoddManifest (checksum <> "  2024-01-01-create.sql\n") of
    Left err -> assertFailure (show err)
    Right _ -> pure ()

testUppercase :: Assertion
testUppercase =
  parseCoddManifest (replicateText 64 "A" <> " migration.sql\n")
    @?= Left (InvalidCoddManifestChecksum 1 (replicateText 64 "A"))

testDuplicate :: Assertion
testDuplicate =
  parseCoddManifest (checksum <> " migration.sql\n" <> checksum <> " migration.sql\n")
    @?= Left (DuplicateCoddManifestFilename "migration.sql")

testEvidenceKey :: Assertion
testEvidenceKey = do
  first <- either (assertFailure . show) pure (coddEvidenceKey "migration.sql")
  second <- either (assertFailure . show) pure (coddEvidenceKey "migration.sql")
  first @?= second

checksum :: Data.Text.Text
checksum = replicateText 64 "a"

replicateText :: Int -> Data.Text.Text -> Data.Text.Text
replicateText count value = mconcat (replicate count value)
