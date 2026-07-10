module Database.PostgreSQL.Migrate.Definition
  ( IdentifierError (..),
    DefinitionError (..),
    componentName,
    migrationName,
    migrationId,
    migrationFingerprint,
    transactionMigration,
    sessionMigration,
    migrationComponent,
  )
where

import Crypto.Hash qualified as Hash
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as ByteString
import Data.Char qualified as Char
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate.Types
import Hasql.Session qualified as Hasql.Session
import Hasql.Transaction qualified as Hasql.Transaction
import PgMigrate.Prelude

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

data DefinitionError
  = InvalidComponentName
      { input :: !Text,
        reason :: !IdentifierError
      }
  | InvalidMigrationName
      { input :: !Text,
        reason :: !IdentifierError
      }
  deriving stock (Generic, Eq, Show)

componentName :: Text -> Either DefinitionError ComponentName
componentName input =
  ComponentName <$> first (InvalidComponentName input) (validateIdentifier input)

migrationName :: Text -> Either DefinitionError MigrationName
migrationName input =
  MigrationName <$> first (InvalidMigrationName input) (validateIdentifier input)

migrationId :: Text -> Text -> Either DefinitionError MigrationId
migrationId componentInput migrationInput =
  MigrationId
    <$> componentName componentInput
    <*> migrationName migrationInput

migrationFingerprint :: ByteString -> MigrationChecksum
migrationFingerprint bytes =
  MigrationChecksum
    (ByteArray.convert (Hash.hashWith Hash.SHA256 bytes))

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
