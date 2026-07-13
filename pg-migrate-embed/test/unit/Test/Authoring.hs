module Test.Authoring (tests) where

import Control.Exception qualified as Exception
import Control.Monad (forM_)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.Foldable (traverse_)
import Data.List qualified as List
import Database.PostgreSQL.Migrate.Embed
import Database.PostgreSQL.Migrate.Embed.Internal
  ( newMigrationWithRename,
    numericPrefix,
    renderNextMigrationName,
  )
import System.Directory qualified as Directory
import System.FilePath qualified as FilePath
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "authoring"
    [ testCase "numeric manifests create and append the next sequence" $
        withWorkspace "next" numericFiles $ \manifestPath -> do
          options <- assertRight (newMigrationOptions manifestPath Nothing "SELECT 3;\n")
          result <- newMigration options
          let expectedPath = FilePath.takeDirectory manifestPath FilePath.</> "0003.sql"
          result @?= Right expectedPath
          actualSql <- ByteString.readFile expectedPath
          actualSql @?= "SELECT 3;\n"
          actualManifest <- ByteString.readFile manifestPath
          actualManifest @?= "0001-first.sql\n0002-second.sql\n0003.sql\n",
      testCase "explicit names work when the existing sequence is irregular" $
        withWorkspace "explicit" [("first.sql", "SELECT 1;\n")] $ \manifestPath -> do
          automatic <- assertRight (newMigrationOptions manifestPath Nothing "SELECT 2;\n")
          automaticResult <- newMigration automatic
          automaticResult @?= Left ExplicitMigrationNameRequired
          explicit <- assertRight (newMigrationOptions manifestPath (Just "second") "SELECT 2;\n")
          result <- newMigration explicit
          result
            @?= Right (FilePath.takeDirectory manifestPath FilePath.</> "second.sql"),
      testCase "automatic names require a zero-padded numeric sequence" $
        withWorkspace "not-zero-padded" [("1001-first.sql", "SELECT 1;\n")] $ \manifestPath -> do
          options <- assertRight (newMigrationOptions manifestPath Nothing "SELECT 2;\n")
          result <- newMigration options
          result @?= Left ExplicitMigrationNameRequired,
      testCase "next automatic name after 08 is 09" $
        withWorkspace "next-nine" (numberedFiles 2 [1 .. 8]) $ \manifestPath -> do
          options <- assertRight (newMigrationOptions manifestPath Nothing "SELECT 9;\n")
          result <- newMigration options
          result
            @?= Right (FilePath.takeDirectory manifestPath FilePath.</> "09.sql"),
      testCase "successor of 09 at width 2 is exhausted" $
        withWorkspace "width-two-exhausted" (numberedFiles 2 [1 .. 9]) $ \manifestPath -> do
          options <- assertRight (newMigrationOptions manifestPath Nothing "SELECT 10;\n")
          result <- newMigration options
          result @?= Left (MigrationSequenceExhausted 2),
      testCase "successor of 0999 at width 4 is exhausted" $
        withWorkspace "width-four-exhausted" [("0999.sql", "SELECT 999;\n")] $ \manifestPath -> do
          options <- assertRight (newMigrationOptions manifestPath Nothing "SELECT 1000;\n")
          result <- newMigration options
          result @?= Left (MigrationSequenceExhausted 4),
      testCase "automatic names round-trip through numeric-prefix inference" $
        forM_ roundTripCases $ \(width, next) -> do
          entry <- assertRight (renderNextMigrationName width next)
          numericPrefix entry @?= Just (width, next),
      testCase "exclusive creation refuses an existing migration" $
        withWorkspace "collision" [("0001-first.sql", "SELECT 1;\n")] $ \manifestPath -> do
          originalManifest <- ByteString.readFile manifestPath
          options <-
            assertRight
              (newMigrationOptions manifestPath (Just "0001-first") "replacement")
          result <- newMigration options
          result
            @?= Left
              ( MigrationFileAlreadyExists
                  (FilePath.takeDirectory manifestPath FilePath.</> "0001-first.sql")
              )
          actualManifest <- ByteString.readFile manifestPath
          actualManifest @?= originalManifest
          existingSql <-
            ByteString.readFile
              (FilePath.takeDirectory manifestPath FilePath.</> "0001-first.sql")
          existingSql @?= "SELECT 1;\n",
      testCase "failed manifest replacement removes only the newly created file" $
        withWorkspace "replacement-failure" [("0001-first.sql", "SELECT 1;\n")] $ \manifestPath -> do
          originalManifest <- ByteString.readFile manifestPath
          options <- assertRight (newMigrationOptions manifestPath Nothing "SELECT 2;\n")
          result <- newMigrationWithRename failingRename options
          case result of
            Left (AuthoringIoError actualPath _) -> actualPath @?= manifestPath
            Left actual -> assertFailure ("expected AuthoringIoError, received " <> show actual)
            Right path -> assertFailure ("expected replacement failure, created " <> path)
          actualManifest <- ByteString.readFile manifestPath
          actualManifest @?= originalManifest
          createdFileExists <-
            Directory.doesPathExist
              (FilePath.takeDirectory manifestPath FilePath.</> "0002.sql")
          createdFileExists @?= False
          directoryEntries <- List.sort <$> Directory.listDirectory (FilePath.takeDirectory manifestPath)
          directoryEntries @?= ["0001-first.sql", "manifest"],
      testCase "a post-rename clobber is detected and the new SQL file is removed" $
        withWorkspace "concurrent-modification" [("0001-first.sql", "SELECT 1;\n")] $ \manifestPath -> do
          originalManifest <- ByteString.readFile manifestPath
          options <- assertRight (newMigrationOptions manifestPath Nothing "SELECT 2;\n")
          let clobberingRename temporaryPath destinationPath = do
                Directory.renameFile temporaryPath destinationPath
                ByteString.writeFile destinationPath originalManifest
          result <- newMigrationWithRename clobberingRename options
          result @?= Left (AuthoringConcurrentModification manifestPath)
          ByteString.readFile manifestPath >>= (@?= originalManifest)
          Directory.doesFileExist
            (FilePath.takeDirectory manifestPath FilePath.</> "0002.sql")
            >>= (@?= False),
      testCase "option construction rejects nested explicit names" $
        case newMigrationOptions "migrations/manifest" (Just "../outside") "SELECT 1" of
          Left (InvalidNewMigrationName (ParentTraversalManifestEntry 1 "../outside.sql")) -> pure ()
          actual -> assertFailure ("expected parent traversal failure, received " <> show actual),
      testCase "option construction rejects a directory as the manifest path" $
        newMigrationOptions "migrations/" Nothing "SELECT 1"
          @?= Left (InvalidAuthoringManifestPath "migrations/")
    ]

