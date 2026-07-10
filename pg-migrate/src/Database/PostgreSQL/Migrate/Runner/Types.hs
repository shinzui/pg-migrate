{-# LANGUAGE RankNTypes #-}

module Database.PostgreSQL.Migrate.Runner.Types
  ( RunOptions (..),
    defaultRunOptions,
    withLedger,
    withLockWait,
    withStatementTimeout,
    withUnknownMigrationsPolicy,
    withEventHandler,
    runLedgerConfig,
    runLockWait,
    runStatementTimeout,
    runUnknownMigrationsPolicy,
    runEventHandler,
    LockWait (..),
    MigrationEvent (..),
    MigrationOutcome (..),
    MigrationResult (..),
    MigrationReport (..),
    CleanupIssue (..),
    MigrationError (..),
    ConnectionProvider (..),
    connectionProvider,
  )
where

import Control.Exception (SomeException)
import Data.Time (NominalDiffTime, UTCTime)
import Database.PostgreSQL.Migrate.Ledger.Types
import Database.PostgreSQL.Migrate.Types
import Hasql.Connection qualified as Connection
import Hasql.Errors qualified as Errors
import PgMigrate.Prelude

data RunOptions = RunOptions
  { ledger :: !LedgerConfig,
    lockWait :: !LockWait,
    statementTimeout :: !(Maybe NominalDiffTime),
    unknownMigrations :: !UnknownMigrationsPolicy,
    emit :: !(MigrationEvent -> IO ())
  }

data LockWait
  = WaitIndefinitely
  | WaitFor !NominalDiffTime
  | NoWait
  deriving stock (Generic, Eq, Ord, Show)

data MigrationEvent
  = LockWaitStarted !LockWait
  | LockAcquired !NominalDiffTime
  | PlanValidated
      { alreadyAppliedCount :: !Int,
        pendingCount :: !Int
      }
  | MigrationStarted !MigrationId
  | MigrationCompleted !MigrationId !NominalDiffTime
  | MigrationFailureObserved !MigrationId !NominalDiffTime
  | MigrationPlanCompleted !NominalDiffTime
  deriving stock (Generic, Eq, Show)

data MigrationOutcome
  = AlreadyApplied
  | AppliedNow
  deriving stock (Generic, Eq, Ord, Show)

data MigrationResult = MigrationResult
  { migration :: !MigrationId,
    outcome :: !MigrationOutcome,
    duration :: !(Maybe NominalDiffTime)
  }
  deriving stock (Generic, Eq, Show)

data MigrationReport = MigrationReport
  { startedAt :: !UTCTime,
    finishedAt :: !UTCTime,
    results :: !(NonEmpty MigrationResult)
  }
  deriving stock (Generic, Eq, Show)

data CleanupIssue
  = AdvisoryUnlockReturnedFalse
  | AdvisoryUnlockFailed !Errors.SessionError
  | StatementTimeoutRestoreFailed !Errors.SessionError
  deriving stock (Generic, Show)

data MigrationError
  = ConnectionAcquisitionFailed !Errors.ConnectionError
  | DatabaseSessionFailed !Errors.SessionError
  | UnsupportedPostgresVersion !Int
  | InvalidLockWait !NominalDiffTime
  | InvalidStatementTimeout !NominalDiffTime
  | AdvisoryLockUnavailable
  | AdvisoryLockTimedOut !NominalDiffTime
  | LedgerInitializationFailed !LedgerError
  | PlanVerificationFailed !VerificationReport
  | UnsupportedNonTransactionalMigration !MigrationId
  | TransactionCondemned !MigrationId
  | EventHandlerFailed !(Maybe MigrationError) !SomeException
  | MigrationActionFailed !SomeException
  | InvalidMigrationAction !MigrationId
  | CleanupFailed !(Maybe MigrationError) !(NonEmpty CleanupIssue)
  deriving stock (Generic, Show)

newtype ConnectionProvider = ConnectionProvider
  { useDedicatedConnection ::
      forall a.
      (Connection.Connection -> IO a) ->
      IO (Either Errors.ConnectionError a)
  }

defaultRunOptions :: RunOptions
defaultRunOptions =
  RunOptions
    { ledger = defaultLedgerConfig,
      lockWait = WaitIndefinitely,
      statementTimeout = Nothing,
      unknownMigrations = RejectUnknownMigrations,
      emit = const (pure ())
    }

withLedger :: LedgerConfig -> RunOptions -> RunOptions
withLedger ledger options = options {ledger}

withLockWait :: LockWait -> RunOptions -> RunOptions
withLockWait lockWait options = options {lockWait}

withStatementTimeout :: Maybe NominalDiffTime -> RunOptions -> RunOptions
withStatementTimeout statementTimeout options = options {statementTimeout}

withUnknownMigrationsPolicy :: UnknownMigrationsPolicy -> RunOptions -> RunOptions
withUnknownMigrationsPolicy unknownMigrations RunOptions {ledger, lockWait, statementTimeout, emit} =
  RunOptions {ledger, lockWait, statementTimeout, unknownMigrations, emit}

withEventHandler :: (MigrationEvent -> IO ()) -> RunOptions -> RunOptions
withEventHandler emit options = options {emit}

runLedgerConfig :: RunOptions -> LedgerConfig
runLedgerConfig RunOptions {ledger} = ledger

runLockWait :: RunOptions -> LockWait
runLockWait RunOptions {lockWait} = lockWait

runStatementTimeout :: RunOptions -> Maybe NominalDiffTime
runStatementTimeout RunOptions {statementTimeout} = statementTimeout

runUnknownMigrationsPolicy :: RunOptions -> UnknownMigrationsPolicy
runUnknownMigrationsPolicy RunOptions {unknownMigrations} = unknownMigrations

runEventHandler :: RunOptions -> MigrationEvent -> IO ()
runEventHandler RunOptions {emit} = emit

connectionProvider ::
  ( forall a.
    (Connection.Connection -> IO a) ->
    IO (Either Errors.ConnectionError a)
  ) ->
  ConnectionProvider
connectionProvider = ConnectionProvider
