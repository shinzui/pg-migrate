module Main (main) where

import Test.Handler qualified as Handler
import Test.Json qualified as Json
import Test.Parser qualified as Parser
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "pg-migrate-cli"
        [ Parser.tests,
          Handler.tests,
          Json.tests
        ]
    )
