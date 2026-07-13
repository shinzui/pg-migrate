-- | Test-only ephemeral PostgreSQL lifecycle. A validated plan is applied before a fresh
-- Hasql connection is bracketed around the caller's assertion callback.
module Database.PostgreSQL.Migrate.Test
  ( -- | Structured startup, migration, callback, and callback-plus-cleanup failures.
    MigratedDatabaseError (..),
    -- | Start a database, apply a plan with default runner options, and run a callback.
    withMigratedDatabase,
    -- | As 'withMigratedDatabase', with explicit runner options.
    withMigratedDatabaseOptions,
    -- | Fully configurable ephemeral-database variant.
    withMigratedDatabaseConfig,
  )
where

import Control.Exception (SomeException)
import Control.Exception qualified as Exception
import Database.PostgreSQL.Migrate
import EphemeralPg qualified
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Errors qualified as Errors

-- | Structured failures from the ephemeral database, migration, callback, or a callback
-- failure accompanied by a connection-release failure. A release failure after a
-- successful callback does not replace its value.
data MigratedDatabaseError
  = MigratedDatabaseStartupFailed !EphemeralPg.StartError
  | MigratedDatabaseMigrationFailed !MigrationError
  | MigratedDatabaseCallbackAcquisitionFailed !Errors.ConnectionError
  | MigratedDatabaseCallbackFailed !SomeException
  | MigratedDatabaseCallbackAndCleanupFailed !SomeException !SomeException
  deriving stock (Show)

-- | Start a database, migrate it with 'defaultRunOptions', and bracket a callback connection.
withMigratedDatabase ::
  MigrationPlan ->
  (Connection.Connection -> IO value) ->
  IO (Either MigratedDatabaseError value)
withMigratedDatabase = withMigratedDatabaseOptions defaultRunOptions

-- | Start a database, migrate it with the supplied options, and bracket a callback connection.
withMigratedDatabaseOptions ::
  RunOptions ->
  MigrationPlan ->
  (Connection.Connection -> IO value) ->
  IO (Either MigratedDatabaseError value)
withMigratedDatabaseOptions = withMigratedDatabaseConfig EphemeralPg.defaultConfig

-- | Fully configurable variant accepting both ephemeral database and migration options.
-- Asynchronous callback exceptions are rethrown after releasing the callback connection.
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
        Right _ -> runCallback settings callback
  pure $ case started of
    Left startError -> Left (MigratedDatabaseStartupFailed startError)
    Right result -> result

runCallback ::
  Settings.Settings ->
  (Connection.Connection -> IO value) ->
  IO (Either MigratedDatabaseError value)
runCallback settings callback =
  Exception.mask $ \restore -> do
    acquired <- Connection.acquire settings
    case acquired of
      Left connectionError -> pure (Left (MigratedDatabaseCallbackAcquisitionFailed connectionError))
      Right connection -> do
        callbackResult <- Exception.try @SomeException (restore (callback connection))
        cleanupResult <- Exception.try @SomeException (Connection.release connection)
        case callbackResult of
          Left callbackError
            | Just _ <- Exception.fromException @Exception.SomeAsyncException callbackError ->
                Exception.throwIO callbackError
          _ ->
            pure $ case (callbackResult, cleanupResult) of
              (Right value, _) -> Right value
              (Left callbackError, Right ()) -> Left (MigratedDatabaseCallbackFailed callbackError)
              (Left callbackError, Left cleanupError) ->
                Left (MigratedDatabaseCallbackAndCleanupFailed callbackError cleanupError)
