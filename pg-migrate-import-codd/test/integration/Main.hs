module Main (main) where

import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.Codd
import Database.PostgreSQL.Migrate.Internal (migrationChecksumBytes)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Numeric qualified
import System.Environment (lookupEnv)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = do
  maybeConnectionString <- lookupEnv "PG_CONNECTION_STRING"
  case maybeConnectionString of
    Nothing -> putStrLn "pg-migrate-import-codd integration tests skipped: PG_CONNECTION_STRING is not set"
    Just connectionString ->
      defaultMain (tests (Settings.connectionString (Text.pack connectionString)))

tests :: Settings.Settings -> TestTree
tests settings =
  testGroup
    "Codd adapter PostgreSQL"
    [ testGroup
        "supported fixtures"
        [ testCase (show version <> " reads without source mutation") (testSupportedFixture settings version)
        | version <- [CoddV1, CoddV2, CoddV3, CoddV4, CoddV5]
        ],
      testCase "partial and duplicate rows are rejected" (testInvalidRows settings),
      testCase "lenient selection reports extras and strict selection rejects them" (testSelection settings),
      testCase "legacy lock contention prevents target acquisition" (testLockContention settings),
      testCase "strict source rejects a selected row omitted from the manifest" (testStrictManifestSymmetry settings),
      testCase "import is audited, action-free, source-preserving, and idempotent" (testImportLifecycle settings),
      testCase "source unlock failure preserves the committed import report" (testUnlockFailurePreservesImportReport settings),
      testCase "a partial manifest supports mixed payload and state evidence" (testMixedEvidenceImport settings)
    ]

testSupportedFixture :: Settings.Settings -> CoddSchemaVersion -> Assertion
testSupportedFixture settings version =
  withCleanSchemas settings $ do
    runScript settings (fixtureSql version <> appliedInsertSql version selectedFilename)
    before <- sourceSnapshot settings version
    history <- readCoddHistory (sourceConfig settings False (selectedFilename :| [])) >>= requireCoddRight
    schemaVersion history @?= version
    (filename <$> toList (selectedRows history)) @?= [selectedFilename]
    unselectedRows history @?= []
    afterSnapshot <- sourceSnapshot settings version
    afterSnapshot @?= before

testInvalidRows :: Settings.Settings -> Assertion
testInvalidRows settings = do
  withCleanSchemas settings $ do
    runScript settings (fixtureSql CoddV3 <> partialInsertSql "partial.sql")
    readCoddHistory (sourceConfig settings False ("partial.sql" :| []))
      >>= assertCoddError (\case CoddPartialMigration "partial.sql" -> True; _ -> False)
  withCleanSchemas settings $ do
    runScript settings (fixtureSql CoddV5 <> appliedInsertSql CoddV5 "duplicate.sql" <> appliedInsertSql CoddV5 "duplicate.sql")
    readCoddHistory (sourceConfig settings False ("duplicate.sql" :| []))
      >>= assertCoddError (\case CoddDuplicateLedgerFilename "duplicate.sql" -> True; _ -> False)

testSelection :: Settings.Settings -> Assertion
testSelection settings =
  withCleanSchemas settings $ do
    runScript settings (fixtureSql CoddV5 <> appliedInsertSql CoddV5 selectedFilename <> appliedInsertSql CoddV5 "unselected.sql")
    history <- readCoddHistory (sourceConfig settings False (selectedFilename :| [])) >>= requireCoddRight
    (filename <$> unselectedRows history) @?= ["unselected.sql"]
    readCoddHistory (sourceConfig settings True (selectedFilename :| []))
      >>= assertCoddError (\case CoddStrictSourceHasUnselected ["unselected.sql"] -> True; _ -> False)

testLockContention :: Settings.Settings -> Assertion
testLockContention settings =
  withCleanSchemas settings $ do
    runScript settings (fixtureSql CoddV5 <> appliedInsertSql CoddV5 selectedFilename)
    withConnection settings $ \holder -> do
      locked <- useSession holder (Session.statement defaultCoddLockKey tryLockStatement)
      locked @?= True
      result <- runImport settings
      assertCoddError (\case CoddLockUnavailable key -> key == defaultCoddLockKey; _ -> False) result
      targetExists <- useSession holder (Session.statement targetSchema targetSchemaExistsStatement)
      targetExists @?= False
      unlocked <- useSession holder (Session.statement defaultCoddLockKey unlockStatement)
      unlocked @?= True

