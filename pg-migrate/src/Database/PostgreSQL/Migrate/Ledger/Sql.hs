module Database.PostgreSQL.Migrate.Ledger.Sql
  ( quotePostgresIdentifier,
    qualifiedLedgerTable,
    ledgerMetadataExistsStatement,
    loadLedgerMetadataStatement,
    insertLedgerMetadataStatement,
    loadStoredMigrationsStatement,
    AppliedLedgerRow (..),
    FailedLedgerRow (..),
    insertAppliedMigrationStatement,
    insertRunningMigrationStatement,
    markRunningMigrationAppliedStatement,
    markRunningMigrationFailedStatement,
    RepairLedgerRow (..),
    insertRepairAuditStatement,
    prepareMarkAppliedStatement,
    prepareRetryStatement,
    HistoryLedgerRow (..),
    StoredHistoryImport (..),
    loadHistoryImportsStatement,
    insertImportedMigrationStatement,
    insertHistoryImportAuditStatement,
    ledgerVersionOneDdl,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Functor.Contravariant (contramap)
import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Data.Time (UTCTime)
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

data AppliedLedgerRow = AppliedLedgerRow
  { appliedMigrationId :: !MigrationId,
    appliedPosition :: !Int32,
    appliedChecksum :: !MigrationChecksum,
    appliedKind :: !MigrationKind,
    appliedTransactionMode :: !TransactionMode,
    appliedStartedAt :: !UTCTime,
    appliedRunnerVersion :: !Text
  }

data FailedLedgerRow = FailedLedgerRow
  { failedLedgerIdentity :: !AppliedLedgerRow,
    failedLedgerError :: !Text
  }

data RepairLedgerRow = RepairLedgerRow
  { repairLedgerMigrationId :: !MigrationId,
    repairLedgerOperation :: !Text,
    repairLedgerOldStatus :: !MigrationStatus,
    repairLedgerNewStatus :: !MigrationStatus,
    repairLedgerReason :: !Text,
    repairLedgerRunnerVersion :: !Text
  }

data HistoryLedgerRow = HistoryLedgerRow
  { historyLedgerMigrationId :: !MigrationId,
    historyLedgerPosition :: !Int32,
    historyLedgerChecksum :: !MigrationChecksum,
    historyLedgerKind :: !MigrationKind,
    historyLedgerTransactionMode :: !TransactionMode,
    historyLedgerImportedAt :: !UTCTime,
    historyLedgerSource :: !Text,
    historyLedgerEvidence :: !ByteString,
    historyLedgerReason :: !Text,
    historyLedgerRunnerVersion :: !Text
  }

data StoredHistoryImport = StoredHistoryImport
  { storedHistoryMigrationId :: !MigrationId,
    storedHistorySource :: !Text,
    storedHistoryEvidence :: !Value,
    storedHistoryReason :: !Text
  }
  deriving stock (Generic, Eq, Show)

insertAppliedMigrationStatement :: LedgerConfig -> Statement AppliedLedgerRow ()
insertAppliedMigrationStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "INSERT INTO",
          qualifiedLedgerTable config "migrations",
          "(component, migration, position, checksum, kind, transaction_mode, status,",
          "started_at, finished_at, execution_time_ms, error, runner_version)",
          "VALUES ($1, $2, $3, $4, $5, $6, 'applied', $7, clock_timestamp(),",
          "GREATEST(0, round(extract(epoch FROM (clock_timestamp() - $7)) * 1000))::bigint,",
          "NULL, $8)"
        ]
    )
    appliedLedgerRowEncoder
    Decoders.noResult

insertRunningMigrationStatement :: LedgerConfig -> Statement AppliedLedgerRow ()
insertRunningMigrationStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "INSERT INTO",
          qualifiedLedgerTable config "migrations",
          "(component, migration, position, checksum, kind, transaction_mode, status,",
          "started_at, finished_at, execution_time_ms, error, runner_version)",
          "VALUES ($1, $2, $3, $4, $5, $6, 'running', $7, NULL, NULL, NULL, $8)"
        ]
    )
    appliedLedgerRowEncoder
    Decoders.noResult

markRunningMigrationAppliedStatement :: LedgerConfig -> Statement AppliedLedgerRow Int64
markRunningMigrationAppliedStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "UPDATE",
          qualifiedLedgerTable config "migrations",
          "SET status = 'applied', finished_at = clock_timestamp(),",
          "execution_time_ms = GREATEST(0, round(extract(epoch FROM",
          "(clock_timestamp() - started_at)) * 1000))::bigint, error = NULL",
          "WHERE component = $1 AND migration = $2 AND position = $3 AND checksum = $4",
          "AND kind = $5 AND transaction_mode = $6 AND status = 'running'"
        ]
    )
    appliedLedgerIdentityEncoder
    Decoders.rowsAffected

