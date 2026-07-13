module Main (main) where

import Control.Exception qualified as Exception
import Control.Monad (filterM, unless, when)
import Data.List (isInfixOf, isPrefixOf)
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
  corePackageRoot <- resolvePackageRoot repositoryRoot "pg-migrate" "pg-migrate.cabal"
  assertFileExists (packageRoot FilePath.</> "pg-migrate-embed.cabal")
  withTemporaryDirectory $ \workspace -> do
    copyDirectory fixtureSource workspace
    writeProjectFile corePackageRoot packageRoot workspace
    prepareProbe workspace
    directoryModuleTimestamp <-
      Directory.getModificationTime (workspace FilePath.</> "app/Main.hs")
    trackedModuleTimestamp <-
      Directory.getModificationTime (workspace FilePath.</> "app/TrackedMain.hs")

    directoryOutput <- runDirectoryProbe workspace
    let unlistedPath = workspace FilePath.</> "migrations/0002-unlisted.sql"
    writeFile unlistedPath "SELECT 2;\n"
    runDirectoryProbeExpectingFailure
      workspace
      "UnlistedSqlFiles [\"0002-unlisted.sql\"]"
    Directory.removeFile unlistedPath
    directoryOutputAfterRemoval <- runDirectoryProbe workspace
    unless (directoryOutputAfterRemoval == directoryOutput) $
      fail "removing the unlisted SQL file changed the embedded checksums"

    initialOutput <- runTrackedProbe workspace
    writeTrackedFile (workspace FilePath.</> "migrations/0001-first.sql") "SELECT 2;\n"
    sqlChangedOutput <- runTrackedProbe workspace
    when (sqlChangedOutput == initialOutput) $
      fail "changing a tracked SQL file did not change the embedded checksums"

    writeFile (workspace FilePath.</> "migrations/0002-second.sql") "SELECT 3;\n"
    writeTrackedFile
      (workspace FilePath.</> "migrations/manifest")
      "0001-first.sql\n0002-second.sql\n"
    manifestChangedOutput <- runTrackedProbe workspace
    when (manifestChangedOutput == sqlChangedOutput) $
      fail "changing the manifest did not change the embedded checksums"
    unless (length (lines manifestChangedOutput) == 2) $
      fail "the rebuilt probe did not embed both manifest entries"

    finalDirectoryModuleTimestamp <-
      Directory.getModificationTime (workspace FilePath.</> "app/Main.hs")
    finalTrackedModuleTimestamp <-
      Directory.getModificationTime (workspace FilePath.</> "app/TrackedMain.hs")
    unless
      ( finalDirectoryModuleTimestamp == directoryModuleTimestamp
          && finalTrackedModuleTimestamp == trackedModuleTimestamp
      )
      $ fail "the recompilation test unexpectedly touched a Haskell module"

runDirectoryProbe :: FilePath -> IO String
runDirectoryProbe workspace = do
  _ <-
    runChecked
      workspace
      "cabal"
      directoryProbeArguments
  runChecked workspace (workspace FilePath.</> "ghc-directory-recompilation/probe") []

runDirectoryProbeExpectingFailure :: FilePath -> String -> IO ()
runDirectoryProbeExpectingFailure workspace expectedError = do
  let command =
        (Process.proc "cabal" directoryProbeArguments)
          { Process.cwd = Just workspace
          }
  (exitCode, standardOutput, standardError) <-
    Process.readCreateProcessWithExitCode command ""
  case exitCode of
    ExitFailure _ ->
      unless (expectedError `isInfixOf` (standardOutput <> standardError)) $
        fail
          ( "probe compilation failed without the expected diagnostic "
              <> show expectedError
              <> ":\n"
              <> standardError
          )
    ExitSuccess ->
      fail "adding an unlisted SQL file did not force manifest revalidation"

runTrackedProbe :: FilePath -> IO String
runTrackedProbe workspace = do
  _ <-
    runChecked
      workspace
      "cabal"
      trackedProbeArguments
  runChecked workspace (workspace FilePath.</> "ghc-tracked-recompilation/probe") []

directoryProbeArguments :: [String]
directoryProbeArguments =
  ghcArguments
    "app/Main.hs"
    Nothing
    "ghc-directory-recompilation"

trackedProbeArguments :: [String]
trackedProbeArguments =
  ghcArguments
    "app/TrackedMain.hs"
    (Just "TrackedMain")
    "ghc-tracked-recompilation"

ghcArguments :: FilePath -> Maybe String -> FilePath -> [String]
ghcArguments source mainModule outputDirectory =
  [ "exec",
    "--builddir=dist-recompilation",
    "--",
    "ghc",
    "--make",
    source,
    "-o",
    outputDirectory FilePath.</> "probe",
    "-odir",
    outputDirectory,
    "-hidir",
    outputDirectory,
    "-package",
    "pg-migrate",
    "-package",
    "pg-migrate-embed",
    "-XGHC2024",
    "-XOverloadedStrings",
    "-XTemplateHaskell"
  ]
    <> maybe [] (\moduleName -> ["-main-is", moduleName]) mainModule

prepareProbe :: FilePath -> IO ()
prepareProbe workspace = do
  Directory.createDirectory (workspace FilePath.</> "ghc-directory-recompilation")
  Directory.createDirectory (workspace FilePath.</> "ghc-tracked-recompilation")
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

writeProjectFile :: FilePath -> FilePath -> FilePath -> IO ()
writeProjectFile corePackageRoot embedPackageRoot workspace =
  writeFile
    (workspace FilePath.</> "cabal.project")
    ( unlines
        [ "packages:",
          "  .",
          "  " <> corePackageRoot,
          "  " <> embedPackageRoot,
          "tests: False",
          "benchmarks: False"
        ]
    )

resolvePackageRoot :: FilePath -> FilePath -> FilePath -> IO FilePath
resolvePackageRoot parent packageName cabalFile = do
  let exact = parent FilePath.</> packageName
  exactExists <- Directory.doesFileExist (exact FilePath.</> cabalFile)
  if exactExists
    then pure exact
    else do
      entries <- Directory.listDirectory parent
      let candidates =
            [ parent FilePath.</> entry
            | entry <- entries,
              (packageName <> "-") `isPrefixOf` entry
            ]
      matching <- filterM (Directory.doesFileExist . (FilePath.</> cabalFile)) candidates
      case matching of
        [resolved] -> pure resolved
        _ -> fail ("could not resolve source distribution for " <> packageName)

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
