module Database.PostgreSQL.Migrate.Ledger.Sql
  ( quotePostgresIdentifier,
    qualifiedLedgerTable,
    ledgerMetadataExistsStatement,
    loadLedgerMetadataStatement,
    insertLedgerMetadataStatement,
    loadStoredMigrationsStatement,
    ledgerVersionOneDdl,
  )
where

import Data.Text qualified as Text
import Database.PostgreSQL.Migrate.Ledger.Types
import Database.PostgreSQL.Migrate.Types
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import PgMigrate.Prelude

quotePostgresIdentifier :: PostgresIdentifier -> Text
quotePostgresIdentifier identifier =
  "\"" <> Text.replace "\"" "\"\"" (postgresIdentifierText identifier) <> "\""

qualifiedLedgerTable :: LedgerConfig -> Text -> Text
qualifiedLedgerTable config table =
  quotePostgresIdentifier (schema config) <> ".\"" <> table <> "\""

ledgerMetadataExistsStatement :: Statement Text Bool
ledgerMetadataExistsStatement =
  Statement.preparable
    """
    SELECT EXISTS
    (
      SELECT 1
      FROM information_schema.tables
      WHERE table_schema = $1
        AND table_name = 'ledger_metadata'
    )
    """
    (Encoders.param (Encoders.nonNullable Encoders.text))
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

loadLedgerMetadataStatement :: LedgerConfig -> Statement () LedgerMetadata
loadLedgerMetadataStatement config =
  Statement.unpreparable
    ( "SELECT schema_version, runner_version FROM "
        <> qualifiedLedgerTable config "ledger_metadata"
        <> " WHERE singleton = true"
    )
    Encoders.noParams
    ( Decoders.singleRow
        ( LedgerMetadata
            <$> Decoders.column (Decoders.nonNullable Decoders.int4)
            <*> Decoders.column (Decoders.nonNullable Decoders.text)
        )
    )

insertLedgerMetadataStatement :: LedgerConfig -> Statement Text ()
insertLedgerMetadataStatement config =
  Statement.unpreparable
    ( "INSERT INTO "
        <> qualifiedLedgerTable config "ledger_metadata"
        <> " (singleton, schema_version, runner_version) VALUES (true, 1, $1)"
    )
    (Encoders.param (Encoders.nonNullable Encoders.text))
    Decoders.noResult

loadStoredMigrationsStatement :: LedgerConfig -> Statement () [StoredMigration]
loadStoredMigrationsStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "SELECT component, migration, position, checksum, kind, transaction_mode,",
          "status, started_at, finished_at, execution_time_ms, error, runner_version",
          "FROM",
          qualifiedLedgerTable config "migrations",
          "ORDER BY component, position"
        ]
    )
    Encoders.noParams
    (Decoders.rowList storedMigrationRow)

storedMigrationRow :: Decoders.Row StoredMigration
storedMigrationRow =
  StoredMigration
    <$> ( MigrationId
            <$> (ComponentName <$> required Decoders.text)
            <*> (MigrationName <$> required Decoders.text)
        )
    <*> (fromIntegral <$> required Decoders.int4)
    <*> (MigrationChecksum <$> required Decoders.bytea)
    <*> required (Decoders.refine decodeMigrationKind Decoders.text)
    <*> required (Decoders.refine decodeTransactionMode Decoders.text)
    <*> required (Decoders.refine decodeMigrationStatus Decoders.text)
    <*> required Decoders.timestamptz
    <*> optional Decoders.timestamptz
    <*> optional Decoders.int8
    <*> optional Decoders.text
    <*> required Decoders.text
  where
    required = Decoders.column . Decoders.nonNullable
    optional = Decoders.column . Decoders.nullable

decodeMigrationKind :: Text -> Either Text MigrationKind
decodeMigrationKind = \case
  "sql" -> Right SqlKind
  "haskell" -> Right HaskellKind
  value -> Left ("unsupported migration kind: " <> value)

decodeTransactionMode :: Text -> Either Text TransactionMode
decodeTransactionMode = \case
  "transactional" -> Right Transactional
  "nontransactional" -> Right NonTransactional
  value -> Left ("unsupported transaction mode: " <> value)

