module Database.PostgreSQL.Migrate.History.Codd.Import
  ( importCoddHistory,
    buildCoddEvidence,
  )
where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.Codd.Ledger
  ( readCoddHistoryOnConnection,
    withLockedCoddHistory,
  )
import Database.PostgreSQL.Migrate.History.Codd.Types
import Database.PostgreSQL.Migrate.Internal (migrationChecksumBytes)
import Numeric qualified
import PgMigrate.History.Codd.Prelude

-- | Read Codd under its source lock, then atomically import target metadata.
importCoddHistory ::
  ImportOptions ->
  CoddSourceConfig ->
  ConnectionProvider ->
  MigrationPlan ->
  NonEmpty HistoryMapping ->
  IO (Either CoddImportError HistoryImportReport)
importCoddHistory options config targetProvider plan mappings =
  case validateImportDefinition config plan mappings of
    Left err -> pure (Left err)
    Right () ->
      withLockedCoddHistory config $ \sourceConnection -> do
        loaded <- readCoddHistoryOnConnection config sourceConnection
        case loaded of
          Left err -> pure (Left err)
          Right history ->
            case buildHistoryImport config history mappings of
              Left err -> pure (Left err)
              Right historyImportDefinition -> do
                imported <- importMigrationHistory options targetProvider plan historyImportDefinition
                pure (first CoddTargetImportFailed imported)

validateImportDefinition ::
  CoddSourceConfig ->
  MigrationPlan ->
  NonEmpty HistoryMapping ->
  Either CoddImportError ()
validateImportDefinition config@CoddSourceConfig {selectedFilenames, confirmation, sourceManifest} plan mappings = do
  if any isSamePayload mappings && confirmation /= Confirmed
    then Left CoddConfirmationRequired
    else pure ()
  if any isSamePayload mappings && sourceManifest == Nothing
    then Left CoddSamePayloadRequiresManifest
    else pure ()
  placeholderEvidence <- buildPlaceholderEvidence selectedFilenames
  case historyImport "codd" placeholderEvidence [] mappings (importReason config) of
    Left err -> Left (CoddHistoryDefinitionFailed err)
    Right _ -> Right ()
  first
    (CoddTargetImportFailed . HistoryImportValidationFailed)
    (validateHistoryMappingTargets plan mappings)
  where
    isSamePayload mapping =
      case historyMappingPayloadRelation mapping of
        SamePayload _ -> True
        EquivalentState -> False

buildPlaceholderEvidence ::
  NonEmpty FilePath ->
  Either CoddImportError (Map EvidenceKey ImportEvidence)
buildPlaceholderEvidence filenames =
  Map.fromList . toList <$> traverse placeholder filenames
  where
    placeholder filename = do
      key <- first CoddDefinitionFailed (coddEvidenceKey filename)
      evidence <-
        first
          CoddHistoryDefinitionFailed
          (ledgerOnlyEvidence (Text.pack filename) Nothing Nothing Aeson.Null)
      Right (key, evidence)

buildHistoryImport ::
  CoddSourceConfig ->
  CoddHistory ->
  NonEmpty HistoryMapping ->
  Either CoddImportError HistoryImport
buildHistoryImport config history mappings = do
  evidence <- buildCoddEvidence config history
  first
    CoddHistoryDefinitionFailed
    (historyImport "codd" evidence [] mappings (importReason config))

buildCoddEvidence ::
  CoddSourceConfig ->
  CoddHistory ->
  Either CoddImportError (Map EvidenceKey ImportEvidence)
buildCoddEvidence config@CoddSourceConfig {strictSource, sourceManifest} CoddHistory {schemaVersion, selectedRows} = do
  case sourceManifest of
    Just (CoddManifest manifest)
      | strictSource ->
          let selected = Set.fromList (filename <$> toList selectedRows)
              extras = Set.toAscList (Map.keysSet manifest `Set.difference` selected)
           in if null extras then Right () else Left (CoddManifestHasUnexpected extras)
    _ -> Right ()
  Map.fromList . toList <$> traverse (rowEvidence config schemaVersion) selectedRows

rowEvidence ::
  CoddSourceConfig ->
  CoddSchemaVersion ->
  CoddHistoryRow ->
  Either CoddImportError (EvidenceKey, ImportEvidence)
rowEvidence CoddSourceConfig {sourcePayloads, sourceManifest} version row@CoddHistoryRow {filename, appliedAt} = do
  key <- first CoddDefinitionFailed (coddEvidenceKey filename)
  let maybeBytes = Map.lookup filename sourcePayloads
      maybeChecksum = migrationFingerprint <$> maybeBytes
      details = rowDetails version row
      timestamp = AbsoluteTime <$> appliedAt
  evidence <-
    case sourceManifest of
      Nothing ->
        first
          CoddHistoryDefinitionFailed
          (ledgerOnlyEvidence (Text.pack filename) timestamp maybeChecksum details)
      Just (CoddManifest manifest) -> do
        expected <- maybe (Left (CoddManifestEntryMissing filename)) Right (Map.lookup filename manifest)
        bytes <- maybe (Left (CoddSourcePayloadMissing filename)) Right maybeBytes
        let actualChecksum = migrationFingerprint bytes
            actual = checksumText actualChecksum
        if actual /= expected
          then Left (CoddManifestChecksumMismatch filename expected actual)
          else
            first
              CoddHistoryDefinitionFailed
              ( sourceManifestVerifiedEvidence
                  (Text.pack filename)
                  timestamp
                  (Just actualChecksum)
                  details
              )
  Right (key, evidence)

rowDetails :: CoddSchemaVersion -> CoddHistoryRow -> Aeson.Value
rowDetails version CoddHistoryRow {filename, migrationTimestamp, appliedAt, numAppliedStatements, noTransactionFailedAt} =
  Aeson.object
    [ "adapter" Aeson..= ("codd" :: Text),
      "schemaVersion" Aeson..= schemaVersionText version,
      "filename" Aeson..= filename,
      "migrationTimestamp" Aeson..= migrationTimestamp,
      "appliedAt" Aeson..= appliedAt,
      "numAppliedStatements" Aeson..= numAppliedStatements,
      "noTransactionFailedAt" Aeson..= noTransactionFailedAt
    ]

schemaVersionText :: CoddSchemaVersion -> Text
schemaVersionText version =
  case version of
    CoddV1 -> "v1"
    CoddV2 -> "v2"
    CoddV3 -> "v3"
    CoddV4 -> "v4"
    CoddV5 -> "v5"

checksumText :: MigrationChecksum -> Text
checksumText =
  Text.pack . concatMap renderByte . ByteString.unpack . migrationChecksumBytes
  where
    renderByte byte =
      case Numeric.showHex byte "" of
        [digit] -> ['0', digit]
        digits -> digits
