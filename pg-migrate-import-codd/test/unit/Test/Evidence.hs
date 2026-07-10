module Test.Evidence (tests) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.Codd
import Database.PostgreSQL.Migrate.History.Codd.Internal
import Database.PostgreSQL.Migrate.Internal (migrationChecksumBytes)
import Numeric qualified
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "evidence"
    [ testCase "manifest-verified payload evidence is constructed" testVerifiedEvidence,
      testCase "manifest checksum mismatches are distinct" testManifestMismatch,
      testCase "SamePayload confirmation fails before connection acquisition" testConfirmationPreflight,
      testCase "unknown targets fail before connection acquisition" testTargetPreflight
    ]

testVerifiedEvidence :: Assertion
testVerifiedEvidence = do
  let config = sourceConfig Confirmed (Just matchingManifest)
  case buildCoddEvidence config history of
    Left err -> assertFailure (show err)
    Right evidence -> Map.size evidence @?= 1

testManifestMismatch :: Assertion
testManifestMismatch = do
  let wrongManifest = expectRight (parseCoddManifest (replicateText 64 "0" <> " migration.sql\n"))
  case buildCoddEvidence (sourceConfig Confirmed (Just wrongManifest)) history of
    Left (CoddManifestChecksumMismatch "migration.sql" _ actual) -> actual @?= payloadChecksum
    result -> assertFailure ("expected manifest mismatch, received: " <> show result)

testConfirmationPreflight :: Assertion
testConfirmationPreflight = do
  let key = expectRight (coddEvidenceKey "migration.sql")
      target = expectRight (migrationId "target" "0001")
      mapping = historyMapping target (Evidence key) (SamePayload key)
      config = sourceConfig NotConfirmed Nothing
  result <-
    importCoddHistory
      defaultImportOptions
      config
      unusedProvider
      targetPlan
      (mapping :| [])
  case result of
    Left CoddConfirmationRequired -> pure ()
    other -> assertFailure ("expected confirmation preflight failure, received: " <> show other)

testTargetPreflight :: Assertion
testTargetPreflight = do
  let key = expectRight (coddEvidenceKey "migration.sql")
      unknownTarget = expectRight (migrationId "target" "missing")
      mapping = historyMapping unknownTarget (Evidence key) (SamePayload key)
  result <-
    importCoddHistory
      defaultImportOptions
      (sourceConfig Confirmed (Just matchingManifest))
      unusedProvider
      targetPlan
      (mapping :| [])
  case result of
    Left (CoddTargetImportFailed (HistoryImportValidationFailed (HistoryTargetUnknown actual))) ->
      actual @?= unknownTarget
    other -> assertFailure ("expected target preflight failure, received: " <> show other)

sourceConfig :: Confirmation -> Maybe CoddManifest -> CoddSourceConfig
sourceConfig confirmation manifest =
  expectRight
    ( coddSourceConfig
        unusedProvider
        ("migration.sql" :| [])
        False
        (Map.singleton "migration.sql" payload)
        manifest
        "fixture import"
        confirmation
    )

matchingManifest :: CoddManifest
matchingManifest = expectRight (parseCoddManifest (payloadChecksum <> " migration.sql\n"))

history :: CoddHistory
history =
  CoddHistory
    CoddV5
    (CoddHistoryRow "migration.sql" timestamp (Just timestamp) 1 Nothing :| [])
    []

targetPlan :: MigrationPlan
targetPlan =
  expectRight
    ( migrationPlan
        ( expectRight
            (migrationComponent "target" Set.empty (expectRight (sqlMigration "0001" payload) :| []))
            :| []
        )
    )

unusedProvider :: ConnectionProvider
unusedProvider = connectionProvider (\_ -> error "connection provider must not be used")

payload :: ByteString
payload = "SELECT 1"

payloadChecksum :: Text
payloadChecksum =
  Text.pack
    ( concatMap
        renderByte
        (ByteString.unpack (migrationChecksumBytes (migrationFingerprint payload)))
    )
  where
    renderByte byte = case Numeric.showHex byte "" of [digit] -> ['0', digit]; digits -> digits

timestamp :: UTCTime
timestamp = read "2026-07-10 12:00:00 UTC"

replicateText :: Int -> Text -> Text
replicateText count value = mconcat (replicate count value)

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
