module Main (main) where

import Control.Exception qualified as Exception
import Data.Int (Int32)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Test
import EphemeralPg.Config qualified as EphemeralPg.Config
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main =
  defaultMain
    ( testGroup
        "pg-migrate test support"
        [ testCase "plan is migrated before a fresh callback connection" testMigratedDatabase,
          testCase "migration failures are structurally distinct" testMigrationFailure,
          testCase "callback failures are structurally distinct" testCallbackFailure,
          testCase "startup failures are structurally distinct" testStartupFailure
        ]
    )

testMigratedDatabase :: Assertion
testMigratedDatabase = do
  result <-
    withMigratedDatabase fixturePlan $ \connection ->
      Connection.use connection (Session.statement () processIdsStatement)
  case result of
    Right (Right (migrationPid, callbackPid)) ->
      assertBool "callback reused the migration connection" (migrationPid /= callbackPid)
    other -> assertFailure ("unexpected migrated database result: " <> show other)

testMigrationFailure :: Assertion
testMigrationFailure = do
  result <- withMigratedDatabase failingPlan (const (pure ()))
  case result of
    Left MigratedDatabaseMigrationFailed {} -> pure ()
    other -> assertFailure ("expected migration failure, received: " <> show other)

testCallbackFailure :: Assertion
testCallbackFailure = do
  result <- withMigratedDatabase fixturePlan (const (Exception.throwIO (userError "callback failed") :: IO ()))
  case result of
    Left MigratedDatabaseCallbackFailed {} -> pure ()
    other -> assertFailure ("expected callback failure, received: " <> show other)

testStartupFailure :: Assertion
testStartupFailure = do
  let invalidConfig = EphemeralPg.Config.defaultConfig {EphemeralPg.Config.initDbArgs = ["--definitely-invalid-initdb-option"]}
  result <- withMigratedDatabaseConfig invalidConfig defaultRunOptions fixturePlan (const (pure ()))
  case result of
    Left MigratedDatabaseStartupFailed {} -> pure ()
    other -> assertFailure ("expected startup failure, received: " <> show other)

fixturePlan :: MigrationPlan
fixturePlan =
  expectRight
    ( migrationPlan
        ( expectRight
            ( migrationComponent
                "test-support"
                Set.empty
                ( expectRight
                    ( sqlMigration
                        "0001-process"
                        "CREATE TABLE callback_probe AS SELECT pg_backend_pid()::int4 AS migration_pid"
                    )
                    :| []
                )
            )
            :| []
        )
    )

failingPlan :: MigrationPlan
failingPlan =
  expectRight
    ( migrationPlan
        ( expectRight
            (migrationComponent "test-support-failure" Set.empty (expectRight (sqlMigration "0001-fail" "SELECT * FROM deliberately_missing_relation") :| []))
            :| []
        )
    )

processIdsStatement :: Statement () (Int32, Int32)
processIdsStatement =
  Statement.preparable
    "SELECT migration_pid, pg_backend_pid()::int4 FROM callback_probe"
    Encoders.noParams
    (Decoders.singleRow ((,) <$> required Decoders.int4 <*> required Decoders.int4))
  where
    required = Decoders.column . Decoders.nonNullable

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
