module Database.PostgreSQL.Migrate.CLI.Types
  ( OutputFormat (..),
    ConnectionOptions (..),
    ExecutionOptions (..),
    OutputOptions (..),
    InspectionOptions (..),
    PlanOptions (..),
    ListOptions (..),
    CheckOptions (..),
    StatusOptions (..),
    VerifyOptions (..),
    UpOptions (..),
    RepairOptions (..),
    NewOptions (..),
    MigrationCommand (..),
  )
where

import Database.PostgreSQL.Migrate
  ( ComponentName,
    Confirmation,
    LockWait,
    MigrationId,
    MigrationName,
    RepairOperation,
  )
import Hasql.Connection.Settings qualified as Settings
import PgMigrate.CLI.Prelude

data OutputFormat
  = TextOutput
  | JsonOutput
  deriving stock (Generic, Eq, Ord, Show)

newtype ConnectionOptions = ConnectionOptions
  { databaseSettings :: Maybe Settings.Settings
  }
  deriving stock (Generic, Eq, Show)

data ExecutionOptions = ExecutionOptions
  { lockWait :: !LockWait,
    statementTimeout :: !(Maybe NominalDiffTime)
  }
  deriving stock (Generic, Eq, Show)

newtype OutputOptions = OutputOptions
  { outputFormat :: OutputFormat
  }
  deriving stock (Generic, Eq, Show)

data InspectionOptions = InspectionOptions
  { component :: !(Maybe ComponentName),
    migration :: !(Maybe MigrationName)
  }
  deriving stock (Generic, Eq, Show)

data PlanOptions = PlanOptions
  { inspection :: !InspectionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

data ListOptions = ListOptions
  { inspection :: !InspectionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

data CheckOptions = CheckOptions
  { manifestPath :: !FilePath,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

data StatusOptions = StatusOptions
  { inspection :: !InspectionOptions,
    connection :: !ConnectionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

data VerifyOptions = VerifyOptions
  { inspection :: !InspectionOptions,
    connection :: !ConnectionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

data UpOptions = UpOptions
  { connection :: !ConnectionOptions,
    execution :: !ExecutionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

data RepairOptions = RepairOptions
  { target :: !MigrationId,
    operation :: !RepairOperation,
    reason :: !Text,
    confirmation :: !Confirmation,
    connection :: !ConnectionOptions,
    execution :: !ExecutionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

data NewOptions = NewOptions
  { manifestPath :: !FilePath,
    description :: !Text,
    requestedName :: !(Maybe FilePath),
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

data MigrationCommand
  = Plan !PlanOptions
  | Status !StatusOptions
  | Verify !VerifyOptions
  | List !ListOptions
  | Check !CheckOptions
  | Up !UpOptions
  | Repair !RepairOptions
  | New !NewOptions
  deriving stock (Generic, Eq, Show)
