module Database.PostgreSQL.Migrate.Definition
  ( IdentifierError (..),
    PostgresIdentifierError (..),
    DefinitionError (..),
    componentName,
    migrationName,
    migrationId,
    migrationFingerprint,
    sqlMigration,
    transactionMigration,
    sessionMigration,
    migrationComponent,
    migrationComponentFromEmbeddedSql,
  )
where

import Crypto.Hash qualified as Hash
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as ByteString
import Data.Char qualified as Char
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate.Sql
  ( SqlError,
    sqlScanTransactionMode,
    validateSql,
  )
import Database.PostgreSQL.Migrate.Types
import Hasql.Session qualified as Hasql.Session
import Hasql.Transaction qualified as Hasql.Transaction
import PgMigrate.Prelude

-- | Reason a component or migration identifier was rejected.
data IdentifierError
  = EmptyIdentifier
  | IdentifierHasSurroundingWhitespace
  | IdentifierContainsSlash
  | IdentifierTooLong
      { actualBytes :: !Int,
        maximumBytes :: !Int
      }
  | IdentifierContainsNonPrintableAscii !Char
  deriving stock (Generic, Eq, Show)

-- | Reason a PostgreSQL schema identifier was rejected.
data PostgresIdentifierError
  = EmptyPostgresIdentifier
  | PostgresIdentifierContainsNul
  | PostgresIdentifierHasReservedPrefix
  | PostgresIdentifierTooLong
      { actualBytes :: !Int,
        maximumBytes :: !Int
      }
  deriving stock (Generic, Eq, Show)

-- | Structured failure from a public smart constructor.
data DefinitionError
  = InvalidComponentName
      { input :: !Text,
        reason :: !IdentifierError
      }
  | InvalidMigrationName
      { input :: !Text,
        reason :: !IdentifierError
      }
  | InvalidSql !SqlError
  | InvalidEmbeddedMigrationFile
      { file :: !FilePath
      }
  | InvalidLedgerSchema
      { input :: !Text,
        postgresIdentifierReason :: !PostgresIdentifierError
      }
  deriving stock (Generic, Eq, Show)

-- | Validate a component identifier.
componentName :: Text -> Either DefinitionError ComponentName
componentName input =
  ComponentName <$> first (InvalidComponentName input) (validateIdentifier input)

-- | Validate a migration identifier.
migrationName :: Text -> Either DefinitionError MigrationName
migrationName input =
  MigrationName <$> first (InvalidMigrationName input) (validateIdentifier input)

-- | Validate and combine component and migration identifiers.
migrationId :: Text -> Text -> Either DefinitionError MigrationId
migrationId componentInput migrationInput =
  MigrationId
    <$> componentName componentInput
    <*> migrationName migrationInput

-- | Compute the canonical SHA-256 fingerprint of exact payload bytes.
migrationFingerprint :: ByteString -> MigrationChecksum
migrationFingerprint bytes =
  MigrationChecksum
    (ByteArray.convert (Hash.hashWith Hash.SHA256 bytes))

-- | Validate SQL and derive its transaction mode and exact-byte checksum.
sqlMigration :: Text -> ByteString -> Either DefinitionError Migration
sqlMigration nameInput sqlBytes = do
  name <- migrationName nameInput
  sqlScan <- first InvalidSql (validateSql sqlBytes)
  pure
    Migration
      { name,
        description = Nothing,
        mode = sqlScanTransactionMode sqlScan,
        kind = SqlKind,
        checksum = migrationFingerprint sqlBytes,
        action = SqlAction sqlBytes
      }

-- | Define a transactional Haskell migration with an explicit fingerprint.
transactionMigration ::
  Text ->
  MigrationChecksum ->
  Hasql.Transaction.Transaction () ->
  Either DefinitionError Migration
transactionMigration nameInput checksum action = do
  name <- migrationName nameInput
  pure
    Migration
      { name,
        description = Nothing,
        mode = Transactional,
        kind = HaskellKind,
        checksum,
        action = TransactionAction action
      }

-- | Define a nontransactional session migration with an explicit fingerprint.
sessionMigration ::
  Text ->
  MigrationChecksum ->
  Hasql.Session.Session () ->
  Either DefinitionError Migration
sessionMigration nameInput checksum action = do
  name <- migrationName nameInput
  pure
    Migration
      { name,
        description = Nothing,
        mode = NonTransactional,
        kind = HaskellKind,
        checksum,
        action = SessionAction action
      }

-- | Define a component with validated dependency names and ordered migrations.
migrationComponent ::
  Text ->
  Set Text ->
  NonEmpty Migration ->
  Either DefinitionError MigrationComponent
migrationComponent nameInput dependencyInputs migrations = do
  name <- componentName nameInput
  dependencies <-
    Set.fromList <$> traverse componentName (Set.toAscList dependencyInputs)
  pure MigrationComponent {name, dependencies, migrations}

-- | Define a component from ordered @.sql@ names and exact embedded bytes.
migrationComponentFromEmbeddedSql ::
  Text ->
  Set Text ->
  NonEmpty (FilePath, ByteString) ->
  Either DefinitionError MigrationComponent
migrationComponentFromEmbeddedSql nameInput dependencyInputs entries = do
  migrations <- traverse migrationFromEntry entries
  migrationComponent nameInput dependencyInputs migrations
  where
    migrationFromEntry (file, sqlBytes) = do
      localName <-
        maybe
          (Left (InvalidEmbeddedMigrationFile file))
          Right
          (Text.stripSuffix ".sql" (Text.pack file))
      sqlMigration localName sqlBytes

validateIdentifier :: Text -> Either IdentifierError Text
validateIdentifier value
  | Text.null value = Left EmptyIdentifier
  | Text.strip value /= value = Left IdentifierHasSurroundingWhitespace
  | Text.any (== '/') value = Left IdentifierContainsSlash
  | byteLength > maximumIdentifierBytes =
      Left
        IdentifierTooLong
          { actualBytes = byteLength,
            maximumBytes = maximumIdentifierBytes
          }
  | Just invalidCharacter <- Text.find (not . isPrintableAscii) value =
      Left (IdentifierContainsNonPrintableAscii invalidCharacter)
  | otherwise = Right value
  where
    byteLength = ByteString.length (Text.Encoding.encodeUtf8 value)

maximumIdentifierBytes :: Int
maximumIdentifierBytes = 200

isPrintableAscii :: Char -> Bool
isPrintableAscii character =
  let codePoint = Char.ord character
   in codePoint >= 0x20 && codePoint <= 0x7E
