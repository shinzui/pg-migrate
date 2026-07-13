module Main (main) where

import Control.Exception qualified as Exception
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.HasqlMigration
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Transaction
import System.Environment (lookupEnv)
import Test.Tasty
import Test.Tasty.HUnit

main :: IO ()
main = do
  maybeConnectionString <- lookupEnv "PG_CONNECTION_STRING"
  case maybeConnectionString of
    Nothing -> putStrLn "pg-migrate-import-hasql-migration integration tests skipped: PG_CONNECTION_STRING is not set"
    Just connectionString ->
      defaultMain (tests (Settings.connectionString (Text.pack connectionString)))

tests :: Settings.Settings -> TestTree
tests settings =
  testGroup
    "hasql-migration adapter PostgreSQL"
    [ testCase "qualified custom table reads without source mutation" (testQualifiedRead settings),
      testCase "bad MD5 and duplicate rows reject before target mutation" (testInvalidSource settings),
      testCase "lenient selection reports extras and strict selection rejects" (testStrictSelection settings),
      testCase "direct import preserves local time, skips actions, and is idempotent" (testDirectImport settings),
      testCase "changed source evidence conflicts with an existing import" (testChangedEvidence settings),
      testCase "alternative history requires and runs a read-only domain validator" (testEquivalentHistory settings)
    ]

testQualifiedRead :: Settings.Settings -> Assertion
testQualifiedRead settings =
  withCleanSchemas settings $ do
    runScript settings customFixtureSql
    let config = sourceConfig settings customTable False (directFilename :| []) directPayloads []
    before <- query settings customSourceSnapshotStatement
    history <- readHasqlMigrationHistory config >>= requireAdapterRight
    (filename <$> toList (selectedRows history)) @?= [directFilename]
    afterSnapshot <- query settings customSourceSnapshotStatement
    afterSnapshot @?= before

testInvalidSource :: Settings.Settings -> Assertion
testInvalidSource settings = do
  withCleanSchemas settings $ do
    runScript settings (sourceFixtureSql <> sourceInsert directFilename "wrong" directExecutedAt)
    runDirectImport settings >>= assertAdapterError (\case HasqlMigrationChecksumMismatch name "wrong" _ -> name == directFilename; _ -> False)
    targetExists <- query settings targetSchemaExistsStatement
    targetExists @?= False
  withCleanSchemas settings $ do
    runScript settings (sourceFixtureSql <> sourceInsert directFilename directMd5 directExecutedAt <> sourceInsert directFilename directMd5 directExecutedAt)
    runDirectImport settings >>= assertAdapterError (\case HasqlMigrationDuplicateLedgerFilename name -> name == directFilename; _ -> False)
    targetExists <- query settings targetSchemaExistsStatement
    targetExists @?= False

testStrictSelection :: Settings.Settings -> Assertion
testStrictSelection settings =
  withCleanSchemas settings $ do
    runScript settings (sourceFixtureSql <> sourceInsert directFilename directMd5 directExecutedAt <> sourceInsert "unselected.sql" md5Two "2024-01-02 04:05:06")
    let lenient = sourceConfig settings defaultSourceTable False (directFilename :| []) directPayloads []
        strict = sourceConfig settings defaultSourceTable True (directFilename :| []) directPayloads []
    history <- readHasqlMigrationHistory lenient >>= requireAdapterRight
    (filename <$> unselectedRows history) @?= ["unselected.sql"]
    readHasqlMigrationHistory strict
      >>= assertAdapterError (\case HasqlMigrationStrictSourceHasUnselected ["unselected.sql"] -> True; _ -> False)

testDirectImport :: Settings.Settings -> Assertion
testDirectImport settings =
  withCleanSchemas settings $ do
    runScript settings (sourceFixtureSql <> sourceInsert directFilename directMd5 directExecutedAt)
    before <- query settings sourceSnapshotStatement
    first <- runDirectImport settings >>= requireAdapterRight
    outcomes first @?= [Imported]
    facts <- query settings directTargetFactsStatement
    facts @?= (1, 1, False, True, True, True)
    second <- runDirectImport settings >>= requireAdapterRight
    outcomes second @?= [AlreadyImported]
    repeatedFacts <- query settings directTargetFactsStatement
    repeatedFacts @?= facts
    afterSnapshot <- query settings sourceSnapshotStatement
    afterSnapshot @?= before

