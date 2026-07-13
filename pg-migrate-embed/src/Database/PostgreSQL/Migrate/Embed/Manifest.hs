module Database.PostgreSQL.Migrate.Embed.Manifest
  ( manifestFormatVersion,
    ManifestError (..),
    checkMigrationManifest,
    embedMigrationManifest,
    validateManifestEntry,
    byteStringExpression,
  )
where

import Control.Exception (IOException)
import Control.Exception qualified as Exception
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Internal qualified as ByteString.Internal
import Data.Foldable (toList, traverse_)
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Language.Haskell.TH
  ( Exp (..),
    Lit (..),
    Q,
  )
import Language.Haskell.TH.Lib qualified as TH.Lib
import Language.Haskell.TH.Syntax qualified as TH.Syntax
import System.Directory qualified as Directory
import System.FilePath qualified as FilePath

-- | Supported ordered-manifest contract version.
manifestFormatVersion :: Int
manifestFormatVersion = 1

-- | Exact manifest syntax, path, membership, or SQL validation failure.
data ManifestError
  = ManifestIoError !FilePath !Text.Text
  | ManifestInvalidUtf8 !FilePath !Text.Text
  | EmptyManifest
  | BlankManifestLine !Int
  | CommentManifestLine !Int
  | ManifestEntryHasSurroundingWhitespace !Int !FilePath
  | AbsoluteManifestEntry !Int !FilePath
  | ParentTraversalManifestEntry !Int !FilePath
  | NestedManifestEntry !Int !FilePath
  | NonSqlManifestEntry !Int !FilePath
  | EmptySqlBasename !Int
  | DuplicateManifestEntry !FilePath !Int !Int
  | MissingManifestFile !FilePath
  | UnlistedSqlFiles ![FilePath]
  deriving stock (Eq, Show)

-- | Validate a manifest and return ordered exact SQL bytes at runtime.
checkMigrationManifest ::
  FilePath ->
  IO (Either ManifestError (NonEmpty (FilePath, ByteString.ByteString)))
checkMigrationManifest manifestPath = do
  manifestResult <- tryIOException (ByteString.readFile manifestPath)
  case manifestResult of
    Left err -> pure (Left (ManifestIoError manifestPath (Text.pack (show err))))
    Right manifestBytes ->
      case parseManifest manifestPath manifestBytes of
        Left err -> pure (Left err)
        Right entries -> checkManifestFiles manifestPath entries

-- | Validate and embed an ordered migration manifest at compile time.
embedMigrationManifest :: FilePath -> Q Exp
embedMigrationManifest inputPath = do
  manifestPath <- TH.Syntax.makeRelativeToProject inputPath
  TH.Syntax.addDependentFile manifestPath
  result <- TH.Syntax.runIO (checkMigrationManifest manifestPath)
  case result of
    Left err -> fail ("invalid pg-migrate manifest: " <> show err)
    Right entries -> do
      let directory = FilePath.takeDirectory manifestPath
      traverse_
        (TH.Syntax.addDependentFile . (directory FilePath.</>) . fst)
        entries
      pure (nonEmptyExpression entries)

