module Database.PostgreSQL.Migrate.Repair.Types
  ( RepairOperation (..),
    Confirmation (..),
    RepairDefinitionError (..),
    RepairRequest (..),
    repairRequest,
    RepairError (..),
    RepairReport (..),
  )
where

import Data.Text qualified as Text
import Database.PostgreSQL.Migrate.Ledger.Types
import Database.PostgreSQL.Migrate.Runner.Types
import Database.PostgreSQL.Migrate.Types
import PgMigrate.Prelude

-- | Explicit recovery action for one nontransactional migration.
data RepairOperation
  = MarkApplied
  | Retry
  deriving stock (Generic, Eq, Ord, Show)

-- | Required acknowledgement for destructive operational intent.
data Confirmation
  = NotConfirmed
  | Confirmed
  deriving stock (Generic, Eq, Ord, Show)

-- | Invalid confirmation or audit reason.
data RepairDefinitionError
  = RepairNotConfirmed
  | EmptyRepairReason
  deriving stock (Generic, Eq, Show)

-- | Validated target, operation, and durable audit reason.
data RepairRequest = RepairRequest
  { repairMigrationId :: !MigrationId,
    repairOperation :: !RepairOperation,
    repairReason :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Structured reason an attempted repair could not complete.
data RepairError
  = RepairRunnerError !MigrationError
  | RepairTargetMissing !MigrationId
  | RepairTargetNotInPlan !MigrationId
  | RepairTargetAlreadyApplied !MigrationId
  | RepairTargetTransactional !MigrationId
  | RepairTargetMetadataMismatch !MigrationId
  | RepairBlockedByVerification !VerificationReport
  | RepairTransitionFailed !MigrationId
  deriving stock (Generic, Show)

-- | Durable status transition produced by a successful repair.
data RepairReport = RepairReport
  { repairedMigration :: !MigrationId,
    operation :: !RepairOperation,
    oldStatus :: !MigrationStatus,
    newStatus :: !MigrationStatus
  }
  deriving stock (Generic, Eq, Show)

-- | Require explicit confirmation and a non-empty audit reason.
repairRequest ::
  MigrationId ->
  RepairOperation ->
  Text ->
  Confirmation ->
  Either RepairDefinitionError RepairRequest
repairRequest repairMigrationId repairOperation repairReason confirmation = do
  case confirmation of
    NotConfirmed -> Left RepairNotConfirmed
    Confirmed -> Right ()
  if Text.null (Text.strip repairReason)
    then Left EmptyRepairReason
    else Right RepairRequest {repairMigrationId, repairOperation, repairReason}
