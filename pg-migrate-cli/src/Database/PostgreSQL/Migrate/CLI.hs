-- | Reusable parser, dispatcher, and text/JSON rendering boundary. Applications retain
-- ownership of their plan, connection configuration, streams, logging, and process exit.
module Database.PostgreSQL.Migrate.CLI
  ( migrationCommandParser,
    CliEnvironment,
    cliEnvironment,
    cliEnvironmentWithConnectionProvider,
    runMigrationCommand,
    renderMigrationCommandText,
    jsonSchemaVersion,
    renderMigrationCommandJson,
    renderHistoryImportJson,
    ExitClass (..),
    CheckedMigration (..),
    CliPayload (..),
    CliError (..),
    CliOutcome (..),
    OutputFormat (..),
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

import Database.PostgreSQL.Migrate.CLI.Handler
  ( CliEnvironment,
    cliEnvironment,
    cliEnvironmentWithConnectionProvider,
    runMigrationCommand,
  )
import Database.PostgreSQL.Migrate.CLI.Json
  ( jsonSchemaVersion,
    renderHistoryImportJson,
    renderMigrationCommandJson,
  )
import Database.PostgreSQL.Migrate.CLI.Outcome
import Database.PostgreSQL.Migrate.CLI.Parser (migrationCommandParser)
import Database.PostgreSQL.Migrate.CLI.Text (renderMigrationCommandText)
import Database.PostgreSQL.Migrate.CLI.Types
