module Database.PostgreSQL.Migrate.Runner.Lock
  ( acquireAdvisoryLock,
    releaseAdvisoryLock,
    applyStatementTimeout,
    restoreStatementTimeout,
    readStatementTimeout,
  )
where

import Control.Concurrent (threadDelay)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Data.Word (Word64)
import Database.PostgreSQL.Migrate.Runner.Types
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Errors
import Hasql.Session qualified as Session
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement

acquireAdvisoryLock ::
  Connection.Connection ->
  Int64 ->
  LockWait ->
  IO (Either MigrationError NominalDiffTime)
acquireAdvisoryLock connection lockKey lockWait = do
  started <- getMonotonicTimeNSec
  case lockWait of
    WaitIndefinitely -> pollIndefinitely started
    NoWait -> do
      result <- tryLock connection lockKey
      case result of
        Left sessionError -> pure (Left (DatabaseSessionFailed sessionError))
        Right False -> pure (Left AdvisoryLockUnavailable)
        Right True -> Right <$> elapsedSince started
    WaitFor timeout
      | timeout < 0 -> pure (Left (InvalidLockWait timeout))
      | otherwise -> pollUntil started timeout
  where
    pollIndefinitely started = do
      result <- tryLock connection lockKey
      case result of
        Left sessionError -> pure (Left (DatabaseSessionFailed sessionError))
        Right True -> Right <$> elapsedSince started
        Right False -> do
          threadDelay 50000
          pollIndefinitely started
    pollUntil started timeout = do
      result <- tryLock connection lockKey
      case result of
        Left sessionError -> pure (Left (DatabaseSessionFailed sessionError))
        Right True -> Right <$> elapsedSince started
        Right False -> do
          elapsed <- elapsedSince started
          if elapsed >= timeout
            then pure (Left (AdvisoryLockTimedOut timeout))
            else do
              threadDelay (pollDelayMicroseconds timeout elapsed)
              pollUntil started timeout

releaseAdvisoryLock ::
  Connection.Connection ->
  Int64 ->
  IO (Either CleanupIssue ())
releaseAdvisoryLock connection lockKey = do
  result <- Connection.use connection (Session.statement lockKey unlockStatement)
  pure $ case result of
    Left sessionError -> Left (AdvisoryUnlockFailed sessionError)
    Right False -> Left AdvisoryUnlockReturnedFalse
    Right True -> Right ()

applyStatementTimeout ::
  Connection.Connection ->
  Maybe NominalDiffTime ->
  IO (Either MigrationError (Maybe Text))
applyStatementTimeout _ Nothing = pure (Right Nothing)
applyStatementTimeout connection (Just timeout)
  | timeout < 0 = pure (Left (InvalidStatementTimeout timeout))
  | otherwise = do
      result <-
        Connection.use connection $ do
          previous <- Session.statement () currentStatementTimeoutStatement
          _ <- Session.statement (formatStatementTimeout timeout) setStatementTimeoutStatement
          pure previous
      pure $ case result of
        Left sessionError -> Left (DatabaseSessionFailed sessionError)
        Right previous -> Right (Just previous)

restoreStatementTimeout ::
  Connection.Connection ->
  Maybe Text ->
  IO (Either CleanupIssue ())
restoreStatementTimeout _ Nothing = pure (Right ())
restoreStatementTimeout connection (Just previous) = do
  result <- Connection.use connection (Session.statement previous setStatementTimeoutStatement)
  pure $ case result of
    Left sessionError -> Left (StatementTimeoutRestoreFailed sessionError)
    Right _ -> Right ()

readStatementTimeout :: Connection.Connection -> IO (Either MigrationError Text)
readStatementTimeout connection = do
  result <- Connection.use connection (Session.statement () currentStatementTimeoutStatement)
  pure $ case result of
    Left sessionError -> Left (DatabaseSessionFailed sessionError)
    Right value -> Right value

tryLock :: Connection.Connection -> Int64 -> IO (Either Errors.SessionError Bool)
tryLock connection lockKey =
  Connection.use connection (Session.statement lockKey tryLockStatement)

elapsedSince :: Word64 -> IO NominalDiffTime
elapsedSince started = do
  finished <- getMonotonicTimeNSec
  pure (realToFrac (fromIntegral (finished - started) / (1000000000 :: Double)))

pollDelayMicroseconds :: NominalDiffTime -> NominalDiffTime -> Int
pollDelayMicroseconds timeout elapsed =
  max 1 (min 50000 (floor (realToFrac (timeout - elapsed) * (1000000 :: Double))))

formatStatementTimeout :: NominalDiffTime -> Text
formatStatementTimeout timeout =
  Text.pack (show milliseconds) <> "ms"
  where
    milliseconds
      | timeout == 0 = 0 :: Integer
      | otherwise = ceiling (realToFrac timeout * (1000 :: Double))

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

currentStatementTimeoutStatement :: Statement () Text
currentStatementTimeoutStatement =
  Statement.preparable
    "SELECT current_setting('statement_timeout')"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))

setStatementTimeoutStatement :: Statement Text Text
setStatementTimeoutStatement =
  Statement.preparable
    "SELECT set_config('statement_timeout', $1, false)"
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.text)))
