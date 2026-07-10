module Main (main) where

import Test.Parser qualified as Parser
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "pg-migrate-cli"
        [Parser.tests]
    )
