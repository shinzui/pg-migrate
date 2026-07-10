module Database.PostgreSQL.Migrate.History.Codd.Ledger
  ( readCoddHistory,
    withLockedCoddHistory,
    readCoddHistoryOnConnection,
    classifyCoddSchema,
    validateCoddRows,
  )
where

import Control.Exception qualified as Exception
import Data.Bifunctor (first)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate.History.Codd.Types
import Database.PostgreSQL.Migrate.Internal (useConnectionProvider)
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import PgMigrate.History.Codd.Prelude

readCoddHistory :: CoddSourceConfig -> IO (Either CoddImportError CoddHistory)
readCoddHistory config = withLockedCoddHistory config (readCoddHistoryOnConnection config)

withLockedCoddHistory ::
  CoddSourceConfig ->
  (Connection.Connection -> IO (Either CoddImportError value)) ->
  IO (Either CoddImportError value)
withLockedCoddHistory CoddSourceConfig {sourceProvider, sourceLockKey} action = do
  acquired <-
    useConnectionProvider sourceProvider $ \connection ->
      Exception.mask $ \restore -> do
        locked <- runSession connection (Session.statement sourceLockKey tryLockStatement)
        case locked of
          Left err -> pure (Left err)
          Right False -> pure (Left (CoddLockUnavailable sourceLockKey))
          Right True -> do
            primary <-
              restore (action connection)
                `Exception.onException` releaseIgnoringFailure connection sourceLockKey
            unlocked <- runSession connection (Session.statement sourceLockKey unlockStatement)
            pure $ case unlocked of
              Right True -> primary
              Right False -> Left (CoddUnlockFailed sourceLockKey (either Just (const Nothing) primary) Nothing)
              Left cleanupFailure ->
                Left
                  ( CoddUnlockFailed
                      sourceLockKey
                      (either Just (const Nothing) primary)
                      (Just cleanupFailure)
                  )
  pure $ case acquired of
    Left connectionError -> Left (CoddConnectionFailed connectionError)
    Right result -> result

releaseIgnoringFailure :: Connection.Connection -> Int64 -> IO ()
releaseIgnoringFailure connection lockKey = do
  _ <- Connection.use connection (Session.statement lockKey unlockStatement)
  pure ()

readCoddHistoryOnConnection ::
  CoddSourceConfig ->
  Connection.Connection ->
  IO (Either CoddImportError CoddHistory)
readCoddHistoryOnConnection config connection = do
  detected <- runSession connection (Session.statement () detectColumnsStatement)
  case detected >>= classifyCoddSchema of
    Left err -> pure (Left err)
    Right (version, schemaName) -> do
      loaded <- runSession connection (Session.statement () (loadRowsStatement version schemaName))
      pure (loaded >>= validateCoddRows config version)

classifyCoddSchema :: [(Text, Text)] -> Either CoddImportError (CoddSchemaVersion, Text)
classifyCoddSchema qualifiedColumns =
  case (Map.lookup "codd_schema" grouped, Map.lookup "codd" grouped) of
    (Nothing, Nothing) -> Left CoddLedgerMissing
    (Just _, Just _) -> Left CoddBothSchemasPresent
    (Just columns, Nothing) -> classifyLegacy columns
    (Nothing, Just columns)
      | columns == v4Columns -> Right (CoddV5, "codd")
      | otherwise -> Left (CoddUnsupportedShape "codd" columns)
  where
    grouped = Map.fromListWith (flip (<>)) [(schema, [column]) | (schema, column) <- qualifiedColumns]
    classifyLegacy columns
      | columns == v1Columns = Right (CoddV1, "codd_schema")
      | columns == v2Columns = Right (CoddV2, "codd_schema")
      | columns == v3Columns = Right (CoddV3, "codd_schema")
      | columns == v4Columns = Right (CoddV4, "codd_schema")
      | otherwise = Left (CoddUnsupportedShape "codd_schema" columns)

validateCoddRows ::
  CoddSourceConfig ->
  CoddSchemaVersion ->
  [CoddHistoryRow] ->
  Either CoddImportError CoddHistory
validateCoddRows CoddSourceConfig {selectedFilenames, strictSource} version rows = do
  case firstDuplicate (filename <$> rows) of
    Just duplicate -> Left (CoddDuplicateLedgerFilename duplicate)
    Nothing -> pure ()
  case List.find (\row -> isJust (noTransactionFailedAt row) || appliedAt row == Nothing) rows of
    Just partial -> Left (CoddPartialMigration (filename partial))
    Nothing -> pure ()
  selected <- traverse selectRow selectedFilenames
  let selectedSet = Set.fromList (toList selectedFilenames)
      unselectedRows = filter ((`Set.notMember` selectedSet) . filename) rows
  if strictSource && not (null unselectedRows)
    then Left (CoddStrictSourceHasUnselected (filename <$> unselectedRows))
    else Right CoddHistory {schemaVersion = version, selectedRows = selected, unselectedRows}
  where
    rowsByFilename = Map.fromList [(filename row, row) | row <- rows]
    selectRow selected =
      maybe (Left (CoddSelectedFilenameMissing selected)) Right (Map.lookup selected rowsByFilename)

firstDuplicate :: (Ord value) => [value] -> Maybe value
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (value : rest)
      | Set.member value seen = Just value
      | otherwise = go (Set.insert value seen) rest

detectColumnsStatement :: Statement () [(Text, Text)]
detectColumnsStatement =
  Statement.preparable
    "SELECT n.nspname::text, a.attname::text FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON a.attrelid = c.oid JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid WHERE c.relname = 'sql_migrations' AND n.nspname IN ('codd_schema', 'codd') AND a.attnum >= 1 AND NOT a.attisdropped ORDER BY n.nspname, a.attnum"
    Encoders.noParams
    (Decoders.rowList ((,) <$> required Decoders.text <*> required Decoders.text))
  where
    required = Decoders.column . Decoders.nonNullable

loadRowsStatement :: CoddSchemaVersion -> Text -> Statement () [CoddHistoryRow]
loadRowsStatement version schemaName =
  Statement.unpreparable
    ( Text.unwords
        [ "SELECT name, migration_timestamp, applied_at,",
          if version >= CoddV3 then "COALESCE(num_applied_statements, 0)::int4," else "0::int4,",
          if version >= CoddV3 then "no_txn_failed_at" else "NULL::timestamptz",
          "FROM " <> schemaName <> ".sql_migrations ORDER BY id"
        ]
    )
    Encoders.noParams
    (Decoders.rowList rowDecoder)
  where
    rowDecoder =
      CoddHistoryRow
        <$> (Text.unpack <$> required Decoders.text)
        <*> required Decoders.timestamptz
        <*> nullableColumn Decoders.timestamptz
        <*> required Decoders.int4
        <*> nullableColumn Decoders.timestamptz
    required = Decoders.column . Decoders.nonNullable
    nullableColumn = Decoders.column . Decoders.nullable

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

runSession :: Connection.Connection -> Session.Session value -> IO (Either CoddImportError value)
runSession connection session =
  first CoddSessionFailed <$> Connection.use connection session

v1Columns :: [Text]
v1Columns = ["id", "migration_timestamp", "applied_at", "name"]

v2Columns :: [Text]
v2Columns = v1Columns <> ["application_duration"]

v3Columns :: [Text]
v3Columns = v2Columns <> ["num_applied_statements", "no_txn_failed_at"]

v4Columns :: [Text]
v4Columns = v3Columns <> ["txnid", "connid"]
