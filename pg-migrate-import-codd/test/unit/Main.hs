module Main (main) where

import Test.Evidence qualified as Evidence
import Test.Ledger qualified as Ledger
import Test.Manifest qualified as Manifest
import Test.Parser qualified as Parser
import Test.Tasty

main :: IO ()
main = defaultMain (testGroup "pg-migrate-import-codd" [Evidence.tests, Ledger.tests, Manifest.tests, Parser.tests])
