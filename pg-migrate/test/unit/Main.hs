module Main (main) where

import PgMigrate.Prelude ()
import Test.Definition qualified as Definition
import Test.History qualified as History
import Test.Ledger qualified as Ledger
import Test.Plan qualified as Plan
import Test.PublicApi qualified as PublicApi
import Test.Runner qualified as Runner
import Test.Sql qualified as Sql
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "pg-migrate"
        [ Definition.tests,
          History.tests,
          Ledger.tests,
          Plan.tests,
          PublicApi.tests,
          Runner.tests,
          Sql.tests
        ]
    )
