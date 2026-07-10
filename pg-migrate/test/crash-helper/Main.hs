module Main (main) where

import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Hasql.Connection.Settings qualified as Settings
import System.Environment (getArgs, lookupEnv)

main :: IO ()
main = do
  arguments <- getArgs
  connectionString <- lookupEnv "PG_CONNECTION_STRING"
  case (arguments, connectionString) of
    ([schema, rawLockKey], Just connection) -> do
      let config = requireRight (ledgerConfig (Text.pack schema) (read rawLockKey :: Int64))
      result <-
        runMigrationPlan
          (withLedger config defaultRunOptions)
          (Settings.connectionString (Text.pack connection))
          crashPlan
      case result of
        Left migrationError -> fail (show migrationError)
        Right _ -> pure ()
    _ -> fail "usage: pg-migrate-crash-helper SCHEMA LOCK_KEY with PG_CONNECTION_STRING set"

crashPlan :: MigrationPlan
crashPlan =
  requireRight
    ( migrationPlan
        ( requireRight
            ( migrationComponent
                "crash-helper"
                Set.empty
                ( requireRight
                    ( sqlMigration
                        "0001-sleep"
                        "-- pg-migrate: no-transaction\nSELECT pg_sleep(2)"
                    )
                    :| []
                )
            )
            :| []
        )
    )

requireRight :: (Show error) => Either error value -> value
requireRight = \case
  Left err -> error (show err)
  Right value -> value