testChangedEvidence :: Settings.Settings -> Assertion
testChangedEvidence settings =
  withCleanSchemas settings $ do
    runScript settings (sourceFixtureSql <> sourceInsert directFilename directMd5 directExecutedAt)
    _ <- runDirectImport settings >>= requireAdapterRight
    runScript settings ("UPDATE hasql_migration_source.schema_migrations SET executed_at = '2024-02-03 04:05:06' WHERE filename = '" <> Text.pack directFilename <> "';")
    runDirectImport settings
      >>= assertAdapterError
        (\case HasqlMigrationTargetImportFailed (HistoryImportConflict identifier) -> identifier == directTargetId; _ -> False)
    counts <- query settings targetCountsStatement
    counts @?= (1, 1)

testEquivalentHistory :: Settings.Settings -> Assertion
testEquivalentHistory settings = do
  withCleanSchemas settings $ do
    runScript settings (sourceFixtureSql <> sourceInsert "legacy-one.sql" md5One directExecutedAt <> sourceInsert "legacy-two.sql" md5Two "2024-01-02 04:05:06" <> "CREATE SCHEMA legacy_domain; CREATE TABLE legacy_domain.ready (id integer);")
    let passingConfig = equivalentSourceConfig settings passingValidator
    rejected <- runEquivalentImport settings directOptions passingConfig
    assertAdapterError
      (\case HasqlMigrationTargetImportFailed (HistoryImportValidationFailed (HistoryEquivalentStateDisallowed _)) -> True; _ -> False)
      rejected
    imported <- runEquivalentImport settings equivalentOptions passingConfig >>= requireAdapterRight
    outcomes imported @?= [Imported]
    facts <- query settings equivalentTargetFactsStatement
    facts @?= (1, 1, False, True)
  withCleanSchemas settings $ do
    runScript settings (sourceFixtureSql <> sourceInsert "legacy-one.sql" md5One directExecutedAt <> sourceInsert "legacy-two.sql" md5Two "2024-01-02 04:05:06")
    result <- runEquivalentImport settings equivalentOptions (equivalentSourceConfig settings failingValidator)
    assertAdapterError
      (\case HasqlMigrationTargetImportFailed (HistoryStateValidationFailed key _) -> key == stateKey; _ -> False)
      result
    counts <- query settings targetCountsIfPresentStatement
    counts @?= (0, 0)

runDirectImport :: Settings.Settings -> IO (Either HasqlMigrationImportError HistoryImportReport)
runDirectImport settings =
  importHasqlMigrationHistory
    directOptions
    (sourceConfig settings defaultSourceTable False (directFilename :| []) directPayloads [])
    (connectionProviderFromSettings settings)
    directPlan
    (directMapping :| [])

runEquivalentImport :: Settings.Settings -> ImportOptions -> HasqlMigrationSourceConfig -> IO (Either HasqlMigrationImportError HistoryImportReport)
runEquivalentImport settings options config =
  importHasqlMigrationHistory options config (connectionProviderFromSettings settings) equivalentPlan (equivalentMapping :| [])

sourceConfig ::
  Settings.Settings ->
  QualifiedTable ->
  Bool ->
  NonEmpty FilePath ->
  Map.Map FilePath ByteString ->
  [StateValidator] ->
  HasqlMigrationSourceConfig
sourceConfig settings table strict filenames payloads validators =
  expectRight
    ( hasqlMigrationSourceConfig
        (connectionProviderFromSettings settings)
        table
        filenames
        strict
        payloads
        validators
        "verified hasql-migration cutover"
    )

equivalentSourceConfig :: Settings.Settings -> StateValidator -> HasqlMigrationSourceConfig
equivalentSourceConfig settings validator =
  sourceConfig
    settings
    defaultSourceTable
    False
    ("legacy-one.sql" :| ["legacy-two.sql"])
    (Map.fromList [("legacy-one.sql", "LEGACY PART ONE"), ("legacy-two.sql", "LEGACY PART TWO")])
    [validator]

passingValidator :: StateValidator
passingValidator =
  stateValidator stateKey $ do
    exists <- Transaction.statement "legacy_domain.ready" regclassStatement
    pure
      ( if exists
          then Right (Aeson.object ["legacy_domain" Aeson..= ("ready" :: Text)])
          else Left (expectRight (stateValidationError "legacy domain is missing"))
      )

failingValidator :: StateValidator
failingValidator =
  stateValidator stateKey (pure (Left (expectRight (stateValidationError "legacy domain is missing"))))

regclassStatement :: Statement Text Bool
regclassStatement =
  Statement.preparable
    "SELECT to_regclass($1) IS NOT NULL"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

directMapping :: HistoryMapping
directMapping = historyMapping directTargetId (Evidence directKey) (SamePayload directKey)

equivalentMapping :: HistoryMapping
equivalentMapping =
  historyMapping
    equivalentTargetId
    (AllOf (Evidence legacyOneKey :| [Evidence legacyTwoKey, Evidence stateKey]))
    EquivalentState

