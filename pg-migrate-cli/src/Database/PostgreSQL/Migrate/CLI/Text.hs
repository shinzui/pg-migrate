module Database.PostgreSQL.Migrate.CLI.Text
  ( renderMigrationCommandText,
  )
where

import Data.ByteString qualified as ByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.CLI.Outcome
import Database.PostgreSQL.Migrate.Internal
import Numeric qualified
import PgMigrate.CLI.Prelude

-- | Render a stable human-oriented outcome.
renderMigrationCommandText :: CliOutcome -> Text
renderMigrationCommandText CliOutcome {command, payload = Left cliError} =
  command <> ": error: " <> renderCliError cliError
renderMigrationCommandText CliOutcome {payload = Right cliPayload} = renderPayload cliPayload

renderCliError :: CliError -> Text
renderCliError cliError =
  case cliError of
    CliMigrationError err -> Text.pack (show err)
    CliRepairDefinitionError err -> Text.pack (show err)
    CliRepairError err -> Text.pack (show err)
    CliManifestError err -> Text.pack (show err)
    CliAuthoringError err -> Text.pack (show err)

renderPayload :: CliPayload -> Text
renderPayload cliPayload =
  case cliPayload of
    PlanPayload components -> renderPlan components
    ListPayload migrations -> Text.unlines (renderMigration <$> migrations)
    CheckPayload checked -> Text.unlines (renderChecked <$> NonEmpty.toList checked)
    StatusPayload report -> renderStatus report
    VerifyPayload report -> renderVerification report
    UpPayload report -> renderMigrationReport report
    RepairPayload report -> renderRepairReport report
    NewPayload path -> "created " <> Text.pack path <> "\n"

renderPlan :: [ComponentDescription] -> Text
renderPlan components = Text.unlines (renderComponent <$> components)

renderComponent :: ComponentDescription -> Text
renderComponent (ComponentDescription name position dependencies migrations) =
  Text.intercalate
    " "
    [ Text.pack (show position) <> ".",
      componentNameText name,
      "depends=[" <> Text.intercalate "," (componentNameText <$> Set.toAscList dependencies) <> "]",
      "migrations=" <> Text.pack (show (NonEmpty.length migrations))
    ]

renderMigration :: MigrationDescription -> Text
renderMigration (MigrationDescription identifier position checksum kind mode) =
  Text.intercalate
    " "
    [ renderMigrationId identifier,
      "position=" <> Text.pack (show position),
      "checksum=" <> checksumText checksum,
      "kind=" <> renderKind kind,
      "transaction=" <> renderMode mode
    ]

renderChecked :: CheckedMigration -> Text
renderChecked (CheckedMigration file checksum) =
  Text.pack file <> " checksum=" <> checksumText checksum

renderStatus :: StatusReport -> Text
renderStatus (StatusReport issues applied pending unknown) =
  Text.unlines
    ( [ "applied=" <> Text.pack (show (length applied)),
        "pending=" <> Text.pack (show (length pending)),
        "unknown=" <> Text.pack (show (length unknown)),
        "issues=" <> Text.pack (show (length issues))
      ]
        <> (("applied " <>) . renderMigrationId <$> applied)
        <> (("pending " <>) . renderMigrationId <$> pending)
        <> (("unknown " <>) . renderStoredMigrationId <$> unknown)
        <> (("issue " <>) . Text.pack . show <$> issues)
    )

renderVerification :: VerificationReport -> Text
renderVerification (VerificationReport issues applied pending unknown) =
  Text.unlines
    ( [ if null issues then "verification ok" else "verification failed",
        "applied=" <> Text.pack (show (length applied)),
        "pending=" <> Text.pack (show (length pending)),
        "unknown=" <> Text.pack (show (length unknown))
      ]
        <> (("issue " <>) . Text.pack . show <$> issues)
    )

renderMigrationReport :: MigrationReport -> Text
renderMigrationReport (MigrationReport startedAt finishedAt results) =
  Text.unlines
    ( [ "started=" <> Text.pack (show startedAt),
        "finished=" <> Text.pack (show finishedAt)
      ]
        <> (renderMigrationResult <$> NonEmpty.toList results)
    )

renderMigrationResult :: MigrationResult -> Text
renderMigrationResult (MigrationResult identifier outcome duration) =
  Text.intercalate
    " "
    [ renderMigrationId identifier,
      "outcome=" <> renderOutcome outcome,
      "duration_ms=" <> maybe "null" renderDurationMilliseconds duration
    ]

renderRepairReport :: RepairReport -> Text
renderRepairReport (RepairReport identifier operation oldStatus newStatus) =
  Text.intercalate
    " "
    [ renderMigrationId identifier,
      "operation=" <> renderRepairOperation operation,
      "old_status=" <> renderStatusName oldStatus,
      "new_status=" <> renderStatusName newStatus
    ]
    <> "\n"

renderStoredMigrationId :: StoredMigration -> Text
renderStoredMigrationId StoredMigration {storedMigrationId} = renderMigrationId storedMigrationId

renderMigrationId :: MigrationId -> Text
renderMigrationId identifier =
  componentNameText (migrationIdComponent identifier)
    <> "/"
    <> migrationNameText (migrationIdName identifier)

checksumText :: MigrationChecksum -> Text
checksumText =
  Text.pack . concatMap renderByte . ByteString.unpack . migrationChecksumBytes
  where
    renderByte byte =
      case Numeric.showHex byte "" of
        [digit] -> ['0', digit]
        digits -> digits

renderKind :: MigrationKind -> Text
renderKind kind = case kind of SqlKind -> "sql"; HaskellKind -> "haskell"

renderMode :: TransactionMode -> Text
renderMode mode = case mode of Transactional -> "transactional"; NonTransactional -> "nontransactional"

renderOutcome :: MigrationOutcome -> Text
renderOutcome outcome = case outcome of AlreadyApplied -> "already_applied"; AppliedNow -> "applied_now"

renderRepairOperation :: RepairOperation -> Text
renderRepairOperation operation = case operation of MarkApplied -> "mark_applied"; Retry -> "retry"

renderStatusName :: MigrationStatus -> Text
renderStatusName status = case status of Running -> "running"; Applied -> "applied"; Failed -> "failed"

renderDurationMilliseconds :: NominalDiffTime -> Text
renderDurationMilliseconds duration = Text.pack (show (round (duration * 1000) :: Integer))