testStrictManifestSymmetry :: Settings.Settings -> Assertion
testStrictManifestSymmetry settings =
  withCleanSchemas settings $ do
    runScript settings (fixtureSql CoddV5 <> appliedInsertSql CoddV5 selectedFilename)
    result <-
      importCoddHistory
        importOptions
        (strictMissingManifestConfig settings)
        (connectionProviderFromSettings settings)
        targetPlan
        (targetMapping :| [])
    assertCoddError (\case CoddManifestEntryMissing filename -> filename == selectedFilename; _ -> False) result

testImportLifecycle :: Settings.Settings -> Assertion
testImportLifecycle settings =
  withCleanSchemas settings $ do
    runScript settings (fixtureSql CoddV5 <> appliedInsertSql CoddV5 selectedFilename)
    before <- sourceSnapshot settings CoddV5
    first <- runImport settings >>= requireCoddRight
    importOutcomes first @?= [Imported]
    facts <- query settings targetFactsStatement
    facts @?= (1, 1, False, True, True)
    second <- runImport settings >>= requireCoddRight
    importOutcomes second @?= [AlreadyImported]
    repeatedFacts <- query settings targetFactsStatement
    repeatedFacts @?= facts
    afterSnapshot <- sourceSnapshot settings CoddV5
    afterSnapshot @?= before

testUnlockFailurePreservesImportReport :: Settings.Settings -> Assertion
testUnlockFailurePreservesImportReport settings =
  withCleanSchemas settings $ do
    runScript settings unlockingFixtureSql
    report <- runImport settings >>= requireCoddRight
    importOutcomes report @?= [Imported]
    let HistoryImportReport {cleanupIssues = observedCleanupIssues} = report
    observedCleanupIssues @?= [AdvisoryUnlockReturnedFalse]
    facts <- query settings targetFactsStatement
    facts @?= (1, 1, False, True, True)

testMixedEvidenceImport :: Settings.Settings -> Assertion
testMixedEvidenceImport settings =
  withCleanSchemas settings $ do
    runScript settings (fixtureSql CoddV5 <> appliedInsertSql CoddV5 mixedSameFilename <> appliedInsertSql CoddV5 mixedEquivalentFilename)
    first <- runMixedImport settings >>= requireCoddRight
    importOutcomes first @?= [Imported, Imported]
    facts <- query settings mixedTargetFactsStatement
    facts @?= (2, 2, False, False)
    second <- runMixedImport settings >>= requireCoddRight
    importOutcomes second @?= [AlreadyImported, AlreadyImported]

runMixedImport :: Settings.Settings -> IO (Either CoddImportError HistoryImportReport)
runMixedImport settings =
  importCoddHistoryWithValidators
    (withEquivalentHistory AllowEquivalentHistory importOptions)
    [mixedStateValidator]
    (mixedSourceConfig settings)
    (connectionProviderFromSettings settings)
    mixedTargetPlan
    mixedMappings

mixedSourceConfig :: Settings.Settings -> CoddSourceConfig
mixedSourceConfig settings =
  expectRight
    ( coddSourceConfig
        (connectionProviderFromSettings settings)
        (mixedSameFilename :| [mixedEquivalentFilename])
        False
        (Map.singleton mixedSameFilename mixedSamePayload)
        (Just mixedManifest)
        "verified mixed-evidence cutover"
        Confirmed
    )

mixedManifest :: CoddManifest
mixedManifest = expectRight (parseCoddManifest (checksumText mixedSamePayload <> " " <> Text.pack mixedSameFilename <> "\n"))

mixedMappings :: NonEmpty HistoryMapping
mixedMappings =
  historyMapping mixedSameTarget (Evidence mixedSameSourceKey) (SamePayload mixedSameSourceKey)
    :| [ historyMapping
           mixedEquivalentTarget
           (AllOf (Evidence mixedEquivalentSourceKey :| [Evidence mixedStateKey]))
           EquivalentState
       ]

mixedStateValidator :: StateValidator
mixedStateValidator = stateValidator mixedStateKey (pure (Right (Aeson.object ["state" Aeson..= ("verified" :: Text)])))

