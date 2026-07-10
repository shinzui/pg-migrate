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

-- | Immutable runner configuration; construct with 'defaultRunOptions' and modifiers.
data RunOptions = RunOptions
  { ledger :: !LedgerConfig,
    lockWait :: !LockWait,
    statementTimeout :: !(Maybe NominalDiffTime),
    unknownMigrations :: !UnknownMigrationsPolicy,
    emit :: !(MigrationEvent -> IO ())
  }

-- | Advisory-lock acquisition policy.
data LockWait
  = WaitIndefinitely
  | WaitFor !NominalDiffTime
  | NoWait
  deriving stock (Generic, Eq, Ord, Show)

-- | Ordered lifecycle observation emitted only at defined durable boundaries.
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

-- | Whether a migration pre-existed or committed during this run.
data MigrationOutcome
  = AlreadyApplied
  | AppliedNow
  deriving stock (Generic, Eq, Ord, Show)

-- | Outcome and optional execution duration for one migration.
data MigrationResult = MigrationResult
  { migration :: !MigrationId,
    outcome :: !MigrationOutcome,
    duration :: !(Maybe NominalDiffTime)
  }
  deriving stock (Generic, Eq, Show)

-- | Successful whole-plan execution report.
data MigrationReport = MigrationReport
  { startedAt :: !UTCTime,
    finishedAt :: !UTCTime,
    results :: !(NonEmpty MigrationResult)
  }
  deriving stock (Generic, Eq, Show)

-- | Resource restoration failure observed while leaving the runner lifecycle.
data CleanupIssue
  = AdvisoryUnlockReturnedFalse
  | AdvisoryUnlockFailed !Errors.SessionError
  | StatementTimeoutRestoreFailed !Errors.SessionError
  deriving stock (Generic, Show)

-- | Structured acquisition, validation, execution, event, or cleanup failure.
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
  | NonTransactionalMigrationFailed !MigrationId !Errors.SessionError
  | LedgerTransitionDidNotMatch !MigrationId !MigrationStatus !MigrationStatus
  | NonTransactionalFailureRecordingFailed !MigrationId !MigrationError !MigrationError
  | CleanupFailed !(Maybe MigrationError) !(NonEmpty CleanupIssue)
  deriving stock (Generic, Show)

-- | Rank-2 provider that brackets one dedicated PostgreSQL connection per operation.
newtype ConnectionProvider = ConnectionProvider
  { useDedicatedConnection ::
      forall a.
      (Connection.Connection -> IO a) ->
      IO (Either Errors.ConnectionError a)
  }

-- | Strict defaults with the standard ledger, indefinite lock wait, and no events.
defaultRunOptions :: RunOptions
defaultRunOptions =
  RunOptions
    { ledger = defaultLedgerConfig,
      lockWait = WaitIndefinitely,
      statementTimeout = Nothing,
      unknownMigrations = RejectUnknownMigrations,
      emit = const (pure ())
    }

-- | Select a validated ledger configuration.
withLedger :: LedgerConfig -> RunOptions -> RunOptions
withLedger ledger options = options {ledger}

-- | Select the advisory-lock wait policy.
withLockWait :: LockWait -> RunOptions -> RunOptions
withLockWait lockWait options = options {lockWait}

-- | Set or disable the temporary PostgreSQL statement timeout.
withStatementTimeout :: Maybe NominalDiffTime -> RunOptions -> RunOptions
withStatementTimeout statementTimeout options = options {statementTimeout}

-- | Select how inspection treats unknown stored migrations.
withUnknownMigrationsPolicy :: UnknownMigrationsPolicy -> RunOptions -> RunOptions
withUnknownMigrationsPolicy unknownMigrations RunOptions {ledger, lockWait, statementTimeout, emit} =
  RunOptions {ledger, lockWait, statementTimeout, unknownMigrations, emit}

-- | Install an observational lifecycle callback.
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

-- | Construct a provider from an application-owned connection bracket.
connectionProvider ::
  ( forall a.
    (Connection.Connection -> IO a) ->
    IO (Either Errors.ConnectionError a)
  ) ->
  ConnectionProvider
connectionProvider = ConnectionProvider
