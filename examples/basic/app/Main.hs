{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI
import Database.PostgreSQL.Migrate.Embed
import Hasql.Connection.Settings qualified as Settings
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit qualified as System.Exit

main :: IO ()
main = do
  plan <-
    case examplePlan of
      Left definitionError -> fail (show definitionError)
      Right (Left planError) -> fail (show planError)
      Right (Right validPlan) -> pure validPlan
  parsedCommand <- execParser (info (migrationCommandParser plan <**> helper) (fullDesc <> progDesc "Manage the example service migration plan"))
  databaseUrl <-
    lookupEnv "DATABASE_URL"
      >>= maybe (fail "DATABASE_URL is required and is owned by this example application") pure
  let environment = cliEnvironment (Settings.connectionString (Text.pack databaseUrl)) plan defaultRunOptions
  outcome <- runMigrationCommand environment parsedCommand
  case commandOutputFormat parsedCommand of
    TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
    JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
  System.Exit.exitWith
    (case exitClass outcome of ExitSucceeded -> System.Exit.ExitSuccess; _ -> System.Exit.ExitFailure 1)

examplePlan :: Either DefinitionError (Either PlanError MigrationPlan)
examplePlan = do
  accounts <-
    migrationComponentFromEmbeddedSql
      "accounts"
      Set.empty
      $(embedMigrationManifest "migrations/accounts/manifest")
  billing <-
    migrationComponentFromEmbeddedSql
      "billing"
      (Set.singleton "accounts")
      $(embedMigrationManifest "migrations/billing/manifest")
  pure (migrationPlan (accounts :| [billing]))

commandOutputFormat :: MigrationCommand -> OutputFormat
commandOutputFormat parsedCommand =
  case parsedCommand of
    Plan PlanOptions {output = OutputOptions format} -> format
    List ListOptions {output = OutputOptions format} -> format
    Check CheckOptions {output = OutputOptions format} -> format
    Status StatusOptions {output = OutputOptions format} -> format
    Verify VerifyOptions {output = OutputOptions format} -> format
    Up UpOptions {output = OutputOptions format} -> format
    Repair RepairOptions {output = OutputOptions format} -> format
    New NewOptions {output = OutputOptions format} -> format
