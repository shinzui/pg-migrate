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

-- | Validated source connection, ledger names, manifest, and cooperating lock.
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

-- | Unordered expected SHA-256 checksums keyed by source filename.
newtype CoddManifest = CoddManifest
  { manifestChecksums :: Map FilePath Text
  }
  deriving stock (Generic, Eq, Show)

-- | Recognized Codd ledger shape from V1 through V5.
data CoddSchemaVersion
  = CoddV1
  | CoddV2
  | CoddV3
  | CoddV4
  | CoddV5
  deriving stock (Generic, Eq, Ord, Show)

-- | Normalized immutable row read from a supported Codd ledger.
data CoddHistoryRow = CoddHistoryRow
  { filename :: !FilePath,
    migrationTimestamp :: !UTCTime,
    appliedAt :: !(Maybe UTCTime),
    numAppliedStatements :: !Int32,
    noTransactionFailedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)

-- | Selected rows, schema shape, evidence, and unselected extras.
data CoddHistory = CoddHistory
  { schemaVersion :: !CoddSchemaVersion,
    selectedRows :: !(NonEmpty CoddHistoryRow),
    unselectedRows :: ![CoddHistoryRow]
  }
  deriving stock (Generic, Eq, Show)

-- | Invalid source identifiers, manifest, mappings, or adapter options.
data CoddDefinitionError
  = EmptyCoddFilename
  | DuplicateCoddFilename !FilePath
  | EmptyCoddImportReason
  | InvalidCoddManifestLine !Int
  | InvalidCoddManifestChecksum !Int !Text
  | DuplicateCoddManifestFilename !FilePath
  | CoddEvidenceDefinitionError !HistoryDefinitionError
  deriving stock (Generic, Eq, Show)

-- | Structured source-read, validation, lock, or target-import failure.
--
-- In 'CoddUnlockFailed', the first optional error is the primary source-read or
-- import failure. The second is the unlock session failure; it is 'Nothing' when
-- @pg_advisory_unlock@ returned false rather than raising a session error.
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

-- | Parsed, application-dispatchable Codd import command.
data CoddImportCommand = CoddImportCommand
  { sourceSettings :: !(Maybe Settings.Settings),
    lockKey :: !Int64,
    mappingPath :: !FilePath,
    manifestPath :: !(Maybe FilePath),
    sourceDirectory :: !(Maybe FilePath),
    strict :: !Bool,
    confirmation :: !Confirmation,
    allowEquivalent :: !Bool,
    outputFormat :: !OutputFormat
  }
  deriving stock (Generic, Eq, Show)

-- | Default advisory lock used to cooperate with Codd writers.
defaultCoddLockKey :: Int64
defaultCoddLockKey = 0x6B69726F6B754D67

-- | Validate a complete Codd source configuration.
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

-- | Override the cooperating source advisory lock key.
withCoddLockKey :: Int64 -> CoddSourceConfig -> CoddSourceConfig
withCoddLockKey sourceLockKey config = config {sourceLockKey}

-- | Derive the canonical evidence key for one manifest filename.
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
