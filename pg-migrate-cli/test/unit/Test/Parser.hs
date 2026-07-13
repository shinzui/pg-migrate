module Test.Parser (tests) where

import Data.ByteString.Char8 qualified as ByteString
import Data.Foldable (traverse_)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI
import Options.Applicative
import Paths_pg_migrate_cli qualified as Paths
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
      testCase "absent execution flags preserve application options" testAbsentExecutionOverrides,
      testCase "lock wait flags produce explicit overrides" testLockWaitOverrides,
      testCase "statement timeout flags produce explicit overrides" testStatementTimeoutOverrides,
      testCase "description rejects control characters" testDescriptionValidation,
      testCase "repair requires an operation and confirmation" testRepairConfirmation,
      testCase "repair validates the component/migration target" testRepairTarget,
      testCase "parsing does not imply database settings" testNoImplicitDatabaseSettings,
      testCase "plain completion derives all commands from the parser" testPlainCompletion,
      testCase "enriched completion derives execution flags and descriptions" testEnrichedCompletion,
      testGroup "help goldens" (uncurry goldenHelpCase <$> helpGoldens)
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
  statementFailure <- parseFailure ["up", "--statement-timeout", "100", "--no-statement-timeout"]
  assertContains "Invalid option" statementFailure

testAbsentExecutionOverrides :: Assertion
testAbsentExecutionOverrides =
  parsedExecution [] @?= ExecutionOptions Nothing Nothing

testLockWaitOverrides :: Assertion
testLockWaitOverrides = do
  parsedExecution ["--no-wait"] @?= ExecutionOptions (Just NoWait) Nothing
  parsedExecution ["--lock-timeout", "250"] @?= ExecutionOptions (Just (WaitFor 0.25)) Nothing
  parsedExecution ["--wait"] @?= ExecutionOptions (Just WaitIndefinitely) Nothing

testStatementTimeoutOverrides :: Assertion
testStatementTimeoutOverrides = do
  parsedExecution ["--statement-timeout", "250"] @?= ExecutionOptions Nothing (Just (Just 0.25))
  parsedExecution ["--no-statement-timeout"] @?= ExecutionOptions Nothing (Just Nothing)

testDescriptionValidation :: Assertion
testDescriptionValidation = do
  failure <- parseFailure ["new", "--manifest", "manifest", "--description", "add profile\nDROP TABLE accounts"]
  assertContains "--description" failure
  assertContains "\\n" failure

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

testPlainCompletion :: Assertion
testPlainCompletion = do
  completion <- completionOutput False 0 []
  traverse_ (\commandName -> assertContains commandName completion) expectedCommands

testEnrichedCompletion :: Assertion
testEnrichedCompletion = do
  commands <- completionOutput True 0 []
  assertContains "verify\tStrictly compare" commands
  flags <- completionOutput True 2 ["test-migrate", "up"]
  assertContains "--database-url\tPostgreSQL URI" flags
  assertContains "--lock-timeout\tWait at most" flags
  assertContains "--no-wait\tFail immediately" flags
  assertContains "--wait\tWait indefinitely" flags
  assertContains "--statement-timeout\tSet a positive PostgreSQL" flags
  assertContains "--no-statement-timeout\tRun without" flags
  assertContains "--json\tEmit JSON schema version 1" flags

completionOutput :: Bool -> Int -> [String] -> IO String
completionOutput enriched index wordsBeforeCursor =
  case execParserPure defaultPrefs commandInfo arguments of
    CompletionInvoked completion -> execCompletion completion "test-migrate"
    Failure failure -> assertFailure (fst (renderFailure failure "test-migrate"))
    Success parsedCommand -> assertFailure ("expected completion, received command: " <> show parsedCommand)
  where
    arguments =
      ["--bash-completion-enriched" | enriched]
        <> ["--bash-completion-index", show index]
        <> concatMap (\word -> ["--bash-completion-word", word]) wordsBeforeCursor

expectedCommands :: [String]
expectedCommands = ["plan", "status", "verify", "list", "check", "up", "repair", "new"]

goldenHelpCase :: FilePath -> [String] -> TestTree
goldenHelpCase name arguments =
  testCase name $ do
    goldenPath <- Paths.getDataFileName ("test/golden/help/" <> name <> ".txt")
    expected <- readFile goldenPath
    actual <- parseFailure (arguments <> ["--help"])
    normalizeHelp actual @?= expected

normalizeHelp :: String -> String
normalizeHelp = unlines . fmap (reverse . dropWhile (== ' ') . reverse) . lines

helpGoldens :: [(FilePath, [String])]
helpGoldens =
  [ ("top", []),
    ("plan", ["plan"]),
    ("status", ["status"]),
    ("verify", ["verify"]),
    ("list", ["list"]),
    ("check", ["check"]),
    ("up", ["up"]),
    ("repair", ["repair"]),
    ("new", ["new"])
  ]

commandInfo :: ParserInfo MigrationCommand
commandInfo =
  info
    (migrationCommandParser fixturePlan <**> helper)
    (fullDesc <> progDesc "Manage the fixture service migration plan")

parseSuccess :: [String] -> MigrationCommand
parseSuccess arguments =
  case execParserPure defaultPrefs commandInfo arguments of
    Success parsedCommand -> parsedCommand
    Failure failure ->
      let (message, _) = renderFailure failure "pg-migrate-cli-help-fixture"
       in error message
    CompletionInvoked _ -> error "unexpected completion"

parsedExecution :: [String] -> ExecutionOptions
parsedExecution arguments =
  case parseSuccess ("up" : arguments) of
    Up UpOptions {execution} -> execution
    parsedCommand -> error ("expected up command, received: " <> show parsedCommand)

parseFailure :: [String] -> IO String
parseFailure arguments =
  case execParserPure defaultPrefs commandInfo arguments of
    Failure failure -> pure (fst (renderFailure failure "pg-migrate-cli-help-fixture"))
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
