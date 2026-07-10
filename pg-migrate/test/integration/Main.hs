module Main (main) where

import Control.Exception (bracket, finally)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Internal
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

main :: IO ()
main = do
  maybeConnectionString <- lookupEnv "PG_CONNECTION_STRING"
  case maybeConnectionString of
    Nothing ->
      putStrLn
        "pg-migrate integration tests skipped: PG_CONNECTION_STRING is not set"
    Just connectionString ->
      defaultMain (tests (Settings.connectionString (Text.pack connectionString)))

tests :: Settings.Settings -> TestTree
tests settings =
  testGroup
    "pg-migrate PostgreSQL ledger"
    [ testCase "installation is complete, constrained, and idempotent" (testInstallation settings),
      testCase "quoted custom schemas are safe" (testQuotedSchema settings),
      testCase "read-only loading leaves a missing ledger missing" (testMissingReadOnly settings),
      testCase "a future schema version is refused without mutation" (testFutureVersion settings)
    ]

testInstallation :: Settings.Settings -> IO ()
testInstallation settings =
  withTestLedger settings "install" $ \connection config -> do
    initialize connection config >>= (@?= Right ())
    initialize connection config >>= (@?= Right ())
    snapshot <- useSession connection (loadLedger config)
    case snapshot of
      LedgerSnapshot
        { metadata =
            Just
              LedgerMetadata
                { schemaVersion,
                  runnerVersion
                },
          storedMigrations = []
        } -> do
          schemaVersion @?= currentLedgerVersion
          runnerVersion @?= integrationRunnerVersion
      other -> assertFailure ("unexpected initialized snapshot: " <> show other)
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    tableNames
      @?= ["history_imports", "ledger_metadata", "migrations", "repairs"]
    mapM_ (assertConstraintRejects connection config) invalidMigrationRows
    migrationCount <- useSession connection (Session.statement () (migrationCountStatement config))
    migrationCount @?= 0

testQuotedSchema :: Settings.Settings -> IO ()
testQuotedSchema settings =
  withTestLedgerNamed settings (\suffix -> "application \"migrations\" " <> suffix) $ \connection config -> do
    initialize connection config >>= (@?= Right ())
    snapshot <- useSession connection (loadLedger config)
    case snapshot of
      LedgerSnapshot {metadata = Just LedgerMetadata {schemaVersion}} ->
        schemaVersion @?= currentLedgerVersion
      other -> assertFailure ("unexpected quoted-schema snapshot: " <> show other)

testMissingReadOnly :: Settings.Settings -> IO ()
testMissingReadOnly settings =
  withTestLedger settings "missing" $ \connection config -> do
    snapshot <- useSession connection (loadLedger config)
    snapshot @?= LedgerSnapshot {metadata = Nothing, storedMigrations = []}
    case statusFromSnapshot integrationPlan snapshot of
      StatusReport {issues, appliedMigrations, pendingMigrations, unknownMigrations} -> do
        issues @?= []
        appliedMigrations @?= []
        length pendingMigrations @?= 1
        unknownMigrations @?= []
    tableNames <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    tableNames @?= []

testFutureVersion :: Settings.Settings -> IO ()
testFutureVersion settings =
  withTestLedger settings "future" $ \connection config -> do
    initialize connection config >>= (@?= Right ())
    tableNamesBefore <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    useSession connection (Session.script (setFutureVersionSql config))
    initialize connection config
      >>= ( @?=
              Left
                LedgerTooNew
                  { databaseVersion = currentLedgerVersion + 1,
                    supportedVersion = currentLedgerVersion
                  }
          )
    tableNamesAfter <- useSession connection (Session.statement (ledgerSchema config) tableNamesStatement)
    tableNamesAfter @?= tableNamesBefore
    snapshot <- useSession connection (loadLedger config)
    case snapshot of
      LedgerSnapshot {metadata = Just LedgerMetadata {schemaVersion}} ->
        schemaVersion @?= currentLedgerVersion + 1
      other -> assertFailure ("unexpected future-version snapshot: " <> show other)

withTestLedger ::
  Settings.Settings ->
  Text ->
  (Connection.Connection -> LedgerConfig -> IO a) ->
  IO a
withTestLedger settings label action =
  withTestLedgerNamed settings (\suffix -> "pgmigrate_test_" <> label <> "_" <> suffix) action

withTestLedgerNamed ::
  Settings.Settings ->
  (Text -> Text) ->
  (Connection.Connection -> LedgerConfig -> IO a) ->
  IO a
withTestLedgerNamed settings makeSchema action = do
  suffix <- uniqueSuffix
  let config = requireRight (ledgerConfig (makeSchema suffix) testLockKey)
  withConnection settings $ \connection -> do
    cleanupLedger connection config
    action connection config `finally` cleanupLedger connection config

