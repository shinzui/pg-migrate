module Database.PostgreSQL.Migrate.History
  ( EvidenceKey,
    evidenceKey,
    EvidenceStrength (..),
    SourceTimestamp (..),
    ImportEvidence,
    ledgerOnlyEvidence,
    sourceManifestVerifiedEvidence,
    sourceLedgerChecksumVerifiedEvidence,
    EvidenceRequirement (..),
    PayloadRelation (..),
    HistoryMapping,
    historyMapping,
    historyMappingPayloadRelation,
    StateValidationError,
    stateValidationError,
    StateValidator,
    stateValidator,
    HistoryImport,
    historyImport,
    HistoryDefinitionError (..),
    EquivalentHistoryPolicy (..),
    ImportOptions,
    defaultImportOptions,
    withEquivalentHistory,
    withImportRunOptions,
    importEquivalentHistoryPolicy,
    HistoryImportOutcome (..),
    HistoryImportResult (..),
    HistoryImportReport (..),
    HistoryValidationError (..),
    HistoryImportError (..),
    importMigrationHistory,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.Version (showVersion)
import Database.PostgreSQL.Migrate.History.Types
import Database.PostgreSQL.Migrate.History.Validation
import Database.PostgreSQL.Migrate.Ledger
import Database.PostgreSQL.Migrate.Ledger.Migrations
import Database.PostgreSQL.Migrate.Ledger.Sql
import Database.PostgreSQL.Migrate.Ledger.Types
import Database.PostgreSQL.Migrate.Plan (planDescription)
import Database.PostgreSQL.Migrate.Runner (withRunLifecycle)
import Database.PostgreSQL.Migrate.Runner.Types
import Database.PostgreSQL.Migrate.Types
import Hasql.Connection qualified as Connection
import Hasql.Session qualified as Session
import Hasql.Transaction qualified as Transaction
import Hasql.Transaction.Sessions qualified as Transaction.Sessions
import Paths_pg_migrate qualified as Package
import PgMigrate.Prelude

data ClassifiedImport
  = ImportPending !ResolvedHistoryMapping
  | ImportExisting !ResolvedHistoryMapping

importMigrationHistory ::
  ImportOptions ->
  ConnectionProvider ->
  MigrationPlan ->
  HistoryImport ->
  IO (Either HistoryImportError HistoryImportReport)
importMigrationHistory options provider plan history = do
  result <-
    withRunLifecycle (importRunOptions options) provider $ \connection ->
      Right <$> importLocked options connection plan history
  pure $ case result of
    Left migrationError -> Left (HistoryImportRunnerError migrationError)
    Right imported -> imported

importLocked ::
  ImportOptions ->
  Connection.Connection ->
  MigrationPlan ->
  HistoryImport ->
  IO (Either HistoryImportError HistoryImportReport)
importLocked options connection plan history = do
  initialized <-
    runSession
      connection
      (initializeOrUpgradeLedger activeLedgerConfig historyRunnerVersion)
  case initialized of
    Left migrationError -> pure (Left (HistoryImportRunnerError migrationError))
    Right (Left ledgerError) -> pure (Left (HistoryImportRunnerError (LedgerInitializationFailed ledgerError)))
    Right (Right ()) -> do
      snapshotResult <- runSession connection (loadLedger activeLedgerConfig)
      auditResult <- runSession connection (Session.statement () (loadHistoryImportsStatement activeLedgerConfig))
      case (snapshotResult, auditResult) of
        (Left migrationError, _) -> pure (Left (HistoryImportRunnerError migrationError))
        (_, Left migrationError) -> pure (Left (HistoryImportRunnerError migrationError))
        (Right snapshot, Right storedAudits) ->
          importAgainstSnapshot options connection plan history snapshot storedAudits
  where
    activeLedgerConfig = runLedgerConfig (importRunOptions options)

importAgainstSnapshot ::
  ImportOptions ->
  Connection.Connection ->
  MigrationPlan ->
  HistoryImport ->
  LedgerSnapshot ->
  [StoredHistoryImport] ->
  IO (Either HistoryImportError HistoryImportReport)
importAgainstSnapshot options connection plan history snapshot storedAudits =
  case comparePlanWithLedger RejectUnknownMigrations (planDescription plan) (storedMigrations snapshot) of
    verification@VerificationReport {issues = _ : _} ->
      pure (Left (HistoryImportRunnerError (PlanVerificationFailed verification)))
    VerificationReport {} -> do
      validatedEvidence <- runValidators connection history
      case validatedEvidence of
        Left importError -> pure (Left importError)
        Right availableEvidence ->
          case resolveHistoryImport (equivalentHistoryPolicy options) plan availableEvidence history of
            Left validationError -> pure (Left (HistoryImportValidationFailed validationError))
            Right resolved -> do
              let classified =
                    traverse
                      (classifyImport history snapshot storedAudits)
                      resolved
              case classified of
                Left importError -> pure (Left importError)
                Right imports -> persistImports options connection history imports

runValidators ::
  Connection.Connection ->
  HistoryImport ->
  IO (Either HistoryImportError (Map EvidenceKey ImportEvidence))
runValidators connection history = go (evidence history) (validators history)
  where
    go available [] = pure (Right available)
    go available (validator : rest) = do
      result <-
        Connection.use
          connection
          ( Transaction.Sessions.transactionNoRetry
              Transaction.Sessions.ReadCommitted
              Transaction.Sessions.Read
              (runStateValidator validator)
          )
      case result of
        Left sessionError -> pure (Left (HistoryImportRunnerError (DatabaseSessionFailed sessionError)))
        Right (Left validationError) ->
          pure (Left (HistoryStateValidationFailed (validatorEvidenceKey validator) validationError))
        Right (Right details) ->
          go
            (Map.insert (validatorEvidenceKey validator) (stateVerifiedEvidence (validatorEvidenceKey validator) details) available)
            rest

classifyImport ::
  HistoryImport ->
  LedgerSnapshot ->
  [StoredHistoryImport] ->
  ResolvedHistoryMapping ->
  Either HistoryImportError ClassifiedImport
classifyImport history snapshot storedAudits resolved =
  case (Map.lookup identifier migrationsById, Map.lookup identifier auditsById) of
    (Nothing, Nothing) -> Right (ImportPending resolved)
    (Just storedMigration, Just storedAudit)
      | migrationMatches resolved storedMigration && auditMatches history resolved storedAudit ->
          Right (ImportExisting resolved)
    _ -> Left (HistoryImportConflict identifier)
  where
    identifier = resolvedTarget resolved
    migrationsById = Map.fromList [(storedMigrationId row, row) | row <- storedMigrations snapshot]
    auditsById = Map.fromList [(storedHistoryMigrationId row, row) | row <- storedAudits]

migrationMatches :: ResolvedHistoryMapping -> StoredMigration -> Bool
migrationMatches
  resolved
  StoredMigration
    { position = storedPosition,
      checksum = storedChecksum,
      kind = storedKind,
      transactionMode = storedTransactionMode,
      status = storedStatus
    } =
    storedPosition == fromIntegral (resolvedPosition resolved)
      && storedChecksum == resolvedChecksum resolved
      && storedKind == resolvedKind resolved
      && storedTransactionMode == resolvedTransactionMode resolved
      && storedStatus == Applied

auditMatches :: HistoryImport -> ResolvedHistoryMapping -> StoredHistoryImport -> Bool
auditMatches history resolved stored =
  storedHistorySource stored == source history
    && storedHistoryEvidence stored == resolvedAuditEvidence resolved
    && storedHistoryReason stored == reason history

persistImports ::
  ImportOptions ->
  Connection.Connection ->
  HistoryImport ->
  NonEmpty ClassifiedImport ->
  IO (Either HistoryImportError HistoryImportReport)
persistImports options connection history imports = do
  importedAt <- getCurrentTime
  let pending = [resolved | ImportPending resolved <- toList imports]
      ledgerRows = historyLedgerRow importedAt history <$> pending
      activeLedgerConfig = runLedgerConfig (importRunOptions options)
  written <-
    Connection.use
      connection
      ( Transaction.Sessions.transactionNoRetry
          Transaction.Sessions.ReadCommitted
          Transaction.Sessions.Write
          ( for_ ledgerRows $ \row -> do
              Transaction.statement row (insertImportedMigrationStatement activeLedgerConfig)
              Transaction.statement row (insertHistoryImportAuditStatement activeLedgerConfig)
          )
      )
  pure $ case written of
    Left sessionError -> Left (HistoryImportRunnerError (DatabaseSessionFailed sessionError))
    Right () ->
      Right
        ( HistoryImportReport
            (toResult <$> imports)
        )
  where
    toResult = \case
      ImportPending resolved -> HistoryImportResult (resolvedTarget resolved) Imported
      ImportExisting resolved -> HistoryImportResult (resolvedTarget resolved) AlreadyImported

historyLedgerRow ::
  UTCTime ->
  HistoryImport ->
  ResolvedHistoryMapping ->
  HistoryLedgerRow
historyLedgerRow historyLedgerImportedAt history resolved =
  HistoryLedgerRow
    { historyLedgerMigrationId = resolvedTarget resolved,
      historyLedgerPosition = resolvedPosition resolved,
      historyLedgerChecksum = resolvedChecksum resolved,
      historyLedgerKind = resolvedKind resolved,
      historyLedgerTransactionMode = resolvedTransactionMode resolved,
      historyLedgerImportedAt,
      historyLedgerSource = source history,
      historyLedgerEvidence = LazyByteString.toStrict (Aeson.encode (resolvedAuditEvidence resolved)),
      historyLedgerReason = reason history,
      historyLedgerRunnerVersion = historyRunnerVersion
    }

runSession ::
  Connection.Connection ->
  Session.Session value ->
  IO (Either MigrationError value)
runSession connection session = first DatabaseSessionFailed <$> Connection.use connection session

historyRunnerVersion :: Text
historyRunnerVersion = Text.pack (showVersion Package.version)