markRunningMigrationFailedStatement :: LedgerConfig -> Statement FailedLedgerRow Int64
markRunningMigrationFailedStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "UPDATE",
          qualifiedLedgerTable config "migrations",
          "SET status = 'failed', finished_at = clock_timestamp(),",
          "execution_time_ms = GREATEST(0, round(extract(epoch FROM",
          "(clock_timestamp() - started_at)) * 1000))::bigint, error = $7",
          "WHERE component = $1 AND migration = $2 AND position = $3 AND checksum = $4",
          "AND kind = $5 AND transaction_mode = $6 AND status = 'running'"
        ]
    )
    failedLedgerRowEncoder
    Decoders.rowsAffected

insertRepairAuditStatement :: LedgerConfig -> Statement RepairLedgerRow ()
insertRepairAuditStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "INSERT INTO",
          qualifiedLedgerTable config "repairs",
          "(component, migration, operation, old_status, new_status, reason, runner_version)",
          "VALUES ($1, $2, $3, $4, $5, $6, $7)"
        ]
    )
    repairLedgerRowEncoder
    Decoders.noResult

prepareMarkAppliedStatement :: LedgerConfig -> Statement RepairLedgerRow Int64
prepareMarkAppliedStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "UPDATE",
          qualifiedLedgerTable config "migrations",
          "SET status = 'applied', finished_at = clock_timestamp(),",
          "execution_time_ms = COALESCE(execution_time_ms,",
          "GREATEST(0, round(extract(epoch FROM (clock_timestamp() - started_at)) * 1000))::bigint),",
          "error = NULL WHERE component = $1 AND migration = $2 AND status = $3"
        ]
    )
    repairTransitionEncoder
    Decoders.rowsAffected

prepareRetryStatement :: LedgerConfig -> Statement RepairLedgerRow Int64
prepareRetryStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "UPDATE",
          qualifiedLedgerTable config "migrations",
          "SET status = 'running', started_at = clock_timestamp(), finished_at = NULL,",
          "execution_time_ms = NULL, error = NULL, runner_version = $4",
          "WHERE component = $1 AND migration = $2 AND status = $3"
        ]
    )
    repairRetryEncoder
    Decoders.rowsAffected

loadHistoryImportsStatement :: LedgerConfig -> Statement () [StoredHistoryImport]
loadHistoryImportsStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "SELECT component, migration, source, source_evidence, reason FROM",
          qualifiedLedgerTable config "history_imports",
          "ORDER BY component, migration"
        ]
    )
    Encoders.noParams
    (Decoders.rowList storedHistoryImportRow)

insertImportedMigrationStatement :: LedgerConfig -> Statement HistoryLedgerRow ()
insertImportedMigrationStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "INSERT INTO",
          qualifiedLedgerTable config "migrations",
          "(component, migration, position, checksum, kind, transaction_mode, status,",
          "started_at, finished_at, execution_time_ms, error, runner_version)",
          "VALUES ($1, $2, $3, $4, $5, $6, 'applied', $7, $7, 0, NULL, $8)"
        ]
    )
    historyMigrationEncoder
    Decoders.noResult

insertHistoryImportAuditStatement :: LedgerConfig -> Statement HistoryLedgerRow ()
insertHistoryImportAuditStatement config =
  Statement.unpreparable
    ( Text.unwords
        [ "INSERT INTO",
          qualifiedLedgerTable config "history_imports",
          "(component, migration, source, source_evidence, reason, imported_at, runner_version)",
          "VALUES ($1, $2, $3, $4, $5, $6, $7)"
        ]
    )
    historyAuditEncoder
    Decoders.noResult

