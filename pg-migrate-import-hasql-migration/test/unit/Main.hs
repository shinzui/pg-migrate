module Main (main) where

import Test.Definition qualified as Definition
import Test.Evidence qualified as Evidence
import Test.Ledger qualified as Ledger
import Test.Parser qualified as Parser
import Test.Tasty

main :: IO ()
main = defaultMain (testGroup "pg-migrate-import-hasql-migration" [Definition.tests, Evidence.tests, Ledger.tests, Parser.tests])
