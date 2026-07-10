module Database.PostgreSQL.Migrate.Embed.Authoring
  ( NewMigrationOptions,
    AuthoringError (..),
    newMigrationOptions,
    newMigration,
    newMigrationWithRename,
  )
where

import Control.Exception (IOException)
import Control.Exception qualified as Exception
import Data.ByteString qualified as ByteString
import Data.Char qualified as Char
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate.Embed.Manifest
  ( ManifestError,
    checkMigrationManifest,
    validateManifestEntry,
  )
import System.Directory qualified as Directory
import System.FilePath qualified as FilePath
import System.IO (Handle)
import System.IO qualified as IO
import System.IO.Error qualified as IO.Error
import System.Posix.IO qualified as Posix

-- | Validated exclusive-create settings for one new migration file.
data NewMigrationOptions = NewMigrationOptions
  { manifestPath :: !FilePath,
    explicitName :: !(Maybe FilePath),
    initialSql :: !ByteString.ByteString
  }
  deriving stock (Eq, Show)

-- | Structured option, filesystem, or manifest replacement failure.
data AuthoringError
  = InvalidAuthoringManifestPath !FilePath
  | InvalidNewMigrationName !ManifestError
  | AuthoringManifestError !ManifestError
  | ExplicitMigrationNameRequired
  | MigrationSequenceExhausted !Int
  | MigrationFileAlreadyExists !FilePath
  | AuthoringIoError !FilePath !Text.Text
  | AuthoringCleanupError !FilePath !Text.Text
  deriving stock (Eq, Show)

-- | Validate manifest path and optional explicit migration name.
newMigrationOptions ::
  FilePath ->
  Maybe FilePath ->
  ByteString.ByteString ->
  Either AuthoringError NewMigrationOptions
newMigrationOptions manifestPath requestedName initialSql
  | null manifestPath = Left (InvalidAuthoringManifestPath manifestPath)
  | FilePath.hasTrailingPathSeparator manifestPath =
      Left (InvalidAuthoringManifestPath manifestPath)
  | otherwise = do
      explicitName <- traverse normalizeExplicitName requestedName
      Right NewMigrationOptions {manifestPath, explicitName, initialSql}

-- | Exclusively create a SQL file and atomically append its manifest entry.
newMigration :: NewMigrationOptions -> IO (Either AuthoringError FilePath)
newMigration = newMigrationWithRename Directory.renameFile

newMigrationWithRename ::
  (FilePath -> FilePath -> IO ()) ->
  NewMigrationOptions ->
  IO (Either AuthoringError FilePath)
newMigrationWithRename renameFile options@NewMigrationOptions {manifestPath} = do
  manifestResult <- checkMigrationManifest manifestPath
  case firstLeft AuthoringManifestError manifestResult of
    Left err -> pure (Left err)
    Right entries ->
      case chooseMigrationName options (fst <$> entries) of
        Left err -> pure (Left err)
        Right entry -> createAndAppend renameFile options entry

normalizeExplicitName :: FilePath -> Either AuthoringError FilePath
normalizeExplicitName requestedName =
  firstLeft InvalidNewMigrationName (validateManifestEntry normalizedName)
  where
    normalizedName =
      case FilePath.takeExtension requestedName of
        "" -> requestedName <> ".sql"
        _ -> requestedName

chooseMigrationName ::
  NewMigrationOptions ->
  NonEmpty FilePath ->
  Either AuthoringError FilePath
chooseMigrationName NewMigrationOptions {explicitName = Just entry} _ = Right entry
chooseMigrationName NewMigrationOptions {explicitName = Nothing} entries =
  automaticMigrationName entries

automaticMigrationName :: NonEmpty FilePath -> Either AuthoringError FilePath
automaticMigrationName entries =
  case traverse numericPrefix entries of
    Nothing -> Left ExplicitMigrationNameRequired
    Just prefixes ->
      let width = fst (NonEmpty.head prefixes)
       in if all ((== width) . fst) prefixes
            then renderNextMigrationName width (maximum (snd <$> prefixes) + 1)
            else Left ExplicitMigrationNameRequired

renderNextMigrationName :: Int -> Integer -> Either AuthoringError FilePath
renderNextMigrationName width next =
  let rendered = show next
   in if length rendered > width
        then Left (MigrationSequenceExhausted width)
        else
          firstLeft
            InvalidNewMigrationName
            (validateManifestEntry (replicate (width - length rendered) '0' <> rendered <> ".sql"))

numericPrefix :: FilePath -> Maybe (Int, Integer)
numericPrefix entry = do
  let basename = FilePath.dropExtension entry
      (digits, suffix) = span Char.isDigit basename
  guardMaybe $ case digits of
    '0' : _ : _ -> True
    _ -> False
  guardMaybe (null suffix || "-" `List.isPrefixOf` suffix)
  value <- readInteger digits
  pure (length digits, value)

readInteger :: String -> Maybe Integer
readInteger value =
  case reads value of
    [(parsed, "")] -> Just parsed
    _ -> Nothing