storedHistoryImportRow :: Decoders.Row StoredHistoryImport
storedHistoryImportRow =
  StoredHistoryImport
    <$> ( MigrationId
            <$> (ComponentName <$> required Decoders.text)
            <*> (MigrationName <$> required Decoders.text)
        )
    <*> required Decoders.text
    <*> required (Decoders.jsonbBytes (first Text.pack . Aeson.eitherDecodeStrict'))
    <*> required Decoders.text
  where
    required = Decoders.column . Decoders.nonNullable

appliedLedgerRowEncoder :: Encoders.Params AppliedLedgerRow
appliedLedgerRowEncoder =
  mconcat
    [ contramap appliedComponentText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap appliedMigrationText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap appliedPosition (Encoders.param (Encoders.nonNullable Encoders.int4)),
      contramap appliedChecksumBytes (Encoders.param (Encoders.nonNullable Encoders.bytea)),
      contramap (encodeMigrationKind . appliedKind) (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap (encodeTransactionMode . appliedTransactionMode) (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap appliedStartedAt (Encoders.param (Encoders.nonNullable Encoders.timestamptz)),
      contramap appliedRunnerVersion (Encoders.param (Encoders.nonNullable Encoders.text))
    ]

appliedLedgerIdentityEncoder :: Encoders.Params AppliedLedgerRow
appliedLedgerIdentityEncoder =
  mconcat
    [ contramap appliedComponentText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap appliedMigrationText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap appliedPosition (Encoders.param (Encoders.nonNullable Encoders.int4)),
      contramap appliedChecksumBytes (Encoders.param (Encoders.nonNullable Encoders.bytea)),
      contramap (encodeMigrationKind . appliedKind) (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap (encodeTransactionMode . appliedTransactionMode) (Encoders.param (Encoders.nonNullable Encoders.text))
    ]

failedLedgerRowEncoder :: Encoders.Params FailedLedgerRow
failedLedgerRowEncoder =
  contramap failedLedgerIdentity appliedLedgerIdentityEncoder
    <> contramap failedLedgerError (Encoders.param (Encoders.nonNullable Encoders.text))

repairLedgerRowEncoder :: Encoders.Params RepairLedgerRow
repairLedgerRowEncoder =
  mconcat
    [ contramap repairComponentText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap repairMigrationText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap repairLedgerOperation (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap (encodeMigrationStatus . repairLedgerOldStatus) (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap (encodeMigrationStatus . repairLedgerNewStatus) (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap repairLedgerReason (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap repairLedgerRunnerVersion (Encoders.param (Encoders.nonNullable Encoders.text))
    ]

repairTransitionEncoder :: Encoders.Params RepairLedgerRow
repairTransitionEncoder =
  mconcat
    [ contramap repairComponentText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap repairMigrationText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap (encodeMigrationStatus . repairLedgerOldStatus) (Encoders.param (Encoders.nonNullable Encoders.text))
    ]

repairRetryEncoder :: Encoders.Params RepairLedgerRow
repairRetryEncoder =
  repairTransitionEncoder
    <> contramap repairLedgerRunnerVersion (Encoders.param (Encoders.nonNullable Encoders.text))

historyMigrationEncoder :: Encoders.Params HistoryLedgerRow
historyMigrationEncoder =
  mconcat
    [ contramap historyComponentText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap historyMigrationText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap historyLedgerPosition (Encoders.param (Encoders.nonNullable Encoders.int4)),
      contramap historyChecksumBytes (Encoders.param (Encoders.nonNullable Encoders.bytea)),
      contramap (encodeMigrationKind . historyLedgerKind) (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap (encodeTransactionMode . historyLedgerTransactionMode) (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap historyLedgerImportedAt (Encoders.param (Encoders.nonNullable Encoders.timestamptz)),
      contramap historyLedgerRunnerVersion (Encoders.param (Encoders.nonNullable Encoders.text))
    ]

historyAuditEncoder :: Encoders.Params HistoryLedgerRow
historyAuditEncoder =
  mconcat
    [ contramap historyComponentText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap historyMigrationText (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap historyLedgerSource (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap historyLedgerEvidence (Encoders.param (Encoders.nonNullable Encoders.jsonbBytes)),
      contramap historyLedgerReason (Encoders.param (Encoders.nonNullable Encoders.text)),
      contramap historyLedgerImportedAt (Encoders.param (Encoders.nonNullable Encoders.timestamptz)),
      contramap historyLedgerRunnerVersion (Encoders.param (Encoders.nonNullable Encoders.text))
    ]

historyComponentText :: HistoryLedgerRow -> Text
historyComponentText = componentNameText . migrationIdComponent . historyLedgerMigrationId

historyMigrationText :: HistoryLedgerRow -> Text
historyMigrationText = migrationNameText . migrationIdName . historyLedgerMigrationId

historyChecksumBytes :: HistoryLedgerRow -> ByteString
historyChecksumBytes HistoryLedgerRow {historyLedgerChecksum = MigrationChecksum bytes} = bytes

repairComponentText :: RepairLedgerRow -> Text
repairComponentText = componentNameText . migrationIdComponent . repairLedgerMigrationId

repairMigrationText :: RepairLedgerRow -> Text
repairMigrationText = migrationNameText . migrationIdName . repairLedgerMigrationId

appliedComponentText :: AppliedLedgerRow -> Text
appliedComponentText = componentNameText . migrationIdComponent . appliedMigrationId

appliedMigrationText :: AppliedLedgerRow -> Text
appliedMigrationText = migrationNameText . migrationIdName . appliedMigrationId

appliedChecksumBytes :: AppliedLedgerRow -> ByteString
appliedChecksumBytes AppliedLedgerRow {appliedChecksum = MigrationChecksum bytes} = bytes

encodeMigrationKind :: MigrationKind -> Text
encodeMigrationKind = \case
  SqlKind -> "sql"
  HaskellKind -> "haskell"

encodeTransactionMode :: TransactionMode -> Text
encodeTransactionMode = \case
  Transactional -> "transactional"
  NonTransactional -> "nontransactional"

encodeMigrationStatus :: MigrationStatus -> Text
encodeMigrationStatus = \case
  Running -> "running"
  Applied -> "applied"
  Failed -> "failed"

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
