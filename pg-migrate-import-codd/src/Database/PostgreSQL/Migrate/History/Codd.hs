-- | Hasql-only reader and importer for exact Codd V1–V5 ledger shapes. Source objects are
-- read under the configured cooperating legacy lock and are never modified.
module Database.PostgreSQL.Migrate.History.Codd
  ( CoddSourceConfig,
    CoddManifest,
    CoddSchemaVersion (..),
    CoddHistoryRow (..),
    CoddHistory (..),
    CoddDefinitionError (..),
    CoddImportError (..),
    CoddImportCommand (..),
    defaultCoddLockKey,
    coddSourceConfig,
    withCoddLockKey,
    coddEvidenceKey,
    parseCoddManifest,
    readCoddHistory,
    importCoddHistory,
    importCoddHistoryWithValidators,
    coddImportCommandParser,
  )
where

import Database.PostgreSQL.Migrate.History.Codd.Import (importCoddHistory, importCoddHistoryWithValidators)
import Database.PostgreSQL.Migrate.History.Codd.Ledger (readCoddHistory)
import Database.PostgreSQL.Migrate.History.Codd.Manifest (parseCoddManifest)
import Database.PostgreSQL.Migrate.History.Codd.Parser (coddImportCommandParser)
import Database.PostgreSQL.Migrate.History.Codd.Types
