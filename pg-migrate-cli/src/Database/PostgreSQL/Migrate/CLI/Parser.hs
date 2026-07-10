module Database.PostgreSQL.Migrate.CLI.Parser
  ( migrationCommandParser,
  )
where

import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
  ( ComponentName,
    Confirmation (Confirmed),
    DefinitionError,
    LockWait (..),
    MigrationId,
    MigrationName,
    MigrationPlan,
    RepairOperation (..),
    componentName,
    migrationId,
    migrationName,
  )
import Database.PostgreSQL.Migrate.CLI.Types
import Hasql.Connection.Settings qualified as Settings
import Options.Applicative
import PgMigrate.CLI.Prelude
import Text.Read qualified as Read

migrationCommandParser :: MigrationPlan -> Parser MigrationCommand
migrationCommandParser _ =
  subparser (commandGroup "Inspection" <> inspectionCommands)
    <|> subparser (commandGroup "Execution" <> executionCommands)
    <|> subparser (commandGroup "Authoring" <> authoringCommands)
  where
    inspectionCommands =
      command
        "plan"
        (info (Plan <$> planOptionsParser <**> helper) (progDesc "Show component order and dependencies"))
        <> command
          "status"
          (info (Status <$> statusOptionsParser <**> helper) (progDesc "Show declared and stored migration status"))
        <> command
          "verify"
          ( info
              (Verify <$> verifyOptionsParser <**> helper)
              (progDesc "Strictly compare the declared plan with the migration ledger (not live schema snapshots)")
          )
        <> command
          "list"
          (info (List <$> listOptionsParser <**> helper) (progDesc "List declared migrations and metadata"))
        <> command
          "check"
          (info (Check <$> checkOptionsParser <**> helper) (progDesc "Validate an ordered SQL manifest without a database"))
    executionCommands =
      command
        "up"
        ( info
            (Up <$> upOptionsParser <**> helper)
            (progDesc "Apply the complete migration plan; selective execution is unavailable in v1")
        )
        <> command
          "repair"
          (info (Repair <$> repairOptionsParser <**> helper) (progDesc "Repair one nontransactional migration after operator inspection"))
    authoringCommands =
      command
        "new"
        (info (New <$> newOptionsParser <**> helper) (progDesc "Create and append one SQL migration without applying it"))

planOptionsParser :: Parser PlanOptions
planOptionsParser =
  PlanOptions
    <$> inspectionOptionsParser
    <*> outputOptionsParser

listOptionsParser :: Parser ListOptions
listOptionsParser =
  ListOptions
    <$> inspectionOptionsParser
    <*> outputOptionsParser

checkOptionsParser :: Parser CheckOptions
checkOptionsParser =
  CheckOptions
    <$> strArgument (metavar "MANIFEST" <> help "Path to the ordered migration manifest")
    <*> outputOptionsParser

statusOptionsParser :: Parser StatusOptions
statusOptionsParser =
  StatusOptions
    <$> inspectionOptionsParser
    <*> connectionOptionsParser
    <*> outputOptionsParser

verifyOptionsParser :: Parser VerifyOptions
verifyOptionsParser =
  VerifyOptions
    <$> inspectionOptionsParser
    <*> connectionOptionsParser
    <*> outputOptionsParser

upOptionsParser :: Parser UpOptions
upOptionsParser =
  UpOptions
    <$> connectionOptionsParser
    <*> executionOptionsParser
    <*> outputOptionsParser

repairOptionsParser :: Parser RepairOptions
repairOptionsParser =
  RepairOptions
    <$> argument migrationIdReader (metavar "COMPONENT/MIGRATION")
    <*> repairOperationParser
    <*> strOption (long "reason" <> metavar "TEXT" <> help "Audit reason for the repair")
    <*> flag' Confirmed (long "confirm" <> help "Confirm that the database result was inspected")
    <*> connectionOptionsParser
    <*> executionOptionsParser
    <*> outputOptionsParser

