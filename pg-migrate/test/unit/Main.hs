module Main (main) where

import PgMigrate.Prelude ()
import Test.Definition qualified as Definition
import Test.Plan qualified as Plan
import Test.PublicApi qualified as PublicApi
import Test.Sql qualified as Sql
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "pg-migrate"
        [ Definition.tests,
          Plan.tests,
          PublicApi.tests,
          Sql.tests
        ]
    )
