module Main (main) where

import Test.Authoring qualified as Authoring
import Test.Component qualified as Component
import Test.Manifest qualified as Manifest
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "pg-migrate-embed"
        [ Manifest.tests,
          Component.tests,
          Authoring.tests
        ]
    )
