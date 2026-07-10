module Main (main) where

import Test.Manifest qualified as Manifest
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "pg-migrate-embed"
        [Manifest.tests]
    )
