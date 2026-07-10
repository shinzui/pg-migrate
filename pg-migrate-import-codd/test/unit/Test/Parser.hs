module Test.Parser (tests) where

import Data.ByteString.Char8 qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI (OutputFormat (JsonOutput))
import Database.PostgreSQL.Migrate.History.Codd
import Options.Applicative
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "parser"
    [ testCase "parser records explicit artifacts without reading them" testCommand,
      testCase "invalid lock keys fail in the parser" testInvalidLock
    ]

testCommand :: Assertion
testCommand =
  case parseSuccess
    [ "--source-lock-key",
      "0x6B69726F6B754D67",
      "--mapping",
      "codd-mapping.json",
      "--manifest",
      "migrations.lock",
      "--source-directory",
      "migrations",
      "--strict-source",
      "--confirm",
      "--json"
    ] of
    CoddImportCommand
      { lockKey,
        mappingPath,
        manifestPath,
        sourceDirectory,
        strict,
        confirmation,
        outputFormat
      } -> do
        lockKey @?= defaultCoddLockKey
        mappingPath @?= "codd-mapping.json"
        manifestPath @?= Just "migrations.lock"
        sourceDirectory @?= Just "migrations"
        strict @?= True
        confirmation @?= Confirmed
        outputFormat @?= JsonOutput

testInvalidLock :: Assertion
testInvalidLock =
  case execParserPure defaultPrefs commandInfo ["--source-lock-key", "nope", "--mapping", "map.json"] of
    Failure _ -> pure ()
    result -> assertFailure ("expected parser failure, received: " <> show result)

parseSuccess :: [String] -> CoddImportCommand
parseSuccess arguments =
  case execParserPure defaultPrefs commandInfo arguments of
    Success parsedCommand -> parsedCommand
    Failure failure -> error (fst (renderFailure failure "codd-import"))
    CompletionInvoked _ -> error "unexpected completion"

commandInfo :: ParserInfo CoddImportCommand
commandInfo = info (coddImportCommandParser fixturePlan <**> helper) fullDesc

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
