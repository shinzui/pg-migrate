module Database.PostgreSQL.Migrate.History.HasqlMigration.Import
  ( importHasqlMigrationHistory,
    buildHasqlMigrationEvidence,
    rowDetails,
  )
where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.History.HasqlMigration.Ledger
  ( readHasqlMigrationHistory,
    renderQualifiedTable,
  )
import Database.PostgreSQL.Migrate.History.HasqlMigration.Types
import PgMigrate.History.HasqlMigration.Prelude

-- | Verify source payloads, then atomically import matching target metadata.
importHasqlMigrationHistory ::
  ImportOptions ->
  HasqlMigrationSourceConfig ->
  ConnectionProvider ->
  MigrationPlan ->
  NonEmpty HistoryMapping ->
  IO (Either HasqlMigrationImportError HistoryImportReport)
importHasqlMigrationHistory options config targetProvider plan mappings =
  case validateImportDefinition config plan mappings of
    Left err -> pure (Left err)
    Right () -> do
      loaded <- readHasqlMigrationHistory config
      case loaded of
        Left err -> pure (Left err)
        Right history ->
          case buildHistoryImport config history mappings of
            Left err -> pure (Left err)
            Right historyImportDefinition -> do
              imported <- importMigrationHistory options targetProvider plan historyImportDefinition
              pure (first HasqlMigrationTargetImportFailed imported)

validateImportDefinition ::
  HasqlMigrationSourceConfig ->
  MigrationPlan ->
  NonEmpty HistoryMapping ->
  Either HasqlMigrationImportError ()
validateImportDefinition config@HasqlMigrationSourceConfig {selectedFilenames, stateValidators} plan mappings = do
  placeholder <- placeholderEvidence config selectedFilenames
  case historyImport "hasql-migration" placeholder stateValidators mappings (importReason config) of
    Left err -> Left (HasqlMigrationHistoryDefinitionFailed err)
    Right _ -> Right ()
  first
    (HasqlMigrationTargetImportFailed . HistoryImportValidationFailed)
    (validateHistoryMappingTargets plan mappings)

placeholderEvidence ::
  HasqlMigrationSourceConfig ->
  NonEmpty FilePath ->
  Either HasqlMigrationImportError (Map EvidenceKey ImportEvidence)
placeholderEvidence HasqlMigrationSourceConfig {sourcePayloads} filenames =
  Map.fromList . toList <$> traverse placeholder filenames
  where
    placeholder migrationFilename = do
      key <- first HasqlMigrationDefinitionFailed (hasqlMigrationEvidenceKey migrationFilename)
      payloadBytes <-
        maybe
          (Left (HasqlMigrationDefinitionFailed (MissingHasqlMigrationPayload migrationFilename)))
          Right
          (Map.lookup migrationFilename sourcePayloads)
      evidence <-
        first
          HasqlMigrationHistoryDefinitionFailed
          ( sourceLedgerChecksumVerifiedEvidence
              (Text.pack migrationFilename)
              Nothing
              (Just (migrationFingerprint payloadBytes))
              Aeson.Null
          )
      Right (key, evidence)

buildHistoryImport ::
  HasqlMigrationSourceConfig ->
  HasqlMigrationHistory ->
  NonEmpty HistoryMapping ->
  Either HasqlMigrationImportError HistoryImport
buildHistoryImport config@HasqlMigrationSourceConfig {stateValidators} history mappings = do
  evidence <- buildHasqlMigrationEvidence config history
  first
    HasqlMigrationHistoryDefinitionFailed
    (historyImport "hasql-migration" evidence stateValidators mappings (importReason config))

buildHasqlMigrationEvidence ::
  HasqlMigrationSourceConfig ->
  HasqlMigrationHistory ->
  Either HasqlMigrationImportError (Map EvidenceKey ImportEvidence)
buildHasqlMigrationEvidence HasqlMigrationSourceConfig {sourcePayloads, sourceTable} HasqlMigrationHistory {selectedRows} =
  Map.fromList . toList <$> traverse rowEvidence selectedRows
  where
    rowEvidence row@HasqlMigrationRow {filename, executedAt} = do
      key <- first HasqlMigrationDefinitionFailed (hasqlMigrationEvidenceKey filename)
      payloadBytes <-
        maybe
          (Left (HasqlMigrationDefinitionFailed (MissingHasqlMigrationPayload filename)))
          Right
          (Map.lookup filename sourcePayloads)
      evidence <-
        first
          HasqlMigrationHistoryDefinitionFailed
          ( sourceLedgerChecksumVerifiedEvidence
              (Text.pack filename)
              (Just (LocalTimeWithoutZone executedAt))
              (Just (migrationFingerprint payloadBytes))
              (rowDetails sourceTable row)
          )
      Right (key, evidence)

rowDetails :: QualifiedTable -> HasqlMigrationRow -> Aeson.Value
rowDetails sourceTable HasqlMigrationRow {filename, storedMd5, executedAt} =
  Aeson.object
    [ "adapter" Aeson..= ("hasql-migration" :: Text),
      "source_table" Aeson..= renderQualifiedTable sourceTable,
      "filename" Aeson..= filename,
      "storedMd5" Aeson..= storedMd5,
      "executedAt" Aeson..= executedAt
    ]
