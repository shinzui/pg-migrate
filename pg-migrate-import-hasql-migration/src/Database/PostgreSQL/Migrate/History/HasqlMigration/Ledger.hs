module Database.PostgreSQL.Migrate.History.HasqlMigration.Ledger
  ( readHasqlMigrationHistory,
    validateHasqlMigrationRows,
    renderQualifiedTable,
  )
where

import Crypto.Hash (MD5 (..), hashWith)
import Data.Bifunctor (first)
import Data.ByteArray.Encoding (Base (Base64), convertToBase)
import Data.Functor.Contravariant ((>$<))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate.History.HasqlMigration.Types
import Database.PostgreSQL.Migrate.Internal
  ( PostgresIdentifier (..),
    quotePostgresIdentifier,
    useConnectionProvider,
  )
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import PgMigrate.History.HasqlMigration.Prelude

-- | Read source rows and reproduce their base64 MD5 without source mutation.
readHasqlMigrationHistory :: HasqlMigrationSourceConfig -> IO (Either HasqlMigrationImportError HasqlMigrationHistory)
readHasqlMigrationHistory config@HasqlMigrationSourceConfig {sourceProvider, sourceTable} = do
  acquired <-
    useConnectionProvider sourceProvider $ \connection -> do
      detected <- runSession connection (Session.statement (qualifiedTableParts sourceTable) detectTableStatement)
      case detected of
        Left err -> pure (Left err)
        Right [] -> pure (Left (HasqlMigrationTableMissing (renderQualifiedTable sourceTable)))
        Right columns
          | columns /= expectedColumns ->
              pure (Left (HasqlMigrationUnsupportedShape (renderQualifiedTable sourceTable) columns))
          | otherwise -> do
              loaded <- runSession connection (Session.statement () (loadRowsStatement sourceTable))
              pure (loaded >>= validateHasqlMigrationRows config)
  pure $ case acquired of
    Left connectionError -> Left (HasqlMigrationConnectionFailed connectionError)
    Right result -> result

expectedColumns :: [Text]
expectedColumns = ["filename", "checksum", "executed_at"]

validateHasqlMigrationRows ::
  HasqlMigrationSourceConfig ->
  [HasqlMigrationRow] ->
  Either HasqlMigrationImportError HasqlMigrationHistory
validateHasqlMigrationRows HasqlMigrationSourceConfig {selectedFilenames, strictSource, sourcePayloads} rows = do
  case firstDuplicate (filename <$> rows) of
    Just duplicate -> Left (HasqlMigrationDuplicateLedgerFilename duplicate)
    Nothing -> pure ()
  selected <- traverse selectRow selectedFilenames
  traverse_ verifyChecksum selected
  let selectedSet = Set.fromList (toList selectedFilenames)
      extras = filter ((`Set.notMember` selectedSet) . filename) rows
  if strictSource && not (null extras)
    then Left (HasqlMigrationStrictSourceHasUnselected (filename <$> extras))
    else Right HasqlMigrationHistory {selectedRows = selected, unselectedRows = extras}
  where
    byFilename = Map.fromList [(filename row, row) | row <- rows]
    selectRow selected =
      maybe (Left (HasqlMigrationSelectedFilenameMissing selected)) Right (Map.lookup selected byFilename)
    verifyChecksum row = do
      payloadBytes <-
        maybe
          (Left (HasqlMigrationDefinitionFailed (MissingHasqlMigrationPayload (filename row))))
          Right
          (Map.lookup (filename row) sourcePayloads)
      let actual = legacyMd5 payloadBytes
      if storedMd5 row == actual
        then Right ()
        else Left (HasqlMigrationChecksumMismatch (filename row) (storedMd5 row) actual)

legacyMd5 :: ByteString -> Text
legacyMd5 = Text.Encoding.decodeUtf8 . convertToBase Base64 . hashWith MD5

renderQualifiedTable :: QualifiedTable -> Text
renderQualifiedTable QualifiedTable {tableSchema, tableName} =
  quotePostgresIdentifier tableSchema <> "." <> quotePostgresIdentifier tableName

qualifiedTableParts :: QualifiedTable -> (Text, Text)
qualifiedTableParts QualifiedTable {tableSchema = PostgresIdentifier schemaName, tableName = PostgresIdentifier relationName} =
  (schemaName, relationName)

detectTableStatement :: Statement (Text, Text) [Text]
detectTableStatement =
  Statement.preparable
    "SELECT a.attname::text FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON a.attrelid = c.oid JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum >= 1 AND NOT a.attisdropped ORDER BY a.attnum"
    ( (fst >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> (snd >$< Encoders.param (Encoders.nonNullable Encoders.text))
    )
    (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))

loadRowsStatement :: QualifiedTable -> Statement () [HasqlMigrationRow]
loadRowsStatement sourceTable =
  Statement.unpreparable
    ("SELECT filename, checksum, executed_at FROM " <> renderQualifiedTable sourceTable <> " ORDER BY executed_at, filename")
    Encoders.noParams
    (Decoders.rowList rowDecoder)
  where
    rowDecoder =
      HasqlMigrationRow
        <$> (Text.unpack <$> required Decoders.text)
        <*> required Decoders.text
        <*> required Decoders.timestamp
    required = Decoders.column . Decoders.nonNullable

runSession :: Connection.Connection -> Session.Session value -> IO (Either HasqlMigrationImportError value)
runSession connection session = first HasqlMigrationSessionFailed <$> Connection.use connection session

firstDuplicate :: (Ord value) => [value] -> Maybe value
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (value : rest)
      | Set.member value seen = Just value
      | otherwise = go (Set.insert value seen) rest