mixedStateKey :: EvidenceKey
mixedStateKey = expectRight (evidenceKey "codd:mixed-equivalent-state")

mixedSameSourceKey :: EvidenceKey
mixedSameSourceKey = expectRight (coddEvidenceKey mixedSameFilename)

mixedEquivalentSourceKey :: EvidenceKey
mixedEquivalentSourceKey = expectRight (coddEvidenceKey mixedEquivalentFilename)

mixedSameTarget :: MigrationId
mixedSameTarget = expectRight (migrationId "codd-target" "0001-mixed-same")

mixedEquivalentTarget :: MigrationId
mixedEquivalentTarget = expectRight (migrationId "codd-target" "0002-mixed-equivalent")

mixedTargetPlan :: MigrationPlan
mixedTargetPlan =
  expectRight
    ( migrationPlan
        ( expectRight
            ( migrationComponent
                "codd-target"
                Set.empty
                ( expectRight (sqlMigration "0001-mixed-same" mixedSamePayload)
                    :| [expectRight (sqlMigration "0002-mixed-equivalent" mixedEquivalentPayload)]
                )
            )
            :| []
        )
    )

mixedSameFilename, mixedEquivalentFilename :: FilePath
mixedSameFilename = "20240101000000-mixed-same.sql"
mixedEquivalentFilename = "20240101000001-mixed-equivalent.sql"

mixedSamePayload, mixedEquivalentPayload :: ByteString
mixedSamePayload = "CREATE TABLE pgmigrate_codd_target.mixed_same_should_not_exist (id bigint)"
mixedEquivalentPayload = "CREATE TABLE pgmigrate_codd_target.mixed_equivalent_should_not_exist (id bigint)"

runImport :: Settings.Settings -> IO (Either CoddImportError HistoryImportReport)
runImport settings =
  importCoddHistory
    importOptions
    (sourceConfigWithEvidence settings)
    (connectionProviderFromSettings settings)
    targetPlan
    (targetMapping :| [])

sourceConfig :: Settings.Settings -> Bool -> NonEmpty FilePath -> CoddSourceConfig
sourceConfig settings strict filenames =
  expectRight
    ( coddSourceConfig
        (connectionProviderFromSettings settings)
        filenames
        strict
        Map.empty
        Nothing
        "Codd fixture import"
        NotConfirmed
    )

sourceConfigWithEvidence :: Settings.Settings -> CoddSourceConfig
sourceConfigWithEvidence settings =
  expectRight
    ( coddSourceConfig
        (connectionProviderFromSettings settings)
        (selectedFilename :| [])
        False
        (Map.singleton selectedFilename targetPayload)
        (Just targetManifest)
        "verified Codd cutover"
        Confirmed
    )

strictMissingManifestConfig :: Settings.Settings -> CoddSourceConfig
strictMissingManifestConfig settings =
  expectRight
    ( coddSourceConfig
        (connectionProviderFromSettings settings)
        (selectedFilename :| [])
        True
        Map.empty
        (Just (expectRight (parseCoddManifest "")))
        "strict Codd cutover"
        Confirmed
    )

targetManifest :: CoddManifest
targetManifest = expectRight (parseCoddManifest (checksumText targetPayload <> " " <> Text.pack selectedFilename <> "\n"))

targetMapping :: HistoryMapping
targetMapping =
  historyMapping targetId (Evidence sourceKey) (SamePayload sourceKey)

sourceKey :: EvidenceKey
sourceKey = expectRight (coddEvidenceKey selectedFilename)

targetId :: MigrationId
targetId = expectRight (migrationId "codd-target" "0001-imported")

targetPlan :: MigrationPlan
targetPlan =
  expectRight
    ( migrationPlan
        (expectRight (migrationComponent "codd-target" Set.empty (expectRight (sqlMigration "0001-imported" targetPayload) :| [])) :| [])
    )

importOptions :: ImportOptions
importOptions =
  withImportRunOptions
    (withLedger (expectRight (ledgerConfig targetSchema 0x636F646454617267)) defaultRunOptions)
    defaultImportOptions

importOutcomes :: HistoryImportReport -> [HistoryImportOutcome]
importOutcomes HistoryImportReport {importResults} = importOutcome <$> toList importResults

sourceSnapshot :: Settings.Settings -> CoddSchemaVersion -> IO (Int64, [Text])
sourceSnapshot settings version = query settings (sourceSnapshotStatement (fixtureSchema version))

