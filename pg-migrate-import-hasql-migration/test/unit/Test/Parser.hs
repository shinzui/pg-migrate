module Test.Parser (tests) where

import Data.ByteString.Char8 qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI (OutputFormat (JsonOutput))
import Database.PostgreSQL.Migrate.History.HasqlMigration
import Options.Applicative
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "parser"
    [ testCase "parser records explicit artifacts without reading them" testCommand,
      testCase "invalid qualified tables fail in the parser" testInvalidTable
    ]

testCommand :: Assertion
testCommand =
  case parseSuccess ["--source-table", "legacy.history", "--mapping", "mapping.json", "--source-directory", "migrations", "--strict-source", "--allow-equivalent", "--json"] of
    HasqlMigrationImportCommand {mappingPath, sourceDirectory, strict, allowEquivalent, outputFormat} -> do
      mappingPath @?= "mapping.json"
      sourceDirectory @?= "migrations"
      strict @?= True
      allowEquivalent @?= True
      outputFormat @?= JsonOutput

testInvalidTable :: Assertion
testInvalidTable =
  case execParserPure defaultPrefs commandInfo ["--source-table", "missing-dot", "--mapping", "map.json", "--source-directory", "migrations"] of
    Failure _ -> pure ()
    result -> assertFailure ("expected parser failure, received: " <> show result)

parseSuccess :: [String] -> HasqlMigrationImportCommand
parseSuccess arguments =
  case execParserPure defaultPrefs commandInfo arguments of
    Success parsedCommand -> parsedCommand
    Failure failure -> error (fst (renderFailure failure "hasql-migration-import"))
    CompletionInvoked _ -> error "unexpected completion"

commandInfo :: ParserInfo HasqlMigrationImportCommand
commandInfo = info (hasqlMigrationImportCommandParser fixturePlan <**> helper) fullDesc

fixturePlan :: MigrationPlan
fixturePlan =
  expectRight
    ( migrationPlan
        (expectRight (migrationComponent "target" Set.empty (expectRight (sqlMigration "0001" (ByteString.pack "SELECT 1")) :| [])) :| [])
    )

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
