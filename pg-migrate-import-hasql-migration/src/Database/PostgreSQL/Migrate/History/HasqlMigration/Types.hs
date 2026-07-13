module Database.PostgreSQL.Migrate.History.HasqlMigration.Types
  ( QualifiedTable (..),
    HasqlMigrationSourceConfig (..),
    HasqlMigrationRow (..),
    HasqlMigrationHistory (..),
    HasqlMigrationDefinitionError (..),
    HasqlMigrationImportError (..),
    HasqlMigrationImportCommand (..),
    qualifiedTable,
    defaultHasqlMigrationTable,
    hasqlMigrationSourceConfig,
    hasqlMigrationEvidenceKey,
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI (OutputFormat)
import Database.PostgreSQL.Migrate.Internal
  ( PostgresIdentifier,
    postgresIdentifier,
  )
import Hasql.Connection.Settings qualified as Settings
import Hasql.Errors qualified as Errors
import PgMigrate.History.HasqlMigration.Prelude

-- | Validated schema-qualified predecessor ledger table.
data QualifiedTable = QualifiedTable
  { tableSchema :: !PostgresIdentifier,
    tableName :: !PostgresIdentifier
  }
  deriving stock (Generic, Eq, Show)

-- | Validated source settings, table, payload selection, and mapping policy.
data HasqlMigrationSourceConfig = HasqlMigrationSourceConfig
  { sourceProvider :: !ConnectionProvider,
    sourceTable :: !QualifiedTable,
    selectedFilenames :: !(NonEmpty FilePath),
    strictSource :: !Bool,
    sourcePayloads :: !(Map FilePath ByteString),
    stateValidators :: ![StateValidator],
    importReason :: !Text
  }

-- | Normalized immutable hasql-migration row with verified payload bytes.
data HasqlMigrationRow = HasqlMigrationRow
  { filename :: !FilePath,
    storedMd5 :: !Text,
    executedAt :: !LocalTime
  }
  deriving stock (Generic, Eq, Show)

-- | Selected verified rows and any unselected source extras.
data HasqlMigrationHistory = HasqlMigrationHistory
  { selectedRows :: !(NonEmpty HasqlMigrationRow),
    unselectedRows :: ![HasqlMigrationRow]
  }
  deriving stock (Generic, Eq, Show)

-- | Invalid qualified name, mappings, or source configuration.
data HasqlMigrationDefinitionError
  = InvalidQualifiedTable !Text
  | InvalidQualifiedTableIdentifier !Text !PostgresIdentifierError
  | EmptyHasqlMigrationFilename
  | DuplicateHasqlMigrationFilename !FilePath
  | MissingHasqlMigrationPayload !FilePath
  | EmptyHasqlMigrationImportReason
  | HasqlMigrationEvidenceDefinitionError !HistoryDefinitionError
  deriving stock (Generic, Eq, Show)

-- | Structured source-read, checksum, validation, or target-import failure.
data HasqlMigrationImportError
  = HasqlMigrationDefinitionFailed !HasqlMigrationDefinitionError
  | HasqlMigrationConnectionFailed !Errors.ConnectionError
  | HasqlMigrationSessionFailed !Errors.SessionError
  | HasqlMigrationTableMissing !Text
  | HasqlMigrationUnsupportedShape !Text ![Text]
  | HasqlMigrationDuplicateLedgerFilename !FilePath
  | HasqlMigrationSelectedFilenameMissing !FilePath
  | HasqlMigrationStrictSourceHasUnselected ![FilePath]
  | HasqlMigrationChecksumMismatch !FilePath !Text !Text
  | HasqlMigrationHistoryDefinitionFailed !HistoryDefinitionError
  | HasqlMigrationTargetImportFailed !HistoryImportError
  deriving stock (Generic, Show)

-- | Parsed, application-dispatchable hasql-migration import command.
data HasqlMigrationImportCommand = HasqlMigrationImportCommand
  { sourceSettings :: !(Maybe Settings.Settings),
    table :: !QualifiedTable,
    mappingPath :: !FilePath,
    sourceDirectory :: !FilePath,
    strict :: !Bool,
    allowEquivalent :: !Bool,
    outputFormat :: !OutputFormat
  }
  deriving stock (Generic, Eq, Show)

-- | Parse and validate a schema-qualified table name.
qualifiedTable :: Text -> Either HasqlMigrationDefinitionError QualifiedTable
qualifiedTable input =
  case Text.splitOn "." input of
    [schemaInput, tableInput] ->
      QualifiedTable
        <$> validatePart schemaInput
        <*> validatePart tableInput
    _ -> Left (InvalidQualifiedTable input)
  where
    validatePart value =
      case postgresIdentifier value of
        Right identifier -> Right identifier
        Left InvalidLedgerSchema {postgresIdentifierReason} ->
          Left (InvalidQualifiedTableIdentifier value postgresIdentifierReason)
        Left _ -> Left (InvalidQualifiedTable value)

-- | The predecessor's conventional @public.schema_migrations@ table.
defaultHasqlMigrationTable :: QualifiedTable
defaultHasqlMigrationTable = either (error . show) id (qualifiedTable "public.schema_migrations")

-- | Validate a complete hasql-migration source configuration.
hasqlMigrationSourceConfig ::
  ConnectionProvider ->
  QualifiedTable ->
  NonEmpty FilePath ->
  Bool ->
  Map FilePath ByteString ->
  [StateValidator] ->
  Text ->
  Either HasqlMigrationDefinitionError HasqlMigrationSourceConfig
hasqlMigrationSourceConfig sourceProvider sourceTable selectedFilenames strictSource sourcePayloads stateValidators importReason = do
  let filenames = toList selectedFilenames
  case firstDuplicate filenames of
    Just duplicate -> Left (DuplicateHasqlMigrationFilename duplicate)
    Nothing -> pure ()
  if any null filenames then Left EmptyHasqlMigrationFilename else pure ()
  case filter (`Map.notMember` sourcePayloads) filenames of
    missing : _ -> Left (MissingHasqlMigrationPayload missing)
    [] -> pure ()
  if Text.null (Text.strip importReason) then Left EmptyHasqlMigrationImportReason else pure ()
  Right HasqlMigrationSourceConfig {sourceProvider, sourceTable, selectedFilenames, strictSource, sourcePayloads, stateValidators, importReason}

-- | Derive the canonical evidence key for one selected payload file.
hasqlMigrationEvidenceKey :: FilePath -> Either HasqlMigrationDefinitionError EvidenceKey
hasqlMigrationEvidenceKey migrationFilename
  | null migrationFilename = Left EmptyHasqlMigrationFilename
  | otherwise =
      case evidenceKey ("hasql-migration:" <> Text.pack migrationFilename) of
        Left err -> Left (HasqlMigrationEvidenceDefinitionError err)
        Right key -> Right key

firstDuplicate :: (Ord value) => [value] -> Maybe value
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (value : remaining)
      | Set.member value seen = Just value
      | otherwise = go (Set.insert value seen) remaining
