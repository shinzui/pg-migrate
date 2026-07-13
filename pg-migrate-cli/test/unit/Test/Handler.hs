module Test.Handler (tests) where

import Control.Exception qualified as Exception
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI
import Database.PostgreSQL.Migrate.Embed
  ( AuthoringError (..),
    ManifestError (..),
  )
import Hasql.Connection.Settings qualified as Settings
import System.Directory qualified as Directory
import System.FilePath ((</>))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "handler"
    [ testCase "plan text is stable and preserves component order" testPlanText,
      testCase "list filters narrow output without changing plan order" testListFilter,
      testCase "check returns exact-byte checksums" testCheck,
      testCase "new creates and appends a migration without applying it" testNew,
      testCase "new rejects control characters before writing files" testNewRejectsControlCharacters,
      testCase "new reports when a nonnumeric manifest requires an explicit name" testNewRequiresName,
      testCase "manifest IO failures are typed execution outcomes" testCheckIoFailure,
      testCase "manifest validation failures remain typed usage outcomes" testCheckValidationFailure,
      testCase "new classifies manifest IO failures as execution outcomes" testNewManifestIoFailure
    ]

testPlanText :: Assertion
testPlanText = do
  outcome <-
    runMigrationCommand
      fixtureEnvironment
      (Plan (PlanOptions noInspection textOutput))
  exitClass outcome @?= ExitSuccess
  renderMigrationCommandText outcome
    @?= Text.unlines
      [ "1. accounts depends=[] migrations=1",
        "2. billing depends=[accounts] migrations=1"
      ]

testListFilter :: Assertion
testListFilter = do
  let billing = expectRight (componentName "billing")
  outcome <-
    runMigrationCommand
      fixtureEnvironment
      (List (ListOptions (InspectionOptions (Just billing) Nothing) textOutput))
  exitClass outcome @?= ExitSuccess
  let rendered = renderMigrationCommandText outcome
  assertBool "billing migration is present" ("billing/0001" `Text.isInfixOf` rendered)
  assertBool "accounts migration is filtered out" (not ("accounts/0001" `Text.isInfixOf` rendered))
  assertBool "checksums are lowercase hexadecimal" (Text.all validOutputCharacter rendered)
  where
    validOutputCharacter character = not (character >= 'A' && character <= 'F')

testCheck :: Assertion
testCheck =
  withFixtureDirectory "check" $ \directory -> do
    let manifest = directory </> "manifest"
    ByteString.writeFile (directory </> "0001.sql") "SELECT 1;\n"
    ByteString.writeFile manifest "0001.sql\n"
    outcome <-
      runMigrationCommand
        fixtureEnvironment
        (Check (CheckOptions manifest textOutput))
    exitClass outcome @?= ExitSuccess
    let rendered = renderMigrationCommandText outcome
    assertBool "manifest entry is rendered" ("0001.sql checksum=" `Text.isPrefixOf` rendered)
    Text.length (Text.takeWhileEnd (/= '=') (Text.strip rendered)) @?= 64

testNew :: Assertion
testNew =
  withFixtureDirectory "new" $ \directory -> do
    let manifest = directory </> "manifest"
    ByteString.writeFile (directory </> "0001.sql") "SELECT 1;\n"
    ByteString.writeFile manifest "0001.sql\n"
    outcome <-
      runMigrationCommand
        fixtureEnvironment
        (New (NewOptions manifest "add profile" Nothing textOutput))
    exitClass outcome @?= ExitSuccess
    renderMigrationCommandText outcome @?= "created " <> Text.pack (directory </> "0002.sql") <> "\n"
    ByteString.readFile (directory </> "0002.sql") >>= (@?= "-- add profile\n\n")
    ByteString.readFile manifest >>= (@?= "0001.sql\n0002.sql\n")

