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
    validateDescription,
  )
where

import Data.Char qualified as Char
import Data.Text qualified as Text
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

-- | Human-readable or versioned JSON rendering.
data OutputFormat
  = TextOutput
  | JsonOutput
  deriving stock (Generic, Eq, Ord, Show)

-- | Optional command-line database connection override.
newtype ConnectionOptions = ConnectionOptions
  { databaseSettings :: Maybe Settings.Settings
  }
  deriving stock (Generic, Eq, Show)

-- | Shared lock and statement-timeout flags.
data ExecutionOptions = ExecutionOptions
  { lockWait :: !(Maybe LockWait),
    statementTimeout :: !(Maybe (Maybe NominalDiffTime))
  }
  deriving stock (Generic, Eq, Show)

-- | Shared output selection.
newtype OutputOptions = OutputOptions
  { outputFormat :: OutputFormat
  }
  deriving stock (Generic, Eq, Show)

-- | Shared read-only command options.
data InspectionOptions = InspectionOptions
  { component :: !(Maybe ComponentName),
    migration :: !(Maybe MigrationName)
  }
  deriving stock (Generic, Eq, Show)

-- | Shared local plan-rendering options.
data PlanOptions = PlanOptions
  { inspection :: !InspectionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

-- | Parsed @list@ command options.
data ListOptions = ListOptions
  { inspection :: !InspectionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

-- | Parsed @check@ command options.
data CheckOptions = CheckOptions
  { manifestPath :: !FilePath,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

-- | Parsed @status@ command options.
data StatusOptions = StatusOptions
  { inspection :: !InspectionOptions,
    connection :: !ConnectionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

-- | Parsed strict @verify@ command options.
data VerifyOptions = VerifyOptions
  { inspection :: !InspectionOptions,
    connection :: !ConnectionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

-- | Parsed @up@ command options.
data UpOptions = UpOptions
  { connection :: !ConnectionOptions,
    execution :: !ExecutionOptions,
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

-- | Parsed confirmed @repair@ command options.
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

-- | Parsed migration-authoring command options.
data NewOptions = NewOptions
  { manifestPath :: !FilePath,
    description :: !Text,
    requestedName :: !(Maybe FilePath),
    output :: !OutputOptions
  }
  deriving stock (Generic, Eq, Show)

-- | Complete reusable command algebra mounted by an application executable.
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

validateDescription :: Text -> Either Text Text
validateDescription description =
  case Text.find Char.isControl description of
    Nothing -> Right description
    Just character ->
      Left
        ( "invalid --description: control character "
            <> Text.pack (show character)
            <> " is not allowed"
        )
