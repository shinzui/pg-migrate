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

data RepairOperation
  = MarkApplied
  | Retry
  deriving stock (Generic, Eq, Ord, Show)

data Confirmation
  = NotConfirmed
  | Confirmed
  deriving stock (Generic, Eq, Ord, Show)

data RepairDefinitionError
  = RepairNotConfirmed
  | EmptyRepairReason
  deriving stock (Generic, Eq, Show)

data RepairRequest = RepairRequest
  { repairMigrationId :: !MigrationId,
    repairOperation :: !RepairOperation,
    repairReason :: !Text
  }
  deriving stock (Generic, Eq, Show)

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

data RepairReport = RepairReport
  { repairedMigration :: !MigrationId,
    operation :: !RepairOperation,
    oldStatus :: !MigrationStatus,
    newStatus :: !MigrationStatus
  }
  deriving stock (Generic, Eq, Show)

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