newOptionsParser :: Parser NewOptions
newOptionsParser =
  NewOptions
    <$> strOption (long "manifest" <> metavar "PATH" <> help "Ordered manifest to append")
    <*> strOption (long "description" <> metavar "TEXT" <> help "Human description written into the new SQL file")
    <*> optional (strOption (long "name" <> metavar "BASENAME" <> help "Explicit SQL basename when numeric inference is unavailable"))
    <*> outputOptionsParser

connectionOptionsParser :: Parser ConnectionOptions
connectionOptionsParser =
  parserOptionGroup
    "Connection"
    ( ConnectionOptions
        <$> optional
          ( option
              databaseSettingsReader
              ( long "database-url"
                  <> metavar "URL"
                  <> help "PostgreSQL URI or keyword/value connection string; no environment variable is read"
              )
          )
    )

executionOptionsParser :: Parser ExecutionOptions
executionOptionsParser =
  parserOptionGroup
    "Execution"
    ( ExecutionOptions
        <$> lockWaitParser
        <*> optional
          ( option
              positiveMillisecondsReader
              ( long "statement-timeout"
                  <> metavar "MILLISECONDS"
                  <> help "Positive PostgreSQL statement timeout in milliseconds"
              )
          )
    )

outputOptionsParser :: Parser OutputOptions
outputOptionsParser =
  parserOptionGroup
    "Output"
    ( OutputOptions
        <$> flag TextOutput JsonOutput (long "json" <> help "Emit JSON schema version 1")
    )

inspectionOptionsParser :: Parser InspectionOptions
inspectionOptionsParser =
  parserOptionGroup
    "Filters"
    ( InspectionOptions
        <$> optional
          (option componentNameReader (long "component" <> metavar "COMPONENT" <> help "Limit inspection output to one component"))
        <*> optional
          (option migrationNameReader (long "migration" <> metavar "MIGRATION" <> help "Limit inspection output to one migration name"))
    )

lockWaitParser :: Parser LockWait
lockWaitParser =
  flag' NoWait (long "no-wait" <> help "Fail immediately when the advisory lock is unavailable")
    <|> ( WaitFor
            <$> option
              positiveMillisecondsReader
              ( long "lock-timeout"
                  <> metavar "MILLISECONDS"
                  <> help "Wait at most this many positive milliseconds for the advisory lock"
              )
        )
    <|> pure WaitIndefinitely

repairOperationParser :: Parser RepairOperation
repairOperationParser =
  flag' MarkApplied (long "mark-applied" <> help "Record the inspected nontransactional result as applied")
    <|> flag' Retry (long "retry" <> help "Return the migration to running and execute its action again")

positiveMillisecondsReader :: ReadM NominalDiffTime
positiveMillisecondsReader = eitherReader $ \input ->
  case Read.readMaybe input :: Maybe Integer of
    Just milliseconds
      | milliseconds > 0 -> Right (fromRational (toRational milliseconds / 1000))
    _ -> Left "expected a positive integer number of milliseconds"

databaseSettingsReader :: ReadM Settings.Settings
databaseSettingsReader = Settings.connectionString . Text.pack <$> str

componentNameReader :: ReadM ComponentName
componentNameReader = validatedTextReader componentName

migrationNameReader :: ReadM MigrationName
migrationNameReader = validatedTextReader migrationName

validatedTextReader :: (Text -> Either DefinitionError value) -> ReadM value
validatedTextReader validate = eitherReader $ \input ->
  case validate (Text.pack input) of
    Left err -> Left (show err)
    Right validated -> Right validated

migrationIdReader :: ReadM MigrationId
migrationIdReader = eitherReader $ \input ->
  case Text.splitOn "/" (Text.pack input) of
    [component, migration] ->
      case migrationId component migration of
        Left err -> Left (show err)
        Right validated -> Right validated
    _ -> Left "expected COMPONENT/MIGRATION"
