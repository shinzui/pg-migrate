module Database.PostgreSQL.Migrate.History.Codd.Parser
  ( coddImportCommandParser,
  )
where

import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
  ( Confirmation (..),
    MigrationPlan,
  )
import Database.PostgreSQL.Migrate.CLI (OutputFormat (..))
import Database.PostgreSQL.Migrate.History.Codd.Types
import Hasql.Connection.Settings qualified as Settings
import Numeric qualified
import Options.Applicative
import PgMigrate.History.Codd.Prelude
import Text.Read qualified as Read

-- | Build the reusable Codd import parser; the plan parameter is reserved.
coddImportCommandParser :: MigrationPlan -> Parser CoddImportCommand
coddImportCommandParser _ =
  CoddImportCommand
    <$> parserOptionGroup
      "Connection"
      ( optional
          ( option
              (Settings.connectionString . Text.pack <$> str)
              (long "source-database-url" <> metavar "URL" <> help "Codd source connection string; no environment variable is read")
          )
      )
    <*> option
      lockKeyReader
      ( long "source-lock-key"
          <> metavar "INT64"
          <> value defaultCoddLockKey
          <> showDefault
          <> help "Cooperating legacy wrapper advisory-lock key (decimal or 0x hexadecimal)"
      )
    <*> strOption (long "mapping" <> metavar "PATH" <> help "Checked-in source-to-target mapping artifact")
    <*> optional (strOption (long "manifest" <> metavar "PATH" <> help "Optional lowercase SHA-256 migrations.lock evidence"))
    <*> optional (strOption (long "source-directory" <> metavar "PATH" <> help "Directory containing exact selected Codd SQL payloads"))
    <*> switch (long "strict-source" <> help "Reject every unselected source row and unexpected manifest entry")
    <*> flag NotConfirmed Confirmed (long "confirm" <> help "Confirm Codd source evidence when SamePayload is mapped")
    <*> switch (long "allow-equivalent" <> help "Opt in to mappings proven by read-only state validators")
    <*> flag TextOutput JsonOutput (long "json" <> help "Emit JSON schema version 1 conventions")

lockKeyReader :: ReadM Int64
lockKeyReader = eitherReader $ \input ->
  case input of
    '0' : 'x' : hexadecimal ->
      case (Numeric.readHex hexadecimal :: [(Integer, String)]) of
        [(parsed, "")] -> checkedInt64 parsed
        _ -> Left "expected an Int64 decimal or 0x hexadecimal advisory-lock key"
    _ ->
      case (Read.readMaybe input :: Maybe Integer) of
        Just parsed -> checkedInt64 parsed
        Nothing -> Left "expected an Int64 decimal or 0x hexadecimal advisory-lock key"
  where
    checkedInt64 parsed
      | parsed < toInteger (minBound :: Int64) = Left rangeError
      | parsed > toInteger (maxBound :: Int64) = Left rangeError
      | otherwise = Right (fromInteger parsed)

    rangeError = "expected an Int64 decimal or 0x hexadecimal advisory-lock key"
