module Main (main) where

import Test.Manifest qualified as Manifest
import Test.Parser qualified as Parser
import Test.Tasty

main :: IO ()
main = defaultMain (testGroup "pg-migrate-import-codd" [Manifest.tests, Parser.tests])