testNewRejectsControlCharacters :: Assertion
testNewRejectsControlCharacters =
  withFixtureDirectory "new-description" $ \directory -> do
    let manifest = directory </> "manifest"
    ByteString.writeFile (directory </> "0001.sql") "SELECT 1;\n"
    ByteString.writeFile manifest "0001.sql\n"
    outcome <-
      runMigrationCommand
        fixtureEnvironment
        (New (NewOptions manifest "add profile\nDROP TABLE accounts" Nothing textOutput))
    exitClass outcome @?= ExitUsageFailed
    case payload outcome of
      Left (CliInputError message) -> assertBool "diagnostic names the newline" ("\\n" `Text.isInfixOf` message)
      result -> assertFailure ("expected typed description error, received: " <> show result)
    Directory.doesFileExist (directory </> "0002.sql") >>= (@?= False)
    ByteString.readFile manifest >>= (@?= "0001.sql\n")

testCheckIoFailure :: Assertion
testCheckIoFailure =
  withFixtureDirectory "missing" $ \directory -> do
    outcome <-
      runMigrationCommand
        fixtureEnvironment
        (Check (CheckOptions (directory </> "missing-manifest") textOutput))
    exitClass outcome @?= ExitExecutionFailed
    case payload outcome of
      Left (CliManifestError ManifestIoError {}) -> pure ()
      result -> assertFailure ("expected typed manifest IO error, received: " <> show result)

testCheckValidationFailure :: Assertion
testCheckValidationFailure =
  withFixtureDirectory "invalid-manifest" $ \directory -> do
    let manifest = directory </> "manifest"
    ByteString.writeFile manifest ""
    outcome <-
      runMigrationCommand
        fixtureEnvironment
        (Check (CheckOptions manifest textOutput))
    exitClass outcome @?= ExitUsageFailed
    case payload outcome of
      Left (CliManifestError EmptyManifest) -> pure ()
      result -> assertFailure ("expected typed manifest validation error, received: " <> show result)

testNewManifestIoFailure :: Assertion
testNewManifestIoFailure =
  withFixtureDirectory "new-missing-manifest" $ \directory -> do
    outcome <-
      runMigrationCommand
        fixtureEnvironment
        (New (NewOptions (directory </> "missing-manifest") "add profile" Nothing textOutput))
    exitClass outcome @?= ExitExecutionFailed
    case payload outcome of
      Left (CliAuthoringError (AuthoringManifestError ManifestIoError {})) -> pure ()
      result -> assertFailure ("expected typed authoring manifest IO error, received: " <> show result)

testNewRequiresName :: Assertion
testNewRequiresName =
  withFixtureDirectory "new-name" $ \directory -> do
    let manifest = directory </> "manifest"
    ByteString.writeFile (directory </> "baseline.sql") "SELECT 1;\n"
    ByteString.writeFile manifest "baseline.sql\n"
    outcome <-
      runMigrationCommand
        fixtureEnvironment
        (New (NewOptions manifest "add profile" Nothing textOutput))
    exitClass outcome @?= ExitUsageFailed
    case payload outcome of
      Left (CliAuthoringError ExplicitMigrationNameRequired) -> pure ()
      result -> assertFailure ("expected explicit-name usage error, received: " <> show result)

fixtureEnvironment :: CliEnvironment
fixtureEnvironment = cliEnvironment (Settings.connectionString "") fixturePlan defaultRunOptions

fixturePlan :: MigrationPlan
fixturePlan =
  expectRight
    ( migrationPlan
        ( expectRight
            ( migrationComponent
                "accounts"
                Set.empty
                (expectRight (sqlMigration "0001" "SELECT 1") :| [])
            )
            :| [ expectRight
                   ( migrationComponent
                       "billing"
                       (Set.singleton "accounts")
                       (expectRight (sqlMigration "0001" "SELECT 2") :| [])
                   )
               ]
        )
    )

noInspection :: InspectionOptions
noInspection = InspectionOptions Nothing Nothing

textOutput :: OutputOptions
textOutput = OutputOptions TextOutput

withFixtureDirectory :: String -> (FilePath -> IO value) -> IO value
withFixtureDirectory label = Exception.bracket create Directory.removePathForcibly
  where
    create = do
      temporaryDirectory <- Directory.getTemporaryDirectory
      let directory = temporaryDirectory </> ("pg-migrate-cli-" <> label)
      Directory.removePathForcibly directory
      Directory.createDirectory directory
      pure directory

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
