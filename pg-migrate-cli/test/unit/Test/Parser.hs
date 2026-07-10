module Test.Parser (tests) where

import Data.ByteString.Char8 qualified as ByteString
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI
import Options.Applicative
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "parser"
    [ testCase "top-level help groups commands by operator intent" testGroupedHelp,
      testCase "verify help defines ledger verification narrowly" testVerifyHelp,
      testCase "up has no selective execution filters" testUpRejectsFilters,
      testCase "durations must be positive integer milliseconds" testDurationValidation,
      testCase "lock wait flags conflict" testConflictingWaitFlags,
      testCase "repair requires an operation and confirmation" testRepairConfirmation,
      testCase "repair validates the component/migration target" testRepairTarget,
      testCase "parsing does not imply database settings" testNoImplicitDatabaseSettings
    ]

testGroupedHelp :: Assertion
testGroupedHelp = do
  helpText <- parseFailure ["--help"]
  assertContains "Inspection" helpText
  assertContains "plan" helpText
  assertContains "status" helpText
  assertContains "verify" helpText
  assertContains "list" helpText
  assertContains "check" helpText
  assertContains "Execution" helpText
  assertContains "up" helpText
  assertContains "repair" helpText
  assertContains "Authoring" helpText
  assertContains "new" helpText

testVerifyHelp :: Assertion
testVerifyHelp = do
  helpText <- parseFailure ["verify", "--help"]
  assertContains "declared plan" helpText
  assertContains "migration ledger" helpText
  assertContains "not live schema" helpText
  assertContains "snapshots" helpText
  assertContains "Connection" helpText
  assertContains "Output" helpText

testUpRejectsFilters :: Assertion
testUpRejectsFilters = do
  failure <- parseFailure ["up", "--component", "accounts"]
  assertContains "Invalid option" failure

testDurationValidation :: Assertion
testDurationValidation = do
  zeroFailure <- parseFailure ["up", "--lock-timeout", "0"]
  assertContains "positive integer" zeroFailure
  fractionalFailure <- parseFailure ["up", "--statement-timeout", "1.5"]
  assertContains "positive integer" fractionalFailure

testConflictingWaitFlags :: Assertion
testConflictingWaitFlags = do
  failure <- parseFailure ["up", "--no-wait", "--lock-timeout", "100"]
  assertContains "Invalid option" failure

testRepairConfirmation :: Assertion
testRepairConfirmation = do
  missingOperation <- parseFailure ["repair", "accounts/0001", "--reason", "inspected", "--confirm"]
  assertContains "mark-applied" missingOperation
  missingConfirmation <- parseFailure ["repair", "accounts/0001", "--mark-applied", "--reason", "inspected"]
  assertContains "confirm" missingConfirmation

testRepairTarget :: Assertion
testRepairTarget = do
  failure <- parseFailure ["repair", "accounts", "--mark-applied", "--reason", "inspected", "--confirm"]
  assertContains "COMPONENT/MIGRATION" failure

testNoImplicitDatabaseSettings :: Assertion
testNoImplicitDatabaseSettings =
  case parseSuccess ["status"] of
    Status StatusOptions {connection = ConnectionOptions {databaseSettings = Nothing}} -> pure ()
    result -> assertFailure ("expected status without database settings, received: " <> show result)

commandInfo :: ParserInfo MigrationCommand
commandInfo =
  info
    (migrationCommandParser fixturePlan <**> helper)
    (fullDesc <> progDesc "Test pg-migrate consumer")

parseSuccess :: [String] -> MigrationCommand
parseSuccess arguments =
  case execParserPure defaultPrefs commandInfo arguments of
    Success parsedCommand -> parsedCommand
    Failure failure ->
      let (message, _) = renderFailure failure "test-migrate"
       in error message
    CompletionInvoked _ -> error "unexpected completion"

parseFailure :: [String] -> IO String
parseFailure arguments =
  case execParserPure defaultPrefs commandInfo arguments of
    Failure failure -> pure (fst (renderFailure failure "test-migrate"))
    Success parsedCommand -> assertFailure ("expected parser failure, received: " <> show parsedCommand)
    CompletionInvoked _ -> assertFailure "expected parser failure, received completion"

assertContains :: String -> String -> Assertion
assertContains needle haystack =
  assertBool ("expected output to contain " <> show needle <> ", received:\n" <> haystack) (needle `isInfixOf` haystack)

fixturePlan :: MigrationPlan
fixturePlan =
  expectRight
    ( migrationPlan
        ( expectRight
            ( migrationComponent
                "accounts"
                Set.empty
                (expectRight (sqlMigration "0001" (ByteString.pack "SELECT 1")) :| [])
            )
            :| []
        )
    )

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