sourceSnapshotStatement :: Text -> Statement () (Int64, [Text])
sourceSnapshotStatement schemaName =
  Statement.unpreparable
    ( Text.unwords
        [ "SELECT (SELECT count(*) FROM " <> schemaName <> ".sql_migrations),",
          "ARRAY(SELECT a.attname::text FROM pg_catalog.pg_attribute a",
          "JOIN pg_catalog.pg_class c ON a.attrelid = c.oid",
          "JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid",
          "WHERE c.relname = 'sql_migrations' AND n.nspname = '" <> schemaName <> "'",
          "AND a.attnum >= 1 AND NOT a.attisdropped ORDER BY a.attnum)"
        ]
    )
    Encoders.noParams
    (Decoders.singleRow ((,) <$> required Decoders.int8 <*> required (Decoders.listArray (Decoders.nonNullable Decoders.text))))
  where
    required = Decoders.column . Decoders.nonNullable

targetFactsStatement :: Statement () (Int64, Int64, Bool, Bool, Bool)
targetFactsStatement =
  Statement.unpreparable
    ( Text.unwords
        [ "SELECT (SELECT count(*) FROM " <> targetSchema <> ".migrations),",
          "count(*),",
          "to_regclass('" <> targetSchema <> ".should_not_exist') IS NOT NULL,",
          "bool_and(source_evidence #>> '{satisfying_evidence,0,details,adapter}' = 'codd'),",
          "bool_and(source_evidence #>> '{satisfying_evidence,0,details,schemaVersion}' = 'v5')",
          "FROM " <> targetSchema <> ".history_imports"
        ]
    )
    Encoders.noParams
    ( Decoders.singleRow
        ( (,,,,)
            <$> required Decoders.int8
            <*> required Decoders.int8
            <*> required Decoders.bool
            <*> required Decoders.bool
            <*> required Decoders.bool
        )
    )
  where
    required = Decoders.column . Decoders.nonNullable

mixedTargetFactsStatement :: Statement () (Int64, Int64, Bool, Bool)
mixedTargetFactsStatement =
  Statement.unpreparable
    ( Text.unwords
        [ "SELECT (SELECT count(*) FROM " <> targetSchema <> ".migrations),",
          "(SELECT count(*) FROM " <> targetSchema <> ".history_imports),",
          "to_regclass('" <> targetSchema <> ".mixed_same_should_not_exist') IS NOT NULL,",
          "to_regclass('" <> targetSchema <> ".mixed_equivalent_should_not_exist') IS NOT NULL"
        ]
    )
    Encoders.noParams
    ( Decoders.singleRow
        ( (,,,)
            <$> required Decoders.int8
            <*> required Decoders.int8
            <*> required Decoders.bool
            <*> required Decoders.bool
        )
    )
  where
    required = Decoders.column . Decoders.nonNullable

targetSchemaExistsStatement :: Statement Text Bool
targetSchemaExistsStatement =
  Statement.preparable
    "SELECT to_regnamespace($1) IS NOT NULL"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

tryLockStatement :: Statement Int64 Bool
tryLockStatement =
  Statement.preparable
    "SELECT pg_try_advisory_lock($1)"
    (Encoders.param (Encoders.nonNullable Encoders.int8))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

unlockStatement :: Statement Int64 Bool
unlockStatement =
  Statement.preparable
    "SELECT pg_advisory_unlock($1)"
    (Encoders.param (Encoders.nonNullable Encoders.int8))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

fixtureSql :: CoddSchemaVersion -> Text
fixtureSql version =
  Text.unwords
    [ "CREATE SCHEMA " <> fixtureSchema version <> ";",
      "CREATE TABLE " <> fixtureSchema version <> ".sql_migrations (",
      "id serial NOT NULL, migration_timestamp timestamptz NOT NULL, applied_at timestamptz, name text NOT NULL",
      case version of
        CoddV1 -> ");"
        CoddV2 -> ", application_duration interval);"
        CoddV3 -> ", application_duration interval, num_applied_statements int, no_txn_failed_at timestamptz);"
        CoddV4 -> ", application_duration interval, num_applied_statements int, no_txn_failed_at timestamptz, txnid bigint, connid int);"
        CoddV5 -> ", application_duration interval, num_applied_statements int, no_txn_failed_at timestamptz, txnid bigint, connid int);"
    ]

