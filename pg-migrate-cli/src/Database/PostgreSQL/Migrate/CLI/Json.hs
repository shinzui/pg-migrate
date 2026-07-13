module Database.PostgreSQL.Migrate.CLI.Json
  ( jsonSchemaVersion,
    renderMigrationCommandJson,
    renderHistoryImportJson,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Types (Pair)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI.Outcome
import Database.PostgreSQL.Migrate.CLI.Types (checksumText)
import Database.PostgreSQL.Migrate.Internal
import PgMigrate.CLI.Prelude

-- | Supported machine-readable CLI schema version.
jsonSchemaVersion :: Int
jsonSchemaVersion = 1

-- | Render a command outcome using JSON schema v1.
renderMigrationCommandJson :: CliOutcome -> Value
renderMigrationCommandJson CliOutcome {command, exitClass, payload} =
  object
    ( [ "schemaVersion" .= jsonSchemaVersion,
        "command" .= command,
        "ok" .= (exitClass == ExitSucceeded)
      ]
        <> case payload of
          Left cliError -> ["error" .= errorValue cliError]
          Right cliPayload -> ["data" .= payloadValue cliPayload]
    )

-- | Render an adapter import report using JSON schema v1.
renderHistoryImportJson :: Text -> HistoryImportReport -> Value
renderHistoryImportJson sourceName HistoryImportReport {importResults, cleanupIssues} =
  object
    [ "schemaVersion" .= jsonSchemaVersion,
      "command" .= ("import" :: Text),
      "ok" .= True,
      "data"
        .= object
          [ "source" .= sourceName,
            "results" .= (historyImportResultValue <$> NonEmpty.toList importResults),
            "cleanup_issues" .= (cleanupIssueValue <$> cleanupIssues)
          ]
    ]

historyImportResultValue :: HistoryImportResult -> Value
historyImportResultValue HistoryImportResult {importedMigration, importOutcome} =
  object
    [ "id" .= migrationIdText importedMigration,
      "outcome" .= case importOutcome of Imported -> ("imported" :: Text); AlreadyImported -> "alreadyImported"
    ]

payloadValue :: CliPayload -> Value
payloadValue cliPayload =
  case cliPayload of
    PlanPayload components ->
      object ["components" .= (componentValue <$> components)]
    ListPayload migrations ->
      object ["migrations" .= (migrationValue <$> migrations)]
    CheckPayload checked ->
      object ["migrations" .= (checkedValue <$> NonEmpty.toList checked)]
    StatusPayload report -> statusValue report
    VerifyPayload report -> verificationValue report
    UpPayload report -> migrationReportValue report
    RepairPayload report -> repairReportValue report
    NewPayload path -> object ["path" .= path]

componentValue :: ComponentDescription -> Value
componentValue (ComponentDescription name position dependencies migrations) =
  object
    [ "name" .= componentNameText name,
      "position" .= position,
      "dependencies" .= (componentNameText <$> Set.toAscList dependencies),
      "migrations" .= (migrationValue <$> NonEmpty.toList migrations)
    ]

migrationValue :: MigrationDescription -> Value
migrationValue (MigrationDescription identifier position checksum kind mode) =
  object
    [ "id" .= migrationIdText identifier,
      "position" .= position,
      "checksum" .= checksumText checksum,
      "kind" .= kindText kind,
      "transactionMode" .= modeText mode
    ]

checkedValue :: CheckedMigration -> Value
checkedValue (CheckedMigration file checksum) =
  object
    [ "file" .= file,
      "checksum" .= checksumText checksum
    ]

statusValue :: StatusReport -> Value
statusValue (StatusReport issues applied pending unknown) =
  object
    [ "issues" .= (verificationIssueValue <$> issues),
      "applied" .= (migrationIdText <$> applied),
      "pending" .= (migrationIdText <$> pending),
      "unknown" .= (storedMigrationValue <$> unknown)
    ]

verificationValue :: VerificationReport -> Value
verificationValue (VerificationReport issues applied pending unknown) =
  object
    [ "issues" .= (verificationIssueValue <$> issues),
      "applied" .= (migrationIdText <$> applied),
      "pending" .= (migrationIdText <$> pending),
      "unknown" .= (storedMigrationValue <$> unknown)
    ]

storedMigrationValue :: StoredMigration -> Value
storedMigrationValue
  ( StoredMigration
      identifier
      position
      checksum
      kind
      mode
      status
      startedAt
      finishedAt
      executionTimeMilliseconds
      errorMessage
      runnerVersion
    ) =
    object
      [ "id" .= migrationIdText identifier,
        "position" .= position,
        "checksum" .= checksumText checksum,
        "kind" .= kindText kind,
        "transactionMode" .= modeText mode,
        "status" .= statusText status,
        "startedAt" .= utcText startedAt,
        "finishedAt" .= (utcText <$> finishedAt),
        "durationMilliseconds" .= executionTimeMilliseconds,
        "error" .= errorMessage,
        "runnerVersion" .= runnerVersion
      ]

verificationIssueValue :: VerificationIssue -> Value
verificationIssueValue issue =
  case issue of
    DuplicateStoredMigration identifier -> issueWithId "duplicateStoredMigration" identifier
    DuplicateStoredPosition component position ->
      object
        [ "type" .= ("duplicateStoredPosition" :: Text),
          "component" .= componentNameText component,
          "position" .= position
        ]
    StoredMigrationRunning identifier -> issueWithId "storedMigrationRunning" identifier
    StoredMigrationFailed identifier -> issueWithId "storedMigrationFailed" identifier
    MigrationPositionMismatch identifier expected actual ->
      mismatchValue "migrationPositionMismatch" identifier ("expected" .= expected) ("actual" .= actual)
    MigrationChecksumMismatch identifier expected actual ->
      mismatchValue
        "migrationChecksumMismatch"
        identifier
        ("expected" .= checksumText expected)
        ("actual" .= checksumText actual)
    MigrationKindMismatch identifier expected actual ->
      mismatchValue
        "migrationKindMismatch"
        identifier
        ("expected" .= kindText expected)
        ("actual" .= kindText actual)
    MigrationTransactionModeMismatch identifier expected actual ->
      mismatchValue
        "migrationTransactionModeMismatch"
        identifier
        ("expected" .= modeText expected)
        ("actual" .= modeText actual)
    AppliedMigrationAfterGap identifier missing ->
      object
        [ "type" .= ("appliedMigrationAfterGap" :: Text),
          "id" .= migrationIdText identifier,
          "missing" .= migrationIdText missing
        ]
    UnknownStoredMigration identifier -> issueWithId "unknownStoredMigration" identifier
    PendingMigration identifier -> issueWithId "pendingMigration" identifier

issueWithId :: Text -> MigrationId -> Value
issueWithId issueType identifier =
  object
    [ "type" .= issueType,
      "id" .= migrationIdText identifier
    ]

mismatchValue :: Text -> MigrationId -> Pair -> Pair -> Value
mismatchValue issueType identifier expected actual =
  object ["type" .= issueType, "id" .= migrationIdText identifier, expected, actual]

migrationReportValue :: MigrationReport -> Value
migrationReportValue MigrationReport {startedAt, finishedAt, results, cleanupIssues} =
  object
    [ "startedAt" .= utcText startedAt,
      "finishedAt" .= utcText finishedAt,
      "results" .= (migrationResultValue <$> NonEmpty.toList results),
      "cleanup_issues" .= (cleanupIssueValue <$> cleanupIssues)
    ]

migrationResultValue :: MigrationResult -> Value
migrationResultValue (MigrationResult identifier outcome duration) =
  object
    [ "id" .= migrationIdText identifier,
      "outcome" .= outcomeText outcome,
      "durationMilliseconds" .= (durationMilliseconds <$> duration)
    ]

repairReportValue :: RepairReport -> Value
repairReportValue RepairReport {repairedMigration, operation, oldStatus, newStatus, cleanupIssues} =
  object
    [ "id" .= migrationIdText repairedMigration,
      "operation" .= repairOperationText operation,
      "oldStatus" .= statusText oldStatus,
      "newStatus" .= statusText newStatus,
      "cleanup_issues" .= (cleanupIssueValue <$> cleanupIssues)
    ]

cleanupIssueValue :: CleanupIssue -> Value
cleanupIssueValue cleanupIssue =
  case cleanupIssue of
    AdvisoryUnlockReturnedFalse -> object ["type" .= ("advisoryUnlockReturnedFalse" :: Text)]
    AdvisoryUnlockFailed sessionError ->
      object
        [ "type" .= ("advisoryUnlockFailed" :: Text),
          "message" .= Text.pack (show sessionError)
        ]
    StatementTimeoutRestoreFailed sessionError ->
      object
        [ "type" .= ("statementTimeoutRestoreFailed" :: Text),
          "message" .= Text.pack (show sessionError)
        ]

errorValue :: CliError -> Value
errorValue cliError =
  object
    [ "type" .= cliErrorType cliError,
      "message" .= Text.pack (renderCliErrorMessage cliError)
    ]

cliErrorType :: CliError -> Text
cliErrorType cliError =
  case cliError of
    CliInputError _ -> "input.invalid"
    CliMigrationError migrationError -> "migration." <> migrationErrorType migrationError
    CliRepairDefinitionError _ -> "repair.definition"
    CliRepairError _ -> "repair.execution"
    CliManifestError _ -> "manifest.invalid"
    CliAuthoringError _ -> "authoring.failed"

renderCliErrorMessage :: CliError -> String
renderCliErrorMessage cliError =
  case cliError of
    CliInputError err -> Text.unpack err
    CliMigrationError err -> show err
    CliRepairDefinitionError err -> show err
    CliRepairError err -> show err
    CliManifestError err -> show err
    CliAuthoringError err -> show err

migrationErrorType :: MigrationError -> Text
migrationErrorType migrationError =
  case migrationError of
    ConnectionAcquisitionFailed _ -> "connectionAcquisitionFailed"
    DatabaseSessionFailed _ -> "databaseSessionFailed"
    UnsupportedPostgresVersion _ -> "unsupportedPostgresVersion"
    InvalidLockWait _ -> "invalidLockWait"
    InvalidStatementTimeout _ -> "invalidStatementTimeout"
    AdvisoryLockUnavailable -> "advisoryLockUnavailable"
    AdvisoryLockTimedOut _ -> "advisoryLockTimedOut"
    LedgerInitializationFailed _ -> "ledgerInitializationFailed"
    PlanVerificationFailed _ -> "planVerificationFailed"
    UnsupportedNonTransactionalMigration _ -> "unsupportedNonTransactionalMigration"
    TransactionCondemned _ -> "transactionCondemned"
    EventHandlerFailed _ _ -> "eventHandlerFailed"
    MigrationActionFailed _ -> "migrationActionFailed"
    InvalidMigrationAction _ -> "invalidMigrationAction"
    NonTransactionalMigrationFailed _ _ -> "nonTransactionalMigrationFailed"
    LedgerTransitionDidNotMatch _ _ _ -> "ledgerTransitionDidNotMatch"
    NonTransactionalFailureRecordingFailed _ _ _ -> "nonTransactionalFailureRecordingFailed"
    CleanupFailed _ _ -> "cleanupFailed"

migrationIdText :: MigrationId -> Text
migrationIdText identifier =
  componentNameText (migrationIdComponent identifier)
    <> "/"
    <> migrationNameText (migrationIdName identifier)

kindText :: MigrationKind -> Text
kindText kind = case kind of SqlKind -> "sql"; HaskellKind -> "haskell"

modeText :: TransactionMode -> Text
modeText mode = case mode of Transactional -> "transactional"; NonTransactional -> "nontransactional"

statusText :: MigrationStatus -> Text
statusText status = case status of Running -> "running"; Applied -> "applied"; Failed -> "failed"

outcomeText :: MigrationOutcome -> Text
outcomeText outcome = case outcome of AlreadyApplied -> "alreadyApplied"; AppliedNow -> "appliedNow"

repairOperationText :: RepairOperation -> Text
repairOperationText operation = case operation of MarkApplied -> "markApplied"; Retry -> "retry"

durationMilliseconds :: NominalDiffTime -> Integer
durationMilliseconds duration = round (duration * 1000)

utcText :: UTCTime -> Text
utcText = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"
