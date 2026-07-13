module Database.PostgreSQL.Migrate.History.Codd.Manifest
  ( parseCoddManifest,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate.History.Codd.Types
import PgMigrate.History.Codd.Prelude

-- | Parse expected SHA-256 checksums keyed by Codd source filename.
parseCoddManifest :: Text -> Either CoddDefinitionError CoddManifest
parseCoddManifest contents =
  CoddManifest <$> foldl parseLine (Right Map.empty) (zip [1 ..] (Text.lines contents))
  where
    parseLine accumulated (lineNumber, line) = do
      entries <- accumulated
      case Text.words line of
        [checksum, filenameText]
          | validChecksum checksum ->
              let filename = Text.unpack filenameText
               in if null filename
                    then Left (InvalidCoddManifestLine lineNumber)
                    else
                      if Map.member filename entries
                        then Left (DuplicateCoddManifestFilename filename)
                        else Right (Map.insert filename checksum entries)
          | otherwise -> Left (InvalidCoddManifestChecksum lineNumber checksum)
        _ -> Left (InvalidCoddManifestLine lineNumber)

validChecksum :: Text -> Bool
validChecksum checksum =
  Text.length checksum == 64
    && Text.all (\character -> (character >= '0' && character <= '9') || character `elem` ['a' .. 'f']) checksum
