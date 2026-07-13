{-# LANGUAGE TemplateHaskell #-}

module Test.Manifest (tests) where

import Control.Exception qualified as Exception
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Database.PostgreSQL.Migrate.Embed
import Database.PostgreSQL.Migrate.Embed.Internal (byteStringExpression)
import Paths_pg_migrate_embed qualified as Paths
import System.Directory qualified as Directory
import System.FilePath ((</>))
import System.FilePath qualified as FilePath
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "manifest"
    [ testCase "the supported format version is one" (manifestFormatVersion @?= 1),
      testCase "valid entries and exact bytes follow manifest order" $ do
        result <- checkMigrationManifest =<< fixture "valid/migrations/manifest"
        result @?= Right validEmbedded,
      testCase "embedded primitive bytes preserve every byte value" $
        embeddedAllBytes @?= ByteString.pack [0 .. 255],
      testCase "a large embedded payload compiles without per-byte AST expansion" $ do
        ByteString.length largeEmbeddedBytes @?= largeFixtureSize
        ByteString.all (== 0xA5) largeEmbeddedBytes @?= True,
      testCase "blank lines are rejected" $
        checkError "blank/manifest" (BlankManifestLine 2),
      testCase "comment lines are rejected" $
        checkError "comment/manifest" (CommentManifestLine 2),
      testCase "duplicates identify both lines" $
        checkError
          "duplicate/manifest"
          (DuplicateManifestEntry "0001-first.sql" 1 2),
      testCase "absolute paths are rejected" $
        checkError
          "absolute/manifest"
          (AbsoluteManifestEntry 1 "/tmp/outside.sql"),
      testCase "parent traversal is rejected" $
        checkError
          "parent/manifest"
          (ParentTraversalManifestEntry 1 "../outside.sql"),
      testCase "nested paths are rejected" $
        checkError
          "nested/manifest"
          (NestedManifestEntry 1 "nested/0001-first.sql"),
      testCase "non-SQL entries are rejected" $
        checkError
          "non-sql/manifest"
          (NonSqlManifestEntry 1 "README.txt"),
      testCase "missing files are rejected" $
        checkError
          "missing/manifest"
          (MissingManifestFile "0001-missing.sql"),
      testCase "unlisted SQL files are rejected deterministically" $
        checkError
          "unlisted/manifest"
          (UnlistedSqlFiles ["0002-unlisted.sql"]),
      testCase "an empty manifest is rejected" $
        withTemporaryManifest "empty" ByteString.empty $ \manifestPath ->
          checkTemporaryError manifestPath EmptyManifest,
      testCase "surrounding entry whitespace is rejected" $
        withTemporaryManifest "whitespace" " 0001-first.sql\n" $ \manifestPath ->
          checkTemporaryError
            manifestPath
            (ManifestEntryHasSurroundingWhitespace 1 " 0001-first.sql"),
      testCase "invalid manifest UTF-8 is rejected" $
        withTemporaryManifest "invalid-utf8" (ByteString.pack [0xC3, 0x28]) $ \manifestPath -> do
          result <- checkMigrationManifest manifestPath
          case result of
            Left (ManifestInvalidUtf8 actualPath _) -> actualPath @?= manifestPath
            Left actual -> fail ("expected ManifestInvalidUtf8, received " <> show actual)
            Right _ -> fail "expected invalid manifest UTF-8 to fail",
      testCase "a manifest byte-order mark has a dedicated diagnostic"
        $ withTemporaryManifest
          "byte-order-mark"
          (ByteString.pack [0xEF, 0xBB, 0xBF] <> "0001-first.sql\n")
        $ \manifestPath ->
          checkTemporaryError manifestPath (ManifestByteOrderMark manifestPath)
    ]

validEmbedded :: NonEmpty (FilePath, ByteString.ByteString)
validEmbedded =
  $(embedMigrationManifest "test/fixtures/valid/migrations/manifest")

embeddedAllBytes :: ByteString.ByteString
embeddedAllBytes =
  $(pure (byteStringExpression (ByteString.pack [0 .. 255])))

largeFixtureSize :: Int
largeFixtureSize = 1024 * 1024 + 1

largeEmbeddedBytes :: ByteString.ByteString
largeEmbeddedBytes =
  $(pure (byteStringExpression (ByteString.replicate (1024 * 1024 + 1) 0xA5)))

checkError :: FilePath -> ManifestError -> IO ()
checkError relativePath expected = do
  result <- checkMigrationManifest =<< fixture relativePath
  case result of
    Left actual -> actual @?= expected
    Right _ -> fail ("expected Left " <> show expected <> ", received Right")

fixture :: FilePath -> IO FilePath
fixture relativePath =
  Paths.getDataFileName ("test/fixtures" </> relativePath)

checkTemporaryError :: FilePath -> ManifestError -> IO ()
checkTemporaryError manifestPath expected = do
  result <- checkMigrationManifest manifestPath
  case result of
    Left actual -> actual @?= expected
    Right _ -> fail ("expected Left " <> show expected <> ", received Right")

withTemporaryManifest :: String -> ByteString.ByteString -> (FilePath -> IO value) -> IO value
withTemporaryManifest label bytes action =
  Exception.bracket create remove action
  where
    create = do
      temporaryDirectory <- Directory.getTemporaryDirectory
      let directory = temporaryDirectory </> ("pg-migrate-embed-" <> label)
          manifestPath = directory </> "manifest"
      Directory.removePathForcibly directory `Exception.catch` ignoreMissing
      Directory.createDirectory directory
      ByteString.writeFile manifestPath bytes
      pure manifestPath
    remove manifestPath = Directory.removePathForcibly (FilePath.takeDirectory manifestPath)
    ignoreMissing :: IOError -> IO ()
    ignoreMissing _ = pure ()
