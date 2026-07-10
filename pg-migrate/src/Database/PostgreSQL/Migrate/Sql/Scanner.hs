module Database.PostgreSQL.Migrate.Sql.Scanner
  ( SqlError (..),
    SqlScan,
    scanSql,
    sqlScanTransactionMode,
    sqlScanStatementCount,
  )
where

import Data.Char qualified as Char
import Data.List qualified as List
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate.Types (TransactionMode (..))
import PgMigrate.Prelude

data SqlError
  = InvalidUtf8
      { byteOffset :: !Int
      }
  | UnknownDirective
      { directive :: !Text
      }
  | DuplicateNoTransactionDirective
  | UnterminatedSqlConstruct
      { construct :: !Text
      }
  | ProhibitedTransactionCommand
      { command :: !Text
      }
  | PsqlMetaCommand
      { lineNumber :: !Int
      }
  | CopyFromStdin
  | EmptySql
  | NonTransactionalStatementCount
      { actualStatements :: !Int
      }
  deriving stock (Generic, Eq, Show)

data SqlScan = SqlScan
  { transactionMode :: !TransactionMode,
    statementCount :: !Int
  }
  deriving stock (Generic, Eq, Show)

data Statement = Statement
  { tokens :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

data StatementAccumulator = StatementAccumulator
  { reverseTokens :: ![Text],
    reverseWord :: !String,
    hasContent :: !Bool
  }

emptyAccumulator :: StatementAccumulator
emptyAccumulator = StatementAccumulator [] [] False

sqlScanTransactionMode :: SqlScan -> TransactionMode
sqlScanTransactionMode SqlScan {transactionMode} = transactionMode

sqlScanStatementCount :: SqlScan -> Int
sqlScanStatementCount SqlScan {statementCount} = statementCount

scanSql :: Text -> Either SqlError SqlScan
scanSql sql = do
  (noTransaction, body) <- scanLeadingRegion False (Text.unpack sql)
  statements <- scanStatements body
  traverse_ validateStatement statements
  let statementCount = length statements
  case (noTransaction, statementCount) of
    (_, 0) -> Left EmptySql
    (True, 1) -> Right (SqlScan NonTransactional statementCount)
    (True, count) -> Left (NonTransactionalStatementCount count)
    (False, count) -> Right (SqlScan Transactional count)

scanLeadingRegion :: Bool -> String -> Either SqlError (Bool, String)
scanLeadingRegion noTransaction input =
  case dropWhile Char.isSpace input of
    '-' : '-' : rest -> do
      let (comment, remaining) = break (== '\n') rest
      noTransaction' <- inspectLeadingComment noTransaction comment
      scanLeadingRegion noTransaction' remaining
    '/' : '*' : rest -> do
      remaining <- consumeLeadingBlockComment 1 rest
      scanLeadingRegion noTransaction remaining
    remaining -> Right (noTransaction, remaining)

inspectLeadingComment :: Bool -> String -> Either SqlError Bool
inspectLeadingComment alreadySeen comment =
  let commentText = Text.strip (Text.pack comment)
   in if commentText == "pg-migrate: no-transaction"
        then
          if alreadySeen
            then Left DuplicateNoTransactionDirective
            else Right True
        else
          if "pg-migrate:" `Text.isPrefixOf` commentText
            then Left (UnknownDirective commentText)
            else Right alreadySeen

consumeLeadingBlockComment :: Int -> String -> Either SqlError String
consumeLeadingBlockComment depth input =
  case input of
    [] -> Left (UnterminatedSqlConstruct "block comment")
    '/' : '*' : rest -> consumeLeadingBlockComment (depth + 1) rest
    '*' : '/' : rest
      | depth == 1 -> Right rest
      | otherwise -> consumeLeadingBlockComment (depth - 1) rest
    _ : rest -> consumeLeadingBlockComment depth rest

scanStatements :: String -> Either SqlError [Statement]
scanStatements = go 1 True emptyAccumulator []
  where
    go line lineOnlyWhitespace accumulator statements input =
      case input of
        [] -> Right (reverse (finishStatement accumulator statements))
        '\n' : rest ->
          go (line + 1) True (flushWord accumulator) statements rest
        character : rest
          | Char.isSpace character ->
              go line lineOnlyWhitespace (flushWord accumulator) statements rest
        '-' : '-' : rest ->
          go line lineOnlyWhitespace (flushWord accumulator) statements (dropLineComment rest)
        '/' : '*' : rest -> do
          (nextLine, nextLineOnlyWhitespace, remaining) <-
            consumeBlockComment 1 line lineOnlyWhitespace rest
          go nextLine nextLineOnlyWhitespace (flushWord accumulator) statements remaining
        '\\' : _
          | lineOnlyWhitespace -> Left (PsqlMetaCommand line)
        '\'' : rest -> do
          let (word, flushedAccumulator) = takeWord accumulator
              isEscapeString = fmap Char.toUpper word == "E"
          (nextLine, remaining) <- consumeSingleQuoted isEscapeString line rest
          go nextLine False (markContent flushedAccumulator) statements remaining
        '"' : rest -> do
          (nextLine, remaining) <- consumeDoubleQuoted line rest
          go nextLine False (markContent (flushWord accumulator)) statements remaining
        '$' : rest
          | null (reverseWord accumulator),
            Just (delimiter, afterOpening) <- dollarDelimiter rest -> do
              (nextLine, remaining) <- consumeDollarQuoted delimiter line afterOpening
              go nextLine False (markContent accumulator) statements remaining
        ';' : rest ->
          let flushedAccumulator = flushWord accumulator
           in go
                line
                False
                emptyAccumulator
                (finishStatement flushedAccumulator statements)
                rest
        character : rest
          | isWordCharacter character ->
              go
                line
                False
                accumulator
                  { reverseWord = character : reverseWord accumulator,
                    hasContent = True
                  }
                statements
                rest
        _ : rest ->
          go line False (markContent (flushWord accumulator)) statements rest

dropLineComment :: String -> String
dropLineComment = dropWhile (/= '\n')

consumeBlockComment :: Int -> Int -> Bool -> String -> Either SqlError (Int, Bool, String)
consumeBlockComment depth line lineOnlyWhitespace input =
  case input of
    [] -> Left (UnterminatedSqlConstruct "block comment")
    '/' : '*' : rest -> consumeBlockComment (depth + 1) line lineOnlyWhitespace rest
    '*' : '/' : rest
      | depth == 1 -> Right (line, lineOnlyWhitespace, rest)
      | otherwise -> consumeBlockComment (depth - 1) line lineOnlyWhitespace rest
    '\n' : rest -> consumeBlockComment depth (line + 1) True rest
    _ : rest -> consumeBlockComment depth line lineOnlyWhitespace rest

consumeSingleQuoted :: Bool -> Int -> String -> Either SqlError (Int, String)
consumeSingleQuoted isEscapeString line input =
  case input of
    [] -> Left (UnterminatedSqlConstruct "single-quoted string")
    '\'' : '\'' : rest -> consumeSingleQuoted isEscapeString line rest
    '\'' : rest -> Right (line, rest)
    '\\' : '\n' : rest
      | isEscapeString -> consumeSingleQuoted isEscapeString (line + 1) rest
    '\\' : _ : rest
      | isEscapeString -> consumeSingleQuoted isEscapeString line rest
    '\n' : rest -> consumeSingleQuoted isEscapeString (line + 1) rest
    _ : rest -> consumeSingleQuoted isEscapeString line rest

consumeDoubleQuoted :: Int -> String -> Either SqlError (Int, String)
consumeDoubleQuoted line input =
  case input of
    [] -> Left (UnterminatedSqlConstruct "double-quoted identifier")
    '"' : '"' : rest -> consumeDoubleQuoted line rest
    '"' : rest -> Right (line, rest)
    '\n' : rest -> consumeDoubleQuoted (line + 1) rest
    _ : rest -> consumeDoubleQuoted line rest

dollarDelimiter :: String -> Maybe (String, String)
dollarDelimiter rest =
  case rest of
    '$' : after -> Just ("$$", after)
    firstCharacter : _
      | Char.isAlpha firstCharacter || firstCharacter == '_' ->
          let (tag, suffix) = span isDollarTagCharacter rest
           in case suffix of
                '$' : after -> Just ('$' : tag <> "$", after)
                _ -> Nothing
    _ -> Nothing

isDollarTagCharacter :: Char -> Bool
isDollarTagCharacter character =
  Char.isAlphaNum character || character == '_'

consumeDollarQuoted :: String -> Int -> String -> Either SqlError (Int, String)
consumeDollarQuoted delimiter line input
  | delimiter `List.isPrefixOf` input = Right (line, drop (length delimiter) input)
  | otherwise =
      case input of
        [] -> Left (UnterminatedSqlConstruct "dollar-quoted string")
        '\n' : rest -> consumeDollarQuoted delimiter (line + 1) rest
        _ : rest -> consumeDollarQuoted delimiter line rest

isWordCharacter :: Char -> Bool
isWordCharacter character =
  Char.isAlphaNum character || character == '_' || character == '$'

markContent :: StatementAccumulator -> StatementAccumulator
markContent accumulator = accumulator {hasContent = True}

takeWord :: StatementAccumulator -> (String, StatementAccumulator)
takeWord accumulator =
  ( reverse (reverseWord accumulator),
    flushWord accumulator
  )

flushWord :: StatementAccumulator -> StatementAccumulator
flushWord accumulator@StatementAccumulator {reverseWord = []} = accumulator
flushWord accumulator@StatementAccumulator {reverseTokens, reverseWord} =
  accumulator
    { reverseTokens = Text.toUpper (Text.pack (reverse reverseWord)) : reverseTokens,
      reverseWord = []
    }

finishStatement :: StatementAccumulator -> [Statement] -> [Statement]
finishStatement accumulator statements
  | hasContent accumulator =
      let StatementAccumulator {reverseTokens} = flushWord accumulator
       in Statement {tokens = reverse reverseTokens} : statements
  | otherwise = statements

validateStatement :: Statement -> Either SqlError ()
validateStatement Statement {tokens} =
  case prohibitedCommand tokens of
    Just command -> Left (ProhibitedTransactionCommand command)
    Nothing
      | isCopyFromStdin tokens -> Left CopyFromStdin
      | otherwise -> Right ()

prohibitedCommand :: [Text] -> Maybe Text
prohibitedCommand tokens =
  case tokens of
    "BEGIN" : _ -> Just "BEGIN"
    "START" : "TRANSACTION" : _ -> Just "START TRANSACTION"
    "COMMIT" : "PREPARED" : _ -> Just "COMMIT PREPARED"
    "COMMIT" : _ -> Just "COMMIT"
    "END" : _ -> Just "END"
    "ROLLBACK" : "PREPARED" : _ -> Just "ROLLBACK PREPARED"
    "ROLLBACK" : _ -> Just "ROLLBACK"
    "ABORT" : _ -> Just "ABORT"
    "SAVEPOINT" : _ -> Just "SAVEPOINT"
    "RELEASE" : _ -> Just "RELEASE SAVEPOINT"
    "PREPARE" : "TRANSACTION" : _ -> Just "PREPARE TRANSACTION"
    _ -> Nothing

isCopyFromStdin :: [Text] -> Bool
isCopyFromStdin tokens =
  case tokens of
    "COPY" : rest -> containsAdjacent "FROM" "STDIN" rest
    _ -> False

containsAdjacent :: (Eq a) => a -> a -> [a] -> Bool
containsAdjacent firstValue secondValue values =
  case values of
    current : next : rest ->
      (current == firstValue && next == secondValue)
        || containsAdjacent firstValue secondValue (next : rest)
    _ -> False