directKey, legacyOneKey, legacyTwoKey, stateKey :: EvidenceKey
directKey = expectRight (hasqlMigrationEvidenceKey directFilename)
legacyOneKey = expectRight (hasqlMigrationEvidenceKey "legacy-one.sql")
legacyTwoKey = expectRight (hasqlMigrationEvidenceKey "legacy-two.sql")
stateKey = expectRight (evidenceKey "hasql-migration:domain-ready")

directTargetId, equivalentTargetId :: MigrationId
directTargetId = expectRight (migrationId "hasql-target" "0001-direct")
equivalentTargetId = expectRight (migrationId "hasql-equivalent" "0001-domain")

directPlan, equivalentPlan :: MigrationPlan
directPlan = singlePlan "hasql-target" "0001-direct" directPayload
equivalentPlan = singlePlan "hasql-equivalent" "0001-domain" "CREATE TABLE pgmigrate_hasql_target.equivalent_action (id bigint)"

singlePlan :: Text -> Text -> ByteString -> MigrationPlan
singlePlan component migration payload =
  expectRight (migrationPlan (expectRight (migrationComponent component Set.empty (expectRight (sqlMigration migration payload) :| [])) :| []))

directOptions, equivalentOptions :: ImportOptions
directOptions = withImportRunOptions targetRunOptions defaultImportOptions
equivalentOptions = withEquivalentHistory AllowEquivalentHistory directOptions

targetRunOptions :: RunOptions
targetRunOptions = withLedger (expectRight (ledgerConfig targetSchema 0x686173716C746172)) defaultRunOptions

outcomes :: HistoryImportReport -> [HistoryImportOutcome]
outcomes HistoryImportReport {importResults} = importOutcome <$> toList importResults

sourceFixtureSql :: Text
sourceFixtureSql =
  "CREATE SCHEMA hasql_migration_source; CREATE TABLE hasql_migration_source.schema_migrations (filename text NOT NULL, checksum text NOT NULL, executed_at timestamp without time zone NOT NULL);"

customFixtureSql :: Text
customFixtureSql =
  "CREATE SCHEMA \"legacy data\"; CREATE TABLE \"legacy data\".\"migration\"\"history\" (filename text NOT NULL, checksum text NOT NULL, executed_at timestamp without time zone NOT NULL); INSERT INTO \"legacy data\".\"migration\"\"history\" VALUES ('"
    <> Text.pack directFilename
    <> "', '"
    <> directMd5
    <> "', '"
    <> directExecutedAt
    <> "');"

sourceInsert :: FilePath -> Text -> Text -> Text
sourceInsert migrationFilename checksum timestamp =
  "INSERT INTO hasql_migration_source.schema_migrations VALUES ('"
    <> Text.pack migrationFilename
    <> "', '"
    <> checksum
    <> "', '"
    <> timestamp
    <> "');"

sourceSnapshotStatement, customSourceSnapshotStatement :: Statement () (Int64, Text)
sourceSnapshotStatement = snapshotStatement "hasql_migration_source.schema_migrations"
customSourceSnapshotStatement = snapshotStatement "\"legacy data\".\"migration\"\"history\""

snapshotStatement :: Text -> Statement () (Int64, Text)
snapshotStatement source =
  Statement.unpreparable
    ("SELECT count(*), md5(string_agg(filename || checksum || executed_at::text, '' ORDER BY executed_at, filename)) FROM " <> source)
    Encoders.noParams
    (Decoders.singleRow ((,) <$> required Decoders.int8 <*> required Decoders.text))
  where
    required = Decoders.column . Decoders.nonNullable

directTargetFactsStatement :: Statement () (Int64, Int64, Bool, Bool, Bool, Bool)
directTargetFactsStatement =
  Statement.unpreparable
    ( Text.unwords
        [ "SELECT (SELECT count(*) FROM " <> targetSchema <> ".migrations), count(*),",
          "to_regclass('" <> targetSchema <> ".should_not_exist') IS NOT NULL,",
          "bool_and(source_evidence #>> '{satisfying_evidence,0,strength}' = 'source-ledger-checksum-verified'),",
          "bool_and(source_evidence #>> '{satisfying_evidence,0,applied_at,kind}' = 'local-without-zone'",
          "AND source_evidence #>> '{satisfying_evidence,0,applied_at,value}' = '2024-01-02 03:04:05'),",
          "bool_and(source_evidence #>> '{satisfying_evidence,0,details,source_table}' = '\"hasql_migration_source\".\"schema_migrations\"')",
          "FROM " <> targetSchema <> ".history_imports"
        ]
    )
    Encoders.noParams
    (Decoders.singleRow ((,,,,,) <$> required Decoders.int8 <*> required Decoders.int8 <*> required Decoders.bool <*> required Decoders.bool <*> required Decoders.bool <*> required Decoders.bool))
  where
    required = Decoders.column . Decoders.nonNullable

