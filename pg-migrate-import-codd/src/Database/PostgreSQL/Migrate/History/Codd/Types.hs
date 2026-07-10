module Database.PostgreSQL.Migrate.History.Codd.Types
  ( CoddSourceConfig (..),
    CoddManifest (..),
    CoddSchemaVersion (..),
    CoddHistoryRow (..),
    CoddHistory (..),
    CoddDefinitionError (..),
    CoddImportError (..),
    CoddImportCommand (..),
    defaultCoddLockKey,
    coddSourceConfig,
    withCoddLockKey,
    coddEvidenceKey,
  )
where

import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
  ( Confirmation,
    ConnectionProvider,
    EvidenceKey,
    HistoryDefinitionError,
    HistoryImportError,
    evidenceKey,
  )
import Database.PostgreSQL.Migrate.CLI (OutputFormat)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Errors qualified as Errors
import PgMigrate.History.Codd.Prelude

data CoddSourceConfig = CoddSourceConfig
  { sourceProvider :: !ConnectionProvider,
    sourceLockKey :: !Int64,
    selectedFilenames :: !(NonEmpty FilePath),
    strictSource :: !Bool,
    sourcePayloads :: !(Map FilePath ByteString),
    sourceManifest :: !(Maybe CoddManifest),
    importReason :: !Text,
    confirmation :: !Confirmation
  }

newtype CoddManifest = CoddManifest
  { manifestChecksums :: Map FilePath Text
  }
  deriving stock (Generic, Eq, Show)

data CoddSchemaVersion
  = CoddV1
  | CoddV2
  | CoddV3
  | CoddV4
  | CoddV5
  deriving stock (Generic, Eq, Ord, Show)

data CoddHistoryRow = CoddHistoryRow
  { filename :: !FilePath,
    migrationTimestamp :: !UTCTime,
    appliedAt :: !(Maybe UTCTime),
    numAppliedStatements :: !Int32,
    noTransactionFailedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)

data CoddHistory = CoddHistory
  { schemaVersion :: !CoddSchemaVersion,
    selectedRows :: !(NonEmpty CoddHistoryRow),
    unselectedRows :: ![CoddHistoryRow]
  }
  deriving stock (Generic, Eq, Show)

data CoddDefinitionError
  = EmptyCoddSelection
  | EmptyCoddFilename
  | DuplicateCoddFilename !FilePath
  | EmptyCoddImportReason
  | InvalidCoddManifestLine !Int
  | InvalidCoddManifestChecksum !Int !Text
  | DuplicateCoddManifestFilename !FilePath
  | CoddEvidenceDefinitionError !HistoryDefinitionError
  deriving stock (Generic, Eq, Show)

data CoddImportError
  = CoddDefinitionFailed !CoddDefinitionError
  | CoddConnectionFailed !Errors.ConnectionError
  | CoddSessionFailed !Errors.SessionError
  | CoddLockUnavailable !Int64
  | CoddUnlockFailed !Int64 !(Maybe CoddImportError) !(Maybe CoddImportError)
  | CoddLedgerMissing
  | CoddBothSchemasPresent
  | CoddUnsupportedShape !Text ![Text]
  | CoddDuplicateLedgerFilename !FilePath
  | CoddSelectedFilenameMissing !FilePath
  | CoddPartialMigration !FilePath
  | CoddStrictSourceHasUnselected ![FilePath]
  | CoddManifestEntryMissing !FilePath
  | CoddManifestHasUnexpected ![FilePath]
  | CoddSourcePayloadMissing !FilePath
  | CoddManifestChecksumMismatch !FilePath !Text !Text
  | CoddConfirmationRequired
  | CoddSamePayloadRequiresManifest
  | CoddHistoryDefinitionFailed !HistoryDefinitionError
  | CoddTargetImportFailed !HistoryImportError
  deriving stock (Generic, Show)

data CoddImportCommand = CoddImportCommand
  { sourceSettings :: !(Maybe Settings.Settings),
    lockKey :: !Int64,
    mappingPath :: !FilePath,
    manifestPath :: !(Maybe FilePath),
    sourceDirectory :: !(Maybe FilePath),
    strict :: !Bool,
    confirmation :: !Confirmation,
    outputFormat :: !OutputFormat
  }
  deriving stock (Generic, Eq, Show)

defaultCoddLockKey :: Int64
defaultCoddLockKey = 0x6B69726F6B754D67

coddSourceConfig ::
  ConnectionProvider ->
  NonEmpty FilePath ->
  Bool ->
  Map FilePath ByteString ->
  Maybe CoddManifest ->
  Text ->
  Confirmation ->
  Either CoddDefinitionError CoddSourceConfig
coddSourceConfig sourceProvider selectedFilenames strictSource sourcePayloads sourceManifest importReason confirmation = do
  let filenames = toList selectedFilenames
  case findDuplicate filenames of
    Just duplicate -> Left (DuplicateCoddFilename duplicate)
    Nothing -> pure ()
  if any null filenames then Left EmptyCoddFilename else pure ()
  if Text.null (Text.strip importReason) then Left EmptyCoddImportReason else pure ()
  pure
    CoddSourceConfig
      { sourceProvider,
        sourceLockKey = defaultCoddLockKey,
        selectedFilenames,
        strictSource,
        sourcePayloads,
        sourceManifest,
        importReason,
        confirmation
      }

withCoddLockKey :: Int64 -> CoddSourceConfig -> CoddSourceConfig
withCoddLockKey sourceLockKey config = config {sourceLockKey}

coddEvidenceKey :: FilePath -> Either CoddDefinitionError EvidenceKey
coddEvidenceKey filename
  | null filename = Left EmptyCoddFilename
  | otherwise =
      case evidenceKey ("codd:" <> Text.pack filename) of
        Left err -> Left (CoddEvidenceDefinitionError err)
        Right key -> Right key

findDuplicate :: (Ord value) => [value] -> Maybe value
findDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (value : remaining)
      | Set.member value seen = Just value
      | otherwise = go (Set.insert value seen) remaining
