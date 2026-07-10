module Database.PostgreSQL.Migrate.CLI.Outcome
  ( ExitClass (..),
    CheckedMigration (..),
    CliPayload (..),
    CliError (..),
    CliOutcome (..),
  )
where

import Database.PostgreSQL.Migrate
  ( MigrationChecksum,
    MigrationError,
    MigrationReport,
    RepairDefinitionError,
    RepairError,
    RepairReport,
    StatusReport,
    VerificationReport,
  )
import Database.PostgreSQL.Migrate.Embed (AuthoringError, ManifestError)
import Database.PostgreSQL.Migrate.Internal
  ( ComponentDescription,
    MigrationDescription,
  )
import PgMigrate.CLI.Prelude

data ExitClass
  = ExitSuccess
  | ExitVerificationFailed
  | ExitUsageFailed
  | ExitExecutionFailed
  deriving stock (Generic, Eq, Ord, Show)

data CheckedMigration = CheckedMigration
  { file :: !FilePath,
    checksum :: !MigrationChecksum
  }
  deriving stock (Generic, Eq, Show)

data CliPayload
  = PlanPayload ![ComponentDescription]
  | ListPayload ![MigrationDescription]
  | CheckPayload !(NonEmpty CheckedMigration)
  | StatusPayload !StatusReport
  | VerifyPayload !VerificationReport
  | UpPayload !MigrationReport
  | RepairPayload !RepairReport
  | NewPayload !FilePath
  deriving stock (Generic, Eq, Show)

data CliError
  = CliMigrationError !MigrationError
  | CliRepairDefinitionError !RepairDefinitionError
  | CliRepairError !RepairError
  | CliManifestError !ManifestError
  | CliAuthoringError !AuthoringError
  deriving stock (Generic, Show)

data CliOutcome = CliOutcome
  { command :: !Text,
    exitClass :: !ExitClass,
    payload :: !(Either CliError CliPayload)
  }
  deriving stock (Generic, Show)
