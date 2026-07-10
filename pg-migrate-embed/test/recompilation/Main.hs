module Main (main) where

import Control.Exception qualified as Exception
import Control.Monad (unless, when)
import Data.Time.Clock qualified as Time
import Paths_pg_migrate_embed qualified as Paths
import System.Directory qualified as Directory
import System.Exit (ExitCode (..))
import System.FilePath qualified as FilePath
import System.IO qualified as IO
import System.Process qualified as Process

main :: IO ()
main = do
  fixtureCabal <-
    Paths.getDataFileName "test/recompilation/fixture/recompilation-probe.cabal"
  let fixtureSource = FilePath.normalise (FilePath.takeDirectory fixtureCabal)
      packageRoot =
        FilePath.normalise
          ( FilePath.takeDirectory
              (FilePath.takeDirectory (FilePath.takeDirectory fixtureSource))
          )
      repositoryRoot = FilePath.takeDirectory packageRoot
  assertFileExists (packageRoot FilePath.</> "pg-migrate-embed.cabal")
  assertFileExists (repositoryRoot FilePath.</> "cabal.project")
  withTemporaryDirectory $ \workspace -> do
    copyDirectory fixtureSource workspace
    writeProjectFile repositoryRoot workspace
    prepareProbe workspace
    moduleTimestamp <- Directory.getModificationTime (workspace FilePath.</> "app/Main.hs")

    initialOutput <- runProbe workspace
    writeTrackedFile (workspace FilePath.</> "migrations/0001-first.sql") "SELECT 2;\n"
    sqlChangedOutput <- runProbe workspace
    when (sqlChangedOutput == initialOutput) $
      fail "changing a tracked SQL file did not change the embedded checksums"

    writeFile (workspace FilePath.</> "migrations/0002-second.sql") "SELECT 3;\n"
    writeTrackedFile
      (workspace FilePath.</> "migrations/manifest")
      "0001-first.sql\n0002-second.sql\n"
    manifestChangedOutput <- runProbe workspace
    when (manifestChangedOutput == sqlChangedOutput) $
      fail "changing the manifest did not change the embedded checksums"
    unless (length (lines manifestChangedOutput) == 2) $
      fail "the rebuilt probe did not embed both manifest entries"

    finalModuleTimestamp <- Directory.getModificationTime (workspace FilePath.</> "app/Main.hs")
    unless (finalModuleTimestamp == moduleTimestamp) $
      fail "the recompilation test unexpectedly touched the Haskell module"

runProbe :: FilePath -> IO String
runProbe workspace = do
  _ <-
    runChecked
      workspace
      "cabal"
      [ "exec",
        "--builddir=dist-recompilation",
        "--",
        "ghc",
        "--make",
        "app/Main.hs",
        "-o",
        "ghc-recompilation/probe",
        "-odir",
        "ghc-recompilation",
        "-hidir",
        "ghc-recompilation",
        "-package",
        "pg-migrate",
        "-package",
        "pg-migrate-embed",
        "-XGHC2024",
        "-XOverloadedStrings",
        "-XTemplateHaskell"
      ]
  runChecked workspace (workspace FilePath.</> "ghc-recompilation/probe") []

prepareProbe :: FilePath -> IO ()
prepareProbe workspace = do
  Directory.createDirectory (workspace FilePath.</> "ghc-recompilation")
  _ <-
    runChecked
      workspace
      "cabal"
      [ "build",
        "pg-migrate",
        "pg-migrate-embed",
        "--builddir=dist-recompilation"
      ]
  pure ()

runChecked :: FilePath -> FilePath -> [String] -> IO String
runChecked workspace executable arguments = do
  let command =
        (Process.proc executable arguments)
          { Process.cwd = Just workspace
          }
  (exitCode, standardOutput, standardError) <-
    Process.readCreateProcessWithExitCode command ""
  case exitCode of
    ExitSuccess -> pure standardOutput
    ExitFailure code ->
      fail
        ( executable
            <> " failed with exit code "
            <> show code
            <> ":\n"
            <> standardError
        )

writeTrackedFile :: FilePath -> String -> IO ()
writeTrackedFile path contents = do
  writeFile path contents
  now <- Time.getCurrentTime
  Directory.setModificationTime path (Time.addUTCTime 2 now)

writeProjectFile :: FilePath -> FilePath -> IO ()
writeProjectFile repositoryRoot workspace =
  writeFile
    (workspace FilePath.</> "cabal.project")
    ( unlines
        [ "packages:",
          "  .",
          "  " <> (repositoryRoot FilePath.</> "pg-migrate"),
          "  " <> (repositoryRoot FilePath.</> "pg-migrate-embed"),
          "tests: False",
          "benchmarks: False"
        ]
    )

copyDirectory :: FilePath -> FilePath -> IO ()
copyDirectory source destination = do
  Directory.createDirectoryIfMissing True destination
  entries <- Directory.listDirectory source
  mapM_ copyEntry entries
  where
    copyEntry entry = do
      let sourcePath = source FilePath.</> entry
          destinationPath = destination FilePath.</> entry
      isDirectory <- Directory.doesDirectoryExist sourcePath
      if isDirectory
        then copyDirectory sourcePath destinationPath
        else Directory.copyFile sourcePath destinationPath

withTemporaryDirectory :: (FilePath -> IO value) -> IO value
withTemporaryDirectory = Exception.bracket create Directory.removePathForcibly
  where
    create = do
      parent <- Directory.getTemporaryDirectory
      (path, handle) <- IO.openTempFile parent "pg-migrate-recompilation"
      IO.hClose handle
      Directory.removeFile path
      Directory.createDirectory path
      pure path

assertFileExists :: FilePath -> IO ()
assertFileExists path = do
  exists <- Directory.doesFileExist path
  unless exists (fail ("required source file does not exist: " <> path))