parseManifest :: FilePath -> ByteString.ByteString -> Either ManifestError (NonEmpty FilePath)
parseManifest manifestPath manifestBytes = do
  manifestText <-
    first
      (ManifestInvalidUtf8 manifestPath . Text.pack . show)
      (Text.Encoding.decodeUtf8' manifestBytes)
  let numberedLines = zip [1 ..] (normalizeLineEnding <$> Text.lines manifestText)
  entries <- traverse validateManifestLine numberedLines
  nonEmptyEntries <-
    case entries of
      firstEntry : remainingEntries -> Right (firstEntry :| remainingEntries)
      [] -> Left EmptyManifest
  validateDuplicates nonEmptyEntries

normalizeLineEnding :: Text.Text -> Text.Text
normalizeLineEnding = Text.dropWhileEnd (== '\r')

validateManifestLine :: (Int, Text.Text) -> Either ManifestError FilePath
validateManifestLine (lineNumber, entryText)
  | Text.null entryText = Left (BlankManifestLine lineNumber)
  | "#" `Text.isPrefixOf` Text.stripStart entryText =
      Left (CommentManifestLine lineNumber)
  | "--" `Text.isPrefixOf` Text.stripStart entryText =
      Left (CommentManifestLine lineNumber)
  | Text.strip entryText /= entryText =
      Left (ManifestEntryHasSurroundingWhitespace lineNumber entry)
  | FilePath.isAbsolute entry = Left (AbsoluteManifestEntry lineNumber entry)
  | ".." `elem` FilePath.splitDirectories entry =
      Left (ParentTraversalManifestEntry lineNumber entry)
  | FilePath.takeFileName entry /= entry = Left (NestedManifestEntry lineNumber entry)
  | FilePath.takeExtension entry /= ".sql" = Left (NonSqlManifestEntry lineNumber entry)
  | null (FilePath.dropExtension entry) = Left (EmptySqlBasename lineNumber)
  | otherwise = Right entry
  where
    entry = Text.unpack entryText

validateManifestEntry :: FilePath -> Either ManifestError FilePath
validateManifestEntry entry = validateManifestLine (1, Text.pack entry)

validateDuplicates :: NonEmpty FilePath -> Either ManifestError (NonEmpty FilePath)
validateDuplicates entries = go [] (zip [1 ..] (toList entries))
  where
    go _ [] = Right entries
    go seen ((lineNumber, entry) : remaining) =
      case List.lookup entry seen of
        Just firstLine -> Left (DuplicateManifestEntry entry firstLine lineNumber)
        Nothing -> go ((entry, lineNumber) : seen) remaining

checkManifestFiles ::
  FilePath ->
  NonEmpty FilePath ->
  IO (Either ManifestError (NonEmpty (FilePath, ByteString.ByteString)))
checkManifestFiles manifestPath entries = do
  let directory = FilePath.takeDirectory manifestPath
      listedEntries = toList entries
  directoryResult <- tryIOException (Directory.listDirectory directory)
  case directoryResult of
    Left err -> pure (Left (ManifestIoError directory (Text.pack (show err))))
    Right directoryEntries ->
      case List.sort
        [ entry
        | entry <- directoryEntries,
          FilePath.takeExtension entry == ".sql",
          entry `notElem` listedEntries
        ] of
        unlisted@(_ : _) -> pure (Left (UnlistedSqlFiles unlisted))
        [] -> readManifestFiles directory entries

readManifestFiles ::
  FilePath ->
  NonEmpty FilePath ->
  IO (Either ManifestError (NonEmpty (FilePath, ByteString.ByteString)))
readManifestFiles directory entries = do
  results <- traverse readEntry entries
  pure (sequence results)
  where
    readEntry entry = do
      let path = directory FilePath.</> entry
      exists <- Directory.doesFileExist path
      if not exists
        then pure (Left (MissingManifestFile entry))
        else do
          result <- tryIOException (ByteString.readFile path)
          pure $ case result of
            Left err -> Left (ManifestIoError path (Text.pack (show err)))
            Right bytes -> Right (entry, bytes)

nonEmptyExpression :: NonEmpty (FilePath, ByteString.ByteString) -> Exp
nonEmptyExpression (firstEntry :| remainingEntries) =
  AppE
    (AppE (ConE '(:|)) (entryExpression firstEntry))
    (ListE (entryExpression <$> remainingEntries))

entryExpression :: (FilePath, ByteString.ByteString) -> Exp
entryExpression (entry, bytes) =
  TupE
    [ Just (LitE (StringL entry)),
      Just (byteStringExpression bytes)
    ]

byteStringExpression :: ByteString.ByteString -> Exp
byteStringExpression bytes =
  let (foreignPointer, offset, length_) = ByteString.Internal.toForeignPtr bytes
   in AppE
        ( AppE
            (VarE 'ByteString.Internal.unsafePackLenLiteral)
            (LitE (IntegerL (fromIntegral length_)))
        )
        ( LitE
            ( TH.Lib.bytesPrimL
                ( TH.Lib.mkBytes
                    foreignPointer
                    (fromIntegral offset)
                    (fromIntegral length_)
                )
            )
        )

tryIOException :: IO value -> IO (Either IOException value)
tryIOException = Exception.try