numericFiles :: [(FilePath, ByteString.ByteString)]
numericFiles =
  [ ("0001-first.sql", "SELECT 1;\n"),
    ("0002-second.sql", "SELECT 2;\n")
  ]

numberedFiles :: Int -> [Integer] -> [(FilePath, ByteString.ByteString)]
numberedFiles width =
  fmap $ \number ->
    ( replicate (width - length (show number)) '0' <> show number <> ".sql",
      "SELECT " <> ByteString.Char8.pack (show number) <> ";\n"
    )

roundTripCases :: [(Int, Integer)]
roundTripCases =
  [ (width, next)
  | width <- [2 .. 6],
    next <- [1, 8, 9, 10, 99, 100, 999],
    length (show next) < width
  ]

withWorkspace ::
  String ->
  [(FilePath, ByteString.ByteString)] ->
  (FilePath -> IO value) ->
  IO value
withWorkspace label files action =
  Exception.bracket create remove action
  where
    create = do
      temporaryDirectory <- Directory.getTemporaryDirectory
      let directory = temporaryDirectory FilePath.</> ("pg-migrate-authoring-" <> label)
          manifestPath = directory FilePath.</> "manifest"
      Directory.removePathForcibly directory `Exception.catch` ignoreMissing
      Directory.createDirectory directory
      traverse_
        (\(entry, contents) -> ByteString.writeFile (directory FilePath.</> entry) contents)
        files
      ByteString.writeFile manifestPath (manifestBytes files)
      pure manifestPath
    remove manifestPath = Directory.removePathForcibly (FilePath.takeDirectory manifestPath)
    ignoreMissing :: IOError -> IO ()
    ignoreMissing _ = pure ()

manifestBytes :: [(FilePath, ByteString.ByteString)] -> ByteString.ByteString
manifestBytes files =
  ByteString.concat [ByteString.Char8.pack entry <> "\n" | (entry, _) <- files]

failingRename :: FilePath -> FilePath -> IO ()
failingRename _ _ = ioError (userError "simulated manifest replacement failure")

assertRight :: (Show error) => Either error value -> IO value
assertRight = \case
  Left err -> assertFailure ("expected Right, received Left " <> show err)
  Right value -> pure value
