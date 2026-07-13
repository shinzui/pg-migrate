module Test.Parser (tests) where

import Data.ByteString.Char8 qualified as ByteString
import Data.Int (Int64)
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
      testCase "invalid lock keys fail in the parser" (assertLockFailure "nope"),
      testCase "accepts 0x7FFFFFFFFFFFFFFF" (lockKeyFor "0x7FFFFFFFFFFFFFFF" @?= maxBound),
      testCase "accepts negative decimal advisory-lock keys" (lockKeyFor "-1" @?= -1),
      testCase "rejects 0x8000000000000000" (assertLockFailure "0x8000000000000000"),
      testCase "rejects 0xFFFFFFFFFFFFFFFF (wrap guard)" (assertLockFailure "0xFFFFFFFFFFFFFFFF"),
      testCase "rejects out-of-range decimal" (assertLockFailure "18446744073709551615")
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

lockKeyFor :: String -> Int64
lockKeyFor input = lockKey (parseSuccess ["--source-lock-key", input, "--mapping", "map.json"])

assertLockFailure :: String -> Assertion
assertLockFailure input =
  case execParserPure defaultPrefs commandInfo ["--source-lock-key", input, "--mapping", "map.json"] of
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
