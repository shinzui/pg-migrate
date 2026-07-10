module Main (main) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI
import Options.Applicative

main :: IO ()
main = do
  _ <-
    execParser
      ( info
          (migrationCommandParser fixturePlan <**> helper)
          (fullDesc <> progDesc "Manage the fixture service migration plan")
      )
  pure ()

fixturePlan :: MigrationPlan
fixturePlan =
  expectRight
    ( migrationPlan
        ( expectRight
            ( migrationComponent
                "accounts"
                Set.empty
                (expectRight (sqlMigration "0001" "SELECT 1") :| [])
            )
            :| [ expectRight
                   ( migrationComponent
                       "billing"
                       (Set.singleton "accounts")
                       (expectRight (sqlMigration "0001" "SELECT 2") :| [])
                   )
               ]
        )
    )

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
