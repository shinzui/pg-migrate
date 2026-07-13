module Database.PostgreSQL.Migrate.History.HasqlMigration.Parser
  ( hasqlMigrationImportCommandParser,
  )
where

import Data.Text qualified as Text
import Database.PostgreSQL.Migrate (MigrationPlan)
import Database.PostgreSQL.Migrate.CLI (OutputFormat (..))
import Database.PostgreSQL.Migrate.History.HasqlMigration.Types
import Hasql.Connection.Settings qualified as Settings
import Options.Applicative

-- | Build the reusable hasql-migration import parser; the plan parameter is reserved.
hasqlMigrationImportCommandParser :: MigrationPlan -> Parser HasqlMigrationImportCommand
hasqlMigrationImportCommandParser _ =
  HasqlMigrationImportCommand
    <$> parserOptionGroup
      "Connection"
      ( optional
          ( option
              (Settings.connectionString . Text.pack <$> str)
              (long "source-database-url" <> metavar "URL" <> help "hasql-migration source connection string; no environment variable is read")
          )
      )
    <*> option
      (eitherReader (either (Left . show) Right . qualifiedTable . Text.pack))
      (long "source-table" <> metavar "SCHEMA.TABLE" <> value defaultHasqlMigrationTable <> showDefaultWith (const "public.schema_migrations"))
    <*> strOption (long "mapping" <> metavar "PATH" <> help "Checked-in source-to-target mapping artifact")
    <*> strOption (long "source-directory" <> metavar "PATH" <> help "Directory containing exact selected legacy SQL payloads")
    <*> switch (long "strict-source" <> help "Reject every unselected source row")
    <*> switch (long "allow-equivalent" <> help "Opt in to mappings proven by read-only state validators")
    <*> flag TextOutput JsonOutput (long "json" <> help "Emit JSON schema version 1 conventions")