guardMaybe :: Bool -> Maybe ()
guardMaybe condition
  | condition = Just ()
  | otherwise = Nothing

createAndAppend ::
  (FilePath -> FilePath -> IO ()) ->
  NewMigrationOptions ->
  FilePath ->
  IO (Either AuthoringError FilePath)
createAndAppend renameFile NewMigrationOptions {manifestPath, initialSql} entry = do
  originalResult <- tryIOException (ByteString.readFile manifestPath)
  case originalResult of
    Left err -> pure (Left (authoringIoError manifestPath err))
    Right originalManifest -> do
      let migrationPath = FilePath.takeDirectory manifestPath FilePath.</> entry
      creationResult <- createExclusive migrationPath initialSql
      case creationResult of
        Left err -> pure (Left err)
        Right () -> do
          replacementResult <-
            replaceManifest renameFile manifestPath (appendEntry originalManifest entry)
          case replacementResult of
            Right () -> pure (Right migrationPath)
            Left replacementError -> do
              cleanupResult <- tryIOException (Directory.removeFile migrationPath)
              pure $ case cleanupResult of
                Left cleanupError -> Left (cleanupIoError migrationPath cleanupError)
                Right () -> Left replacementError

createExclusive :: FilePath -> ByteString.ByteString -> IO (Either AuthoringError ())
createExclusive path contents = do
  openResult <-
    tryIOException
      ( Posix.openFd
          path
          Posix.WriteOnly
          Posix.defaultFileFlags
            { Posix.exclusive = True,
              Posix.creat = Just 0o644
            }
      )
  case openResult of
    Left err
      | IO.Error.isAlreadyExistsError err ->
          pure (Left (MigrationFileAlreadyExists path))
      | otherwise -> pure (Left (authoringIoError path err))
    Right fileDescriptor -> do
      handleResult <- tryIOException (Posix.fdToHandle fileDescriptor)
      case handleResult of
        Left err -> do
          ignoreIOException (Posix.closeFd fileDescriptor)
          cleanupCreatedFile path (authoringIoError path err)
        Right handle -> do
          writeResult <-
            tryIOException
              (ByteString.hPut handle contents >> IO.hFlush handle >> IO.hClose handle)
          case writeResult of
            Right () -> pure (Right ())
            Left err -> do
              ignoreIOException (IO.hClose handle)
              cleanupCreatedFile path (authoringIoError path err)

cleanupCreatedFile :: FilePath -> AuthoringError -> IO (Either AuthoringError ())
cleanupCreatedFile path originalError = do
  cleanupResult <- tryIOException (Directory.removeFile path)
  pure $ case cleanupResult of
    Left err -> Left (cleanupIoError path err)
    Right () -> Left originalError

replaceManifest ::
  (FilePath -> FilePath -> IO ()) ->
  FilePath ->
  ByteString.ByteString ->
  IO (Either AuthoringError ())
replaceManifest renameFile manifestPath contents = do
  let directory = FilePath.takeDirectory manifestPath
      temporaryTemplate = FilePath.takeFileName manifestPath <> ".tmp"
  temporaryResult <-
    tryIOException (IO.openBinaryTempFileWithDefaultPermissions directory temporaryTemplate)
  case temporaryResult of
    Left err -> pure (Left (authoringIoError manifestPath err))
    Right (temporaryPath, handle) -> do
      replacementResult <-
        tryIOException
          ( ByteString.hPut handle contents
              >> IO.hFlush handle
              >> IO.hClose handle
              >> renameFile temporaryPath manifestPath
          )
      case replacementResult of
        Right () -> pure (Right ())
        Left err -> do
          cleanupTemporaryFile handle temporaryPath
          pure (Left (authoringIoError manifestPath err))

cleanupTemporaryFile :: Handle -> FilePath -> IO ()
cleanupTemporaryFile handle path = do
  ignoreIOException (IO.hClose handle)
  ignoreIOException (Directory.removeFile path)

appendEntry :: ByteString.ByteString -> FilePath -> ByteString.ByteString
appendEntry original entry =
  original
    <> separator
    <> Text.Encoding.encodeUtf8 (Text.pack entry)
    <> "\n"
  where
    separator
      | ByteString.null original = ByteString.empty
      | ByteString.last original == 0x0A = ByteString.empty
      | otherwise = "\n"

authoringIoError :: FilePath -> IOException -> AuthoringError
authoringIoError path err = AuthoringIoError path (Text.pack (show err))

cleanupIoError :: FilePath -> IOException -> AuthoringError
cleanupIoError path err = AuthoringCleanupError path (Text.pack (show err))

tryIOException :: IO value -> IO (Either IOException value)
tryIOException = Exception.try

ignoreIOException :: IO value -> IO ()
ignoreIOException action = do
  _ <- tryIOException action
  pure ()

firstLeft :: (error -> mappedError) -> Either error value -> Either mappedError value
firstLeft mapError = either (Left . mapError) Right
