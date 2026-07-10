module Database.PostgreSQL.Migrate.CLI.Handler
  ( CliEnvironment,
    cliEnvironment,
    cliEnvironmentWithConnectionProvider,
    runMigrationCommand,
  )
where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate
  ( ComponentName,
    Confirmation,
    ConnectionProvider,
    MigrationId,
    MigrationPlan,
    RepairOperation,
    RunOptions,
    StatusReport (..),
    StoredMigration (..),
    VerificationReport (..),
    connectionProviderFromSettings,
    migrationFingerprint,
    migrationStatusWith,
    repairMigration,
    repairRequest,
    runMigrationPlanWith,
    verifyMigrationPlanWith,
    withLockWait,
    withStatementTimeout,
  )
import Database.PostgreSQL.Migrate.CLI.Outcome
import Database.PostgreSQL.Migrate.CLI.Types
import Database.PostgreSQL.Migrate.Embed
  ( AuthoringError (..),
    checkMigrationManifest,
    newMigration,
    newMigrationOptions,
  )
import Database.PostgreSQL.Migrate.Internal
  ( ComponentDescription (..),
    MigrationDescription (..),
    PlanDescription (..),
    migrationIdComponent,
    migrationIdName,
    planDescription,
  )
import Hasql.Connection.Settings qualified as Settings
import PgMigrate.CLI.Prelude

data CliConnection
  = SettingsConnection !Settings.Settings
  | ProviderConnection !ConnectionProvider

data CliEnvironment = CliEnvironment
  { defaultConnection :: !CliConnection,
    migrationPlan :: !MigrationPlan,
    runnerOptions :: !RunOptions
  }

cliEnvironment :: Settings.Settings -> MigrationPlan -> RunOptions -> CliEnvironment
cliEnvironment settings = CliEnvironment (SettingsConnection settings)

cliEnvironmentWithConnectionProvider ::
  ConnectionProvider ->
  MigrationPlan ->
  RunOptions ->
  CliEnvironment
cliEnvironmentWithConnectionProvider provider = CliEnvironment (ProviderConnection provider)

runMigrationCommand :: CliEnvironment -> MigrationCommand -> IO CliOutcome
runMigrationCommand environment commandValue =
  case commandValue of
    Plan PlanOptions {inspection} ->
      pure
        ( success
            "plan"
            (PlanPayload (filterPlan inspection (planDescription (migrationPlan environment))))
        )
    List ListOptions {inspection} ->
      pure
        ( success
            "list"
            ( ListPayload
                ( filterMigrations
                    inspection
                    (flattenPlanDescription (planDescription (migrationPlan environment)))
                )
            )
        )
    Check CheckOptions {manifestPath} -> runCheck manifestPath
    Status StatusOptions {inspection, connection} -> runStatus environment inspection connection
    Verify VerifyOptions {inspection, connection} -> runVerify environment inspection connection
    Up UpOptions {connection, execution} -> runUp environment connection execution
    Repair RepairOptions {target, operation, reason, confirmation, connection, execution} ->
      runRepair environment connection execution target operation reason confirmation
    New NewOptions {manifestPath, description, requestedName} ->
      runNew manifestPath description requestedName

runCheck :: FilePath -> IO CliOutcome
runCheck manifestPath = do
  checked <- checkMigrationManifest manifestPath
  pure $ case checked of
    Left manifestError -> failure "check" ExitUsageFailed (CliManifestError manifestError)
    Right entries ->
      success
        "check"
        ( CheckPayload
            ((\(file, bytes) -> CheckedMigration file (migrationFingerprint bytes)) <$> entries)
        )

runStatus :: CliEnvironment -> InspectionOptions -> ConnectionOptions -> IO CliOutcome
runStatus environment inspection connection = do
  result <-
    migrationStatusWith
      (runnerOptions environment)
      (selectProvider environment connection)
      (migrationPlan environment)
  pure $ case result of
    Left migrationError -> failure "status" ExitExecutionFailed (CliMigrationError migrationError)
    Right report -> success "status" (StatusPayload (filterStatus inspection report))

runVerify :: CliEnvironment -> InspectionOptions -> ConnectionOptions -> IO CliOutcome
runVerify environment inspection connection = do
  result <-
    verifyMigrationPlanWith
      (runnerOptions environment)
      (selectProvider environment connection)
      (migrationPlan environment)
  pure $ case result of
    Left migrationError -> failure "verify" ExitExecutionFailed (CliMigrationError migrationError)
    Right report ->
      CliOutcome
        { command = "verify",
          exitClass = verificationExitClass report,
          payload = Right (VerifyPayload (filterVerification inspection report))
        }

runUp :: CliEnvironment -> ConnectionOptions -> ExecutionOptions -> IO CliOutcome
runUp environment connection execution = do
  result <-
    runMigrationPlanWith
      (applyExecution execution (runnerOptions environment))
      (selectProvider environment connection)
      (migrationPlan environment)
  pure $ case result of
    Left migrationError -> failure "up" ExitExecutionFailed (CliMigrationError migrationError)
    Right report -> success "up" (UpPayload report)

