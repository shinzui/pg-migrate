module Test.Component (tests) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Database.PostgreSQL.Migrate qualified as Migrate
import Database.PostgreSQL.Migrate.Embed (checkMigrationManifest)
import Database.PostgreSQL.Migrate.Internal qualified as Internal
import Paths_pg_migrate_embed qualified as Paths
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "embedded component"
    [ testCase "manifest order and suffix-derived names are authoritative" $ do
        entries <- validEntries
        component <-
          assertRight
            ( Migrate.migrationComponentFromEmbeddedSql
                "example-component"
                Set.empty
                entries
            )
        plan <- assertRight (Migrate.migrationPlan (component :| []))
        let descriptions = migrationDescriptions (Internal.planDescription plan)
        fmap Internal.migrationId descriptions
          @?= ( assertMigrationId "example-component" "0002-second"
                  :| [assertMigrationId "example-component" "0001-first"]
              ),
      testCase "each embedded file retains its own derived transaction mode" $ do
        component <-
          assertRight
            ( Migrate.migrationComponentFromEmbeddedSql
                "example-component"
                Set.empty
                ( ("0001-transactional.sql", "SELECT 1")
                    :| [ ( "0002-nontransactional.sql",
                           "-- pg-migrate: no-transaction\nCREATE INDEX CONCURRENTLY example_idx ON example (id)"
                         )
                       ]
                )
            )
        plan <- assertRight (Migrate.migrationPlan (component :| []))
        fmap Internal.transactionMode (migrationDescriptions (Internal.planDescription plan))
          @?= (Internal.Transactional :| [Internal.NonTransactional]),
      testCase "invalid SQL keeps its structured definition error" $
        assertDefinitionLeft
          (Migrate.InvalidSql (Migrate.ProhibitedTransactionCommand "BEGIN"))
          ( Migrate.migrationComponentFromEmbeddedSql
              "example-component"
              Set.empty
              (("0001-invalid.sql", "BEGIN") :| [])
          ),
      testCase "manual entries must have the SQL suffix" $
        assertDefinitionLeft
          (Migrate.InvalidEmbeddedMigrationFile "0001-invalid.txt")
          ( Migrate.migrationComponentFromEmbeddedSql
              "example-component"
              Set.empty
              (("0001-invalid.txt", "SELECT 1") :| [])
          )
    ]

validEntries :: IO (NonEmpty (FilePath, ByteString))
validEntries = do
  manifestPath <- Paths.getDataFileName ("test/fixtures" </> "valid/migrations/manifest")
  result <- checkMigrationManifest manifestPath
  case result of
    Left err -> assertFailure ("expected valid fixture, received Left " <> show err)
    Right entries -> pure entries

migrationDescriptions :: Internal.PlanDescription -> NonEmpty Internal.MigrationDescription
migrationDescriptions (Internal.PlanDescription (component :| [])) = Internal.migrations component
migrationDescriptions _ = error "expected one component"

assertMigrationId :: Text -> Text -> Migrate.MigrationId
assertMigrationId component name =
  case Migrate.migrationId component name of
    Left err -> error (show err)
    Right value -> value

assertRight :: (Show error) => Either error value -> IO value
assertRight = \case
  Left err -> assertFailure ("expected Right, received Left " <> show err)
  Right value -> pure value

assertDefinitionLeft ::
  Migrate.DefinitionError ->
  Either Migrate.DefinitionError value ->
  IO ()
assertDefinitionLeft expected = \case
  Left actual -> actual @?= expected
  Right _ -> assertFailure ("expected Left " <> show expected <> ", received Right")
