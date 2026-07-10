module Main (main) where

import PgMigrate.Prelude
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "pg-migrate" [])
