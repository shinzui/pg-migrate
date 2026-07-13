module Database.PostgreSQL.Migrate.Sql
  ( SqlError (..),
    SqlScan,
    validateSql,
    sqlScanTransactionMode,
    sqlScanStatementCount,
  )
where

import Data.ByteString qualified as ByteString
import Data.Text.Encoding qualified as Text.Encoding
import Data.Word (Word8)
import Database.PostgreSQL.Migrate.Sql.Scanner
  ( SqlError (..),
    SqlScan,
    scanSql,
    sqlScanStatementCount,
    sqlScanTransactionMode,
  )
import PgMigrate.Prelude

validateSql :: ByteString -> Either SqlError SqlScan
validateSql bytes
  | utf8ByteOrderMark `ByteString.isPrefixOf` bytes = Left ByteOrderMarkFound
  | otherwise = do
      validateUtf8 bytes
      scanSql (Text.Encoding.decodeUtf8 bytes)

utf8ByteOrderMark :: ByteString
utf8ByteOrderMark = ByteString.pack [0xEF, 0xBB, 0xBF]

validateUtf8 :: ByteString -> Either SqlError ()
validateUtf8 = go 0 . ByteString.unpack
  where
    go :: Int -> [Word8] -> Either SqlError ()
    go _ [] = Right ()
    go offset (byte : rest)
      | byte <= 0x7F = go (offset + 1) rest
      | byte >= 0xC2 && byte <= 0xDF =
          consumeContinuation offset 1 rest
      | byte == 0xE0 =
          consumeRestricted offset 0xA0 0xBF 1 rest
      | byte >= 0xE1 && byte <= 0xEC =
          consumeContinuation offset 2 rest
      | byte == 0xED =
          consumeRestricted offset 0x80 0x9F 1 rest
      | byte >= 0xEE && byte <= 0xEF =
          consumeContinuation offset 2 rest
      | byte == 0xF0 =
          consumeRestricted offset 0x90 0xBF 2 rest
      | byte >= 0xF1 && byte <= 0xF3 =
          consumeContinuation offset 3 rest
      | byte == 0xF4 =
          consumeRestricted offset 0x80 0x8F 2 rest
      | otherwise = Left (InvalidUtf8 offset)

    consumeRestricted :: Int -> Word8 -> Word8 -> Int -> [Word8] -> Either SqlError ()
    consumeRestricted offset lower upper remainingCount input =
      case input of
        next : rest
          | next >= lower && next <= upper ->
              consumeContinuationFrom
                (offset + 2)
                remainingCount
                rest
          | otherwise -> Left (InvalidUtf8 (offset + 1))
        [] -> Left (InvalidUtf8 (offset + 1))

    consumeContinuation :: Int -> Int -> [Word8] -> Either SqlError ()
    consumeContinuation offset count input =
      consumeContinuationFrom (offset + 1) count input

    consumeContinuationFrom :: Int -> Int -> [Word8] -> Either SqlError ()
    consumeContinuationFrom nextOffset count input
      | count == 0 = go nextOffset input
      | otherwise =
          case input of
            next : rest
              | next >= 0x80 && next <= 0xBF ->
                  consumeContinuationFrom (nextOffset + 1) (count - 1) rest
              | otherwise -> Left (InvalidUtf8 nextOffset)
            [] -> Left (InvalidUtf8 nextOffset)