decodeMigrationStatus :: Text -> Either Text MigrationStatus
decodeMigrationStatus = \case
  "running" -> Right Running
  "applied" -> Right Applied
  "failed" -> Right Failed
  value -> Left ("unsupported migration status: " <> value)

ledgerVersionOneDdl :: LedgerConfig -> Text
ledgerVersionOneDdl config =
  Text.unlines
    [ "CREATE SCHEMA IF NOT EXISTS " <> quotePostgresIdentifier (schema config) <> ";",
      "CREATE TABLE " <> metadataTable,
      "(",
      "    singleton       boolean     PRIMARY KEY DEFAULT true CHECK (singleton),",
      "    schema_version  integer     NOT NULL CHECK (schema_version > 0),",
      "    updated_at      timestamptz NOT NULL DEFAULT clock_timestamp(),",
      "    runner_version  text        NOT NULL",
      ");",
      "CREATE TABLE " <> migrationsTable,
      "(",
      "    component          text        NOT NULL,",
      "    migration          text        NOT NULL,",
      "    position           integer     NOT NULL CHECK (position > 0),",
      "    checksum           bytea       NOT NULL CHECK (octet_length(checksum) = 32),",
      "    kind               text        NOT NULL CHECK (kind IN ('sql', 'haskell')),",
      "    transaction_mode   text        NOT NULL",
      "        CHECK (transaction_mode IN ('transactional', 'nontransactional')),",
      "    status             text        NOT NULL",
      "        CHECK (status IN ('running', 'applied', 'failed')),",
      "    started_at         timestamptz NOT NULL,",
      "    finished_at        timestamptz,",
      "    execution_time_ms  bigint      CHECK (execution_time_ms >= 0),",
      "    error               text,",
      "    runner_version      text        NOT NULL,",
      "    CHECK (transaction_mode = 'nontransactional' OR status = 'applied'),",
      "    CHECK",
      "    (",
      "        (status = 'running' AND finished_at IS NULL AND error IS NULL)",
      "        OR",
      "        (status = 'applied' AND finished_at IS NOT NULL AND error IS NULL)",
      "        OR",
      "        (status = 'failed' AND finished_at IS NOT NULL AND error IS NOT NULL)",
      "    ),",
      "    PRIMARY KEY (component, migration),",
      "    UNIQUE (component, position)",
      ");",
      "CREATE TABLE " <> historyImportsTable,
      "(",
      "    component       text        NOT NULL,",
      "    migration       text        NOT NULL,",
      "    source          text        NOT NULL,",
      "    source_evidence jsonb       NOT NULL,",
      "    reason          text        NOT NULL,",
      "    imported_at     timestamptz NOT NULL DEFAULT clock_timestamp(),",
      "    imported_by     text        NOT NULL DEFAULT current_user,",
      "    runner_version  text        NOT NULL,",
      "    PRIMARY KEY (component, migration),",
      "    FOREIGN KEY (component, migration)",
      "        REFERENCES " <> migrationsTable <> " (component, migration)",
      ");",
      "CREATE TABLE " <> repairsTable,
      "(",
      "    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,",
      "    component       text        NOT NULL,",
      "    migration       text        NOT NULL,",
      "    operation       text        NOT NULL",
      "        CHECK (operation IN ('mark-applied', 'retry')),",
      "    old_status      text        NOT NULL,",
      "    new_status      text        NOT NULL,",
      "    reason          text        NOT NULL,",
      "    repaired_at     timestamptz NOT NULL DEFAULT clock_timestamp(),",
      "    repaired_by     text        NOT NULL DEFAULT current_user,",
      "    runner_version  text        NOT NULL,",
      "    FOREIGN KEY (component, migration)",
      "        REFERENCES " <> migrationsTable <> " (component, migration)",
      ");"
    ]
  where
    metadataTable = qualifiedLedgerTable config "ledger_metadata"
    migrationsTable = qualifiedLedgerTable config "migrations"
    historyImportsTable = qualifiedLedgerTable config "history_imports"
    repairsTable = qualifiedLedgerTable config "repairs"
