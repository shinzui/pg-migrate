module Test.Json (tests) where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.Foldable (traverse_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI
import Database.PostgreSQL.Migrate.Embed (ManifestError (EmptyManifest))
import Database.PostgreSQL.Migrate.Internal
  ( ComponentDescription (ComponentDescription),
    MigrationDescription (MigrationDescription),
    MigrationKind (..),
    TransactionMode (..),
  )
import Paths_pg_migrate_cli qualified as Paths
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "JSON schema v1"
    [ goldenCase "plan" planOutcome,
      goldenCase "status" statusOutcome,
      goldenCase "verify" verifyOutcome,
      goldenCase "up" upOutcome,
      goldenCase "repair" repairOutcome,
      goldenCase "error" errorOutcome,
      testCase "import matches its golden contract" testImportGolden,
      testCase "rendering is byte-for-byte stable" testStableRendering
    ]

goldenCase :: FilePath -> CliOutcome -> TestTree
goldenCase name outcome =
  testCase (name <> " matches its golden contract") $ do
    goldenPath <- Paths.getDataFileName ("test/golden/json/" <> name <> ".json")
    goldenBytes <- ByteString.readFile goldenPath
    expected <-
      case Aeson.eitherDecodeStrict' goldenBytes of
        Left decodeError -> assertFailure ("invalid golden JSON: " <> decodeError)
        Right value -> pure value
    renderMigrationCommandJson outcome @?= expected

testImportGolden :: Assertion
testImportGolden = do
  goldenPath <- Paths.getDataFileName "test/golden/json/import.json"
  goldenBytes <- ByteString.readFile goldenPath
  expected <-
    case Aeson.eitherDecodeStrict' goldenBytes of
      Left decodeError -> assertFailure ("invalid golden JSON: " <> decodeError)
      Right value -> pure value
  renderHistoryImportJson "codd" importReport @?= expected

testStableRendering :: Assertion
testStableRendering =
  traverse_
    ( \outcome ->
        Aeson.encode (renderMigrationCommandJson outcome)
          @?= Aeson.encode (renderMigrationCommandJson outcome)
    )
    fixtureOutcomes

fixtureOutcomes :: [CliOutcome]
fixtureOutcomes =
  [ planOutcome,
    statusOutcome,
    verifyOutcome,
    upOutcome,
    repairOutcome,
    errorOutcome
  ]

planOutcome :: CliOutcome
planOutcome =
  successful
    "plan"
    ( PlanPayload
        [ ComponentDescription
            accounts
            1
            Set.empty
            (MigrationDescription migrationIdentifier 1 emptyChecksum SqlKind Transactional :| [])
        ]
    )

statusOutcome :: CliOutcome
statusOutcome =
  successful "status" (StatusPayload (StatusReport [] [migrationIdentifier] [] []))

verifyOutcome :: CliOutcome
verifyOutcome =
  CliOutcome
    { command = "verify",
      exitClass = ExitVerificationFailed,
      payload =
        Right
          ( VerifyPayload
              (VerificationReport [PendingMigration migrationIdentifier] [] [migrationIdentifier] [])
          )
    }

upOutcome :: CliOutcome
upOutcome =
  successful
    "up"
    ( UpPayload
        ( MigrationReport
            fixtureStartedAt
            fixtureFinishedAt
            (MigrationResult migrationIdentifier AppliedNow (Just 0.125) :| [])
        )
    )

repairOutcome :: CliOutcome
repairOutcome =
  successful
    "repair"
    (RepairPayload (RepairReport migrationIdentifier MarkApplied Failed Applied))

errorOutcome :: CliOutcome
errorOutcome =
  CliOutcome
    { command = "check",
      exitClass = ExitUsageFailed,
      payload = Left (CliManifestError EmptyManifest)
    }

successful :: Text -> CliPayload -> CliOutcome
successful command payload = CliOutcome {command, exitClass = ExitSuccess, payload = Right payload}

accounts :: ComponentName
accounts = expectRight (componentName "accounts")

migrationIdentifier :: MigrationId
migrationIdentifier = expectRight (migrationId "accounts" "0001")

emptyChecksum :: MigrationChecksum
emptyChecksum = migrationFingerprint ByteString.empty

fixtureStartedAt :: UTCTime
fixtureStartedAt = read "2026-07-10 12:00:00 UTC"

fixtureFinishedAt :: UTCTime
fixtureFinishedAt = read "2026-07-10 12:00:01 UTC"

importReport :: HistoryImportReport
importReport =
  HistoryImportReport
    ( HistoryImportResult migrationIdentifier Imported
        :| [HistoryImportResult (expectRight (migrationId "accounts" "0002")) AlreadyImported]
    )

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
