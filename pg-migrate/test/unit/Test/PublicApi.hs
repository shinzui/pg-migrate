module Test.PublicApi (tests) where

import PgMigrate.Prelude
import Test.Tasty (TestTree, testGroup)

tests :: TestTree
tests = testGroup "public API" []
