module Test.PublicApi (tests) where

import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
  ( DefinitionError,
    Migration,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    migrationComponent,
    migrationFingerprint,
    migrationPlan,
    sessionMigration,
    transactionMigration,
  )
import PgMigrate.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "public API"
    [ testCase "manual definitions compile through the singular public module" $
        case publicPlan of
          Left err -> assertFailure (show err)
          Right (Left err) -> assertFailure (show err)
          Right (Right plan) -> length (show plan) `seq` pure ()
    ]

publicPlan :: Either DefinitionError (Either PlanError MigrationPlan)
publicPlan = do
  transaction <- publicTransaction
  session <- publicSession
  component <- publicComponent transaction session
  pure (migrationPlan (component :| []))

publicTransaction :: Either DefinitionError Migration
publicTransaction =
  transactionMigration "0001-transaction" (migrationFingerprint "transaction-v1") (pure ())

publicSession :: Either DefinitionError Migration
publicSession =
  sessionMigration "0002-session" (migrationFingerprint "session-v1") (pure ())

publicComponent :: Migration -> Migration -> Either DefinitionError MigrationComponent
publicComponent transaction session =
  migrationComponent "public-api" Set.empty (transaction :| [session])