unlockingFixtureSql :: Text
unlockingFixtureSql =
  Text.unwords
    [ "CREATE SCHEMA codd;",
      "CREATE VIEW codd.sql_migrations AS SELECT",
      "1::integer AS id,",
      "'2024-01-01 00:00:00+00'::timestamptz AS migration_timestamp,",
      "CASE WHEN pg_advisory_unlock(" <> Text.pack (show defaultCoddLockKey) <> ")",
      "THEN '2024-01-01 00:00:01+00'::timestamptz ELSE NULL::timestamptz END AS applied_at,",
      "'" <> Text.pack selectedFilename <> "'::text AS name,",
      "NULL::interval AS application_duration,",
      "1::integer AS num_applied_statements,",
      "NULL::timestamptz AS no_txn_failed_at,",
      "NULL::bigint AS txnid,",
      "NULL::integer AS connid;"
    ]

fixtureSchema :: CoddSchemaVersion -> Text
fixtureSchema CoddV5 = "codd"
fixtureSchema _ = "codd_schema"

appliedInsertSql :: CoddSchemaVersion -> FilePath -> Text
appliedInsertSql version migrationFilename =
  Text.unwords
    [ "INSERT INTO " <> fixtureSchema version <> ".sql_migrations",
      "(migration_timestamp, applied_at, name) VALUES",
      "('2024-01-01 00:00:00+00', '2024-01-01 00:00:01+00', '" <> Text.pack migrationFilename <> "');"
    ]

partialInsertSql :: FilePath -> Text
partialInsertSql migrationFilename =
  Text.unwords
    [ "INSERT INTO codd_schema.sql_migrations",
      "(migration_timestamp, applied_at, name, num_applied_statements, no_txn_failed_at) VALUES",
      "('2024-01-01 00:00:00+00', NULL, '" <> Text.pack migrationFilename <> "', 1, '2024-01-01 00:00:01+00');"
    ]

withCleanSchemas :: Settings.Settings -> IO value -> IO value
withCleanSchemas settings = Exception.bracket_ cleanup cleanup
  where
    cleanup = runScript settings cleanupSql

cleanupSql :: Text
cleanupSql =
  Text.unwords
    [ "DROP SCHEMA IF EXISTS codd CASCADE;",
      "DROP SCHEMA IF EXISTS codd_schema CASCADE;",
      "DROP SCHEMA IF EXISTS " <> targetSchema <> " CASCADE;"
    ]

runScript :: Settings.Settings -> Text -> IO ()
runScript settings sql = withConnection settings (\connection -> useSession connection (Session.script sql))

query :: Settings.Settings -> Statement () value -> IO value
query settings statement = withConnection settings (\connection -> useSession connection (Session.statement () statement))

withConnection :: Settings.Settings -> (Connection.Connection -> IO value) -> IO value
withConnection settings action =
  Exception.bracket acquire Connection.release action
  where
    acquire = Connection.acquire settings >>= either (assertFailure . ("could not acquire integration connection: " <>) . show) pure

useSession :: Connection.Connection -> Session.Session value -> IO value
useSession connection session =
  Connection.use connection session >>= either (assertFailure . ("integration session failed: " <>) . show) pure

requireCoddRight :: (Show error) => Either error value -> IO value
requireCoddRight = either (assertFailure . show) pure

assertCoddError :: (CoddImportError -> Bool) -> Either CoddImportError value -> Assertion
assertCoddError matches result =
  case result of
    Left err | matches err -> pure ()
    _ -> assertFailure ("unexpected Codd adapter result: " <> showResult result)
  where
    showResult = either show (const "Right <value>")

checksumText :: ByteString -> Text
checksumText =
  Text.pack . concatMap renderByte . ByteString.unpack . migrationChecksumBytes . migrationFingerprint
  where
    renderByte byte = case Numeric.showHex byte "" of [digit] -> ['0', digit]; digits -> digits

selectedFilename :: FilePath
selectedFilename = "20240101000000-create.sql"

targetPayload :: ByteString
targetPayload = "CREATE TABLE pgmigrate_codd_target.should_not_exist (id bigint)"

targetSchema :: Text
targetSchema = "pgmigrate_codd_target"

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
