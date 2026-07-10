module Database.PostgreSQL.Migrate.Runner.Connection
  ( connectionProviderFromSettings,
    checkServerVersion,
    classifyServerVersion,
  )
where

import Control.Exception (finally, mask)
import Data.Int (Int32)
import Database.PostgreSQL.Migrate.Runner.Types
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement

-- | Acquire and release a fresh Hasql connection from concrete settings.
connectionProviderFromSettings :: Settings.Settings -> ConnectionProvider
connectionProviderFromSettings settings =
  ConnectionProvider $ \action ->
    mask $ \restore -> do
      acquired <- Connection.acquire settings
      case acquired of
        Left connectionError -> pure (Left connectionError)
        Right connection ->
          Right <$> restore (action connection) `finally` Connection.release connection

checkServerVersion :: Connection.Connection -> IO (Either MigrationError Int)
checkServerVersion connection = do
  result <- Connection.use connection (Session.statement () serverVersionStatement)
  pure $ case result of
    Left sessionError -> Left (DatabaseSessionFailed sessionError)
    Right serverVersion -> classifyServerVersion serverVersion

classifyServerVersion :: Int32 -> Either MigrationError Int
classifyServerVersion serverVersionNumber
  | majorVersion `elem` [17, 18] = Right majorVersion
  | otherwise = Left (UnsupportedPostgresVersion majorVersion)
  where
    majorVersion = fromIntegral serverVersionNumber `div` 10000

serverVersionStatement :: Statement () Int32
serverVersionStatement =
  Statement.preparable
    "SELECT current_setting('server_version_num')::integer"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int4)))