runRepair ::
  CliEnvironment ->
  ConnectionOptions ->
  ExecutionOptions ->
  MigrationId ->
  RepairOperation ->
  Text ->
  Confirmation ->
  IO CliOutcome
runRepair environment connection execution target operation reason confirmation =
  case repairRequest target operation reason confirmation of
    Left definitionError ->
      pure (failure "repair" ExitUsageFailed (CliRepairDefinitionError definitionError))
    Right request -> do
      result <-
        repairMigration
          (applyExecution execution (runnerOptions environment))
          (selectProvider environment connection)
          (migrationPlan environment)
          request
      pure $ case result of
        Left repairError -> failure "repair" ExitExecutionFailed (CliRepairError repairError)
        Right report -> success "repair" (RepairPayload report)

runNew :: FilePath -> Text -> Maybe FilePath -> IO CliOutcome
runNew manifestPath description requestedName =
  case newMigrationOptions manifestPath requestedName initialSql of
    Left authoringError ->
      pure (failure "new" ExitUsageFailed (CliAuthoringError authoringError))
    Right options -> do
      result <- newMigration options
      pure $ case result of
        Left authoringError ->
          failure "new" (authoringExitClass authoringError) (CliAuthoringError authoringError)
        Right path -> success "new" (NewPayload path)
  where
    initialSql = Text.Encoding.encodeUtf8 ("-- " <> description <> "\n\n")

selectProvider :: CliEnvironment -> ConnectionOptions -> ConnectionProvider
selectProvider CliEnvironment {defaultConnection} ConnectionOptions {databaseSettings} =
  case databaseSettings of
    Just settings -> connectionProviderFromSettings settings
    Nothing ->
      case defaultConnection of
        SettingsConnection settings -> connectionProviderFromSettings settings
        ProviderConnection provider -> provider

applyExecution :: ExecutionOptions -> RunOptions -> RunOptions
applyExecution ExecutionOptions {lockWait, statementTimeout} =
  withStatementTimeout statementTimeout . withLockWait lockWait

verificationExitClass :: VerificationReport -> ExitClass
verificationExitClass VerificationReport {issues}
  | null issues = ExitSuccess
  | otherwise = ExitVerificationFailed

authoringExitClass :: AuthoringError -> ExitClass
authoringExitClass authoringError =
  case authoringError of
    AuthoringIoError {} -> ExitExecutionFailed
    AuthoringCleanupError {} -> ExitExecutionFailed
    _ -> ExitUsageFailed

success :: Text -> CliPayload -> CliOutcome
success command payload = CliOutcome {command, exitClass = ExitSuccess, payload = Right payload}

failure :: Text -> ExitClass -> CliError -> CliOutcome
failure command exitClass cliError = CliOutcome {command, exitClass, payload = Left cliError}

flattenPlanDescription :: PlanDescription -> [MigrationDescription]
flattenPlanDescription (PlanDescription components) =
  concatMap (toList . migrations) (toList components)

filterPlan :: InspectionOptions -> PlanDescription -> [ComponentDescription]
filterPlan inspection (PlanDescription components) =
  foldr filterComponent [] (toList components)
  where
    filterComponent componentDescription@ComponentDescription {name, migrations} remaining
      | not (matchesComponent inspection name) = remaining
      | otherwise =
          case NonEmpty.nonEmpty (filter (matchesMigrationDescription inspection) (toList migrations)) of
            Nothing -> remaining
            Just filteredMigrations ->
              componentDescription {migrations = filteredMigrations} : remaining

filterMigrations :: InspectionOptions -> [MigrationDescription] -> [MigrationDescription]
filterMigrations inspection = filter (matchesMigrationDescription inspection)

filterStatus :: InspectionOptions -> StatusReport -> StatusReport
filterStatus inspection (StatusReport issues applied pending unknown) =
  StatusReport
    issues
    (filter (matchesMigrationId inspection) applied)
    (filter (matchesMigrationId inspection) pending)
    (filter (matchesMigrationId inspection . storedMigrationId) unknown)

filterVerification :: InspectionOptions -> VerificationReport -> VerificationReport
filterVerification inspection (VerificationReport issues applied pending unknown) =
  VerificationReport
    issues
    (filter (matchesMigrationId inspection) applied)
    (filter (matchesMigrationId inspection) pending)
    (filter (matchesMigrationId inspection . storedMigrationId) unknown)

matchesMigrationDescription :: InspectionOptions -> MigrationDescription -> Bool
matchesMigrationDescription inspection MigrationDescription {migrationId} =
  matchesMigrationId inspection migrationId

matchesMigrationId :: InspectionOptions -> MigrationId -> Bool
matchesMigrationId InspectionOptions {component, migration} identifier =
  maybe True (== migrationIdComponent identifier) component
    && maybe True (== migrationIdName identifier) migration

matchesComponent :: InspectionOptions -> ComponentName -> Bool
matchesComponent InspectionOptions {component} candidate = maybe True (== candidate) component