equivalentTargetFactsStatement :: Statement () (Int64, Int64, Bool, Bool)
equivalentTargetFactsStatement =
  Statement.unpreparable
    ( Text.unwords
        [ "SELECT (SELECT count(*) FROM " <> targetSchema <> ".migrations), count(*),",
          "to_regclass('" <> targetSchema <> ".equivalent_action') IS NOT NULL,",
          "source_evidence::text LIKE '%state-verified%'",
          "FROM " <> targetSchema <> ".history_imports GROUP BY source_evidence"
        ]
    )
    Encoders.noParams
    (Decoders.singleRow ((,,,) <$> required Decoders.int8 <*> required Decoders.int8 <*> required Decoders.bool <*> required Decoders.bool))
  where
    required = Decoders.column . Decoders.nonNullable

targetCountsStatement :: Statement () (Int64, Int64)
targetCountsStatement =
  Statement.unpreparable
    ("SELECT (SELECT count(*) FROM " <> targetSchema <> ".migrations), (SELECT count(*) FROM " <> targetSchema <> ".history_imports)")
    Encoders.noParams
    (Decoders.singleRow ((,) <$> required Decoders.int8 <*> required Decoders.int8))
  where
    required = Decoders.column . Decoders.nonNullable

targetCountsIfPresentStatement :: Statement () (Int64, Int64)
targetCountsIfPresentStatement = targetCountsStatement

targetSchemaExistsStatement :: Statement () Bool
targetSchemaExistsStatement =
  Statement.preparable
    "SELECT to_regnamespace('pgmigrate_hasql_target') IS NOT NULL"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

defaultSourceTable, customTable :: QualifiedTable
defaultSourceTable = expectRight (qualifiedTable "hasql_migration_source.schema_migrations")
customTable = expectRight (qualifiedTable "legacy data.migration\"history")

directPayloads :: Map.Map FilePath ByteString
directPayloads = Map.fromList [(directFilename, directPayload), ("unselected.sql", "SELECT 2")]

directFilename :: FilePath
directFilename = "0001-direct.sql"

directPayload :: ByteString
directPayload = "CREATE TABLE pgmigrate_hasql_target.should_not_exist (id bigint)"

directMd5, md5One, md5Two, directExecutedAt :: Text
directMd5 = "h2PAgWYnAN32+RvJkHfzhQ=="
md5One = "Q+RyEgfRb5LTu12mraufdA=="
md5Two = "Gy3qSDLT6v7pC10e6tEwNA=="
directExecutedAt = "2024-01-02 03:04:05"

targetSchema :: Text
targetSchema = "pgmigrate_hasql_target"

withCleanSchemas :: Settings.Settings -> IO value -> IO value
withCleanSchemas settings = Exception.bracket_ cleanup cleanup
  where
    cleanup = runScript settings cleanupSql

cleanupSql :: Text
cleanupSql =
  Text.unwords
    [ "DROP SCHEMA IF EXISTS hasql_migration_source CASCADE;",
      "DROP SCHEMA IF EXISTS \"legacy data\" CASCADE;",
      "DROP SCHEMA IF EXISTS legacy_domain CASCADE;",
      "DROP SCHEMA IF EXISTS " <> targetSchema <> " CASCADE;"
    ]

runScript :: Settings.Settings -> Text -> IO ()
runScript settings sql = withConnection settings (\connection -> useSession connection (Session.script sql))

query :: Settings.Settings -> Statement () value -> IO value
query settings statement = withConnection settings (\connection -> useSession connection (Session.statement () statement))

withConnection :: Settings.Settings -> (Connection.Connection -> IO value) -> IO value
withConnection settings = Exception.bracket acquire Connection.release
  where
    acquire = Connection.acquire settings >>= either (assertFailure . ("could not acquire integration connection: " <>) . show) pure

useSession :: Connection.Connection -> Session.Session value -> IO value
useSession connection session = Connection.use connection session >>= either (assertFailure . ("integration session failed: " <>) . show) pure

requireAdapterRight :: Either HasqlMigrationImportError value -> IO value
requireAdapterRight = either (assertFailure . show) pure

assertAdapterError :: (HasqlMigrationImportError -> Bool) -> Either HasqlMigrationImportError value -> Assertion
assertAdapterError matches result =
  case result of
    Left err | matches err -> pure ()
    Left err -> assertFailure ("unexpected adapter error: " <> show err)
    Right _ -> assertFailure "expected adapter error, received Right"

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
