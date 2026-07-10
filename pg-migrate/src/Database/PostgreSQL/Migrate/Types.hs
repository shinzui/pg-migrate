module Database.PostgreSQL.Migrate.Types
  ( ComponentName (..),
    MigrationName (..),
    MigrationId (..),
    MigrationChecksum (..),
    TransactionMode (..),
    MigrationKind (..),
    MigrationAction (..),
    Migration (..),
    MigrationComponent (..),
    MigrationPlan (..),
    componentNameText,
    migrationNameText,
    migrationIdComponent,
    migrationIdName,
    migrationNameOf,
    migrationChecksumOf,
    migrationKindOf,
    migrationModeOf,
    migrationActionOf,
    componentNameOf,
    componentDependenciesOf,
    componentMigrationsOf,
    planComponentsOf,
  )
where

import Hasql.Session qualified as Hasql.Session
import Hasql.Transaction qualified as Hasql.Transaction
import PgMigrate.Prelude

-- | Validated, application-stable component identifier.
newtype ComponentName = ComponentName
  { unComponentName :: Text
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | Validated migration identifier local to one component.
newtype MigrationName = MigrationName
  { unMigrationName :: Text
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | Globally unique migration identity: component plus local name.
data MigrationId = MigrationId
  { component :: !ComponentName,
    name :: !MigrationName
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | SHA-256 fingerprint of the immutable migration payload.
newtype MigrationChecksum = MigrationChecksum
  { unMigrationChecksum :: ByteString
  }
  deriving stock (Generic, Eq, Ord, Show)

data TransactionMode
  = Transactional
  | NonTransactional
  deriving stock (Generic, Eq, Ord, Show)

data MigrationKind
  = SqlKind
  | HaskellKind
  deriving stock (Generic, Eq, Ord, Show)

data MigrationAction
  = SqlAction !ByteString
  | TransactionAction !(Hasql.Transaction.Transaction ())
  | SessionAction !(Hasql.Session.Session ())

-- | Validated migration definition with an immutable action and fingerprint.
data Migration = Migration
  { name :: !MigrationName,
    description :: !(Maybe Text),
    mode :: !TransactionMode,
    kind :: !MigrationKind,
    checksum :: !MigrationChecksum,
    action :: !MigrationAction
  }

-- | Ordered, non-empty migrations owned by one library component.
data MigrationComponent = MigrationComponent
  { name :: !ComponentName,
    dependencies :: !(Set ComponentName),
    migrations :: !(NonEmpty Migration)
  }

-- | Validated dependency-ordered composition of components.
newtype MigrationPlan = MigrationPlan
  { components :: NonEmpty MigrationComponent
  }

instance Show MigrationPlan where
  showsPrec precedence (MigrationPlan planComponents) =
    showsPrec precedence (summarizeComponent <$> planComponents)

summarizeComponent ::
  MigrationComponent ->
  (ComponentName, Set ComponentName, NonEmpty (MigrationName, MigrationChecksum, MigrationKind, TransactionMode))
summarizeComponent migrationComponent =
  ( componentNameOf migrationComponent,
    componentDependenciesOf migrationComponent,
    summarizeMigration <$> componentMigrationsOf migrationComponent
  )

summarizeMigration ::
  Migration ->
  (MigrationName, MigrationChecksum, MigrationKind, TransactionMode)
summarizeMigration migration =
  ( migrationNameOf migration,
    migrationChecksumOf migration,
    migrationKindOf migration,
    migrationModeOf migration
  )

componentNameText :: ComponentName -> Text
componentNameText (ComponentName value) = value

migrationNameText :: MigrationName -> Text
migrationNameText (MigrationName value) = value

migrationIdComponent :: MigrationId -> ComponentName
migrationIdComponent MigrationId {component} = component

migrationIdName :: MigrationId -> MigrationName
migrationIdName MigrationId {name} = name

migrationNameOf :: Migration -> MigrationName
migrationNameOf Migration {name} = name

migrationChecksumOf :: Migration -> MigrationChecksum
migrationChecksumOf Migration {checksum} = checksum

migrationKindOf :: Migration -> MigrationKind
migrationKindOf Migration {kind} = kind

migrationModeOf :: Migration -> TransactionMode
migrationModeOf Migration {mode} = mode

migrationActionOf :: Migration -> MigrationAction
migrationActionOf Migration {action} = action

componentNameOf :: MigrationComponent -> ComponentName
componentNameOf MigrationComponent {name} = name

componentDependenciesOf :: MigrationComponent -> Set ComponentName
componentDependenciesOf MigrationComponent {dependencies} = dependencies

componentMigrationsOf :: MigrationComponent -> NonEmpty Migration
componentMigrationsOf MigrationComponent {migrations} = migrations

planComponentsOf :: MigrationPlan -> NonEmpty MigrationComponent
planComponentsOf MigrationPlan {components} = components