withConnection :: Settings.Settings -> (Connection.Connection -> IO a) -> IO a
withConnection settings action = do
  acquired <- Connection.acquire settings
  case acquired of
    Left connectionError ->
      assertFailure ("failed to acquire PostgreSQL integration connection: " <> show connectionError)
        >> error "assertFailure returned"
    Right connection -> bracket (pure connection) Connection.release action

initialize :: Connection.Connection -> LedgerConfig -> IO (Either LedgerError ())
initialize connection config =
  useSession connection (initializeOrUpgradeLedger config integrationRunnerVersion)

useSession :: Connection.Connection -> Session a -> IO a
useSession connection session = do
  result <- Connection.use connection session
  case result of
    Left sessionError ->
      assertFailure ("PostgreSQL session failed: " <> show sessionError)
        >> error "assertFailure returned"
    Right value -> pure value

assertConstraintRejects :: Connection.Connection -> LedgerConfig -> Text -> IO ()
assertConstraintRejects connection config values = do
  result <- Connection.use connection (Session.script (invalidInsertSql config values))
  assertBool ("expected constraint failure for values: " <> Text.unpack values) (isLeft result)

cleanupLedger :: Connection.Connection -> LedgerConfig -> IO ()
cleanupLedger connection config =
  useSession
    connection
    (Session.script ("DROP SCHEMA IF EXISTS " <> quotedSchema config <> " CASCADE"))

invalidInsertSql :: LedgerConfig -> Text -> Text
invalidInsertSql config values =
  Text.unwords
    [ "INSERT INTO",
      qualifiedMigrationsTable config,
      "(component, migration, position, checksum, kind, transaction_mode, status,",
      "started_at, finished_at, execution_time_ms, error, runner_version)",
      "VALUES",
      values
    ]

invalidMigrationRows :: [Text]
invalidMigrationRows =
  [ "('owner', 'bad-position', 0, decode(repeat('00', 32), 'hex'), 'sql', 'transactional', 'applied', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'bad-checksum', 1, decode('00', 'hex'), 'sql', 'transactional', 'applied', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'bad-kind', 1, decode(repeat('00', 32), 'hex'), 'other', 'transactional', 'applied', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'bad-mode', 1, decode(repeat('00', 32), 'hex'), 'sql', 'other', 'applied', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'bad-status', 1, decode(repeat('00', 32), 'hex'), 'sql', 'transactional', 'other', clock_timestamp(), clock_timestamp(), 0, NULL, 'test')",
    "('owner', 'transactional-running', 1, decode(repeat('00', 32), 'hex'), 'sql', 'transactional', 'running', clock_timestamp(), NULL, NULL, NULL, 'test')",
    "('owner', 'bad-status-shape', 1, decode(repeat('00', 32), 'hex'), 'sql', 'transactional', 'applied', clock_timestamp(), NULL, 0, NULL, 'test')"
  ]

tableNamesStatement :: Statement.Statement Text [Text]
tableNamesStatement =
  Statement.preparable
    """
    SELECT table_name::text
    FROM information_schema.tables
    WHERE table_schema = $1
    ORDER BY table_name
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

migrationCountStatement :: LedgerConfig -> Statement.Statement () Int64
migrationCountStatement config =
  Statement.unpreparable
    ("SELECT count(*) FROM " <> qualifiedMigrationsTable config)
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))

setFutureVersionSql :: LedgerConfig -> Text
setFutureVersionSql config =
  "UPDATE "
    <> quotedSchema config
    <> ".\"ledger_metadata\" SET schema_version = "
    <> Text.pack (show (currentLedgerVersion + 1))

qualifiedMigrationsTable :: LedgerConfig -> Text
qualifiedMigrationsTable config = quotedSchema config <> ".\"migrations\""

quotedSchema :: LedgerConfig -> Text
quotedSchema config = quotePostgresIdentifier (PostgresIdentifier (ledgerSchemaText config))

ledgerSchema :: LedgerConfig -> Text
ledgerSchema = ledgerSchemaText

integrationPlan :: MigrationPlan
integrationPlan =
  requireRight
    ( migrationPlan
        ( requireRight
            ( migrationComponent
                "integration"
                Set.empty
                (requireRight (sqlMigration "0001" "SELECT 1") :| [])
            )
            :| []
        )
    )

uniqueSuffix :: IO Text
uniqueSuffix = do
  now <- getPOSIXTime
  pure (Text.pack (show (floor (realToFrac now * (1000000 :: Double)) :: Integer)))

requireRight :: (Show error) => Either error value -> value
requireRight = \case
  Left err -> error (show err)
  Right value -> value

isLeft :: Either left right -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

integrationRunnerVersion :: Text
integrationRunnerVersion = "pg-migrate-integration"

testLockKey :: Int64
testLockKey = 0x70675F6D74657374
