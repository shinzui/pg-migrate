module Database.PostgreSQL.Migrate.Test
  ( MigratedDatabaseError (..),
    withMigratedDatabase,
    withMigratedDatabaseOptions,
    withMigratedDatabaseConfig,
  )
where

import Control.Exception (SomeException)
import Control.Exception qualified as Exception
import Database.PostgreSQL.Migrate
import EphemeralPg qualified
import Hasql.Connection qualified as Connection
import Hasql.Errors qualified as Errors

data MigratedDatabaseError
  = MigratedDatabaseStartupFailed !EphemeralPg.StartError
  | MigratedDatabaseMigrationFailed !MigrationError
  | MigratedDatabaseCallbackAcquisitionFailed !Errors.ConnectionError
  | MigratedDatabaseCallbackFailed !SomeException
  | MigratedDatabaseCallbackCleanupFailed !SomeException
  | MigratedDatabaseCallbackAndCleanupFailed !SomeException !SomeException
  deriving stock (Show)

withMigratedDatabase ::
  MigrationPlan ->
  (Connection.Connection -> IO value) ->
  IO (Either MigratedDatabaseError value)
withMigratedDatabase = withMigratedDatabaseOptions defaultRunOptions

withMigratedDatabaseOptions ::
  RunOptions ->
  MigrationPlan ->
  (Connection.Connection -> IO value) ->
  IO (Either MigratedDatabaseError value)
withMigratedDatabaseOptions = withMigratedDatabaseConfig EphemeralPg.defaultConfig

withMigratedDatabaseConfig ::
  EphemeralPg.Config ->
  RunOptions ->
  MigrationPlan ->
  (Connection.Connection -> IO value) ->
  IO (Either MigratedDatabaseError value)
withMigratedDatabaseConfig config options plan callback = do
  started <-
    EphemeralPg.withConfig config $ \database -> do
      let settings = EphemeralPg.connectionSettings database
      migrated <- runMigrationPlan options settings plan
      case migrated of
        Left migrationError -> pure (Left (MigratedDatabaseMigrationFailed migrationError))
        Right _ -> do
          acquired <- Connection.acquire settings
          case acquired of
            Left connectionError -> pure (Left (MigratedDatabaseCallbackAcquisitionFailed connectionError))
            Right connection -> runCallback connection callback
  pure $ case started of
    Left startError -> Left (MigratedDatabaseStartupFailed startError)
    Right result -> result

runCallback ::
  Connection.Connection ->
  (Connection.Connection -> IO value) ->
  IO (Either MigratedDatabaseError value)
runCallback connection callback =
  Exception.mask $ \restore -> do
    callbackResult <- Exception.try (restore (callback connection))
    cleanupResult <- Exception.try (Connection.release connection)
    pure $ case (callbackResult, cleanupResult) of
      (Right value, Right ()) -> Right value
      (Left callbackError, Right ()) -> Left (MigratedDatabaseCallbackFailed callbackError)
      (Right _, Left cleanupError) -> Left (MigratedDatabaseCallbackCleanupFailed cleanupError)
      (Left callbackError, Left cleanupError) ->
        Left (MigratedDatabaseCallbackAndCleanupFailed callbackError cleanupError)
