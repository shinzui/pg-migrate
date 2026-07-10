module Database.PostgreSQL.Migrate.Ledger
  ( comparePlanWithLedger,
    loadLedger,
    statusFromSnapshot,
    statusFromSnapshotWith,
    verifyFromSnapshot,
    loadStatus,
    loadVerification,
  )
where

import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate.Ledger.Sql
import Database.PostgreSQL.Migrate.Ledger.Types
import Database.PostgreSQL.Migrate.Plan
import Database.PostgreSQL.Migrate.Types
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import PgMigrate.Prelude

comparePlanWithLedger ::
  UnknownMigrationsPolicy ->
  PlanDescription ->
  [StoredMigration] ->
  VerificationReport
comparePlanWithLedger unknownPolicy description storedInput =
  VerificationReport
    { issues =
        duplicateIdentityIssues
          <> duplicatePositionIssues
          <> statusIssues
          <> metadataIssues
          <> prefixIssues
          <> unknownIssues,
      appliedMigrations,
      pendingMigrations,
      unknownMigrations
    }
  where
    target = flattenPlan description
    targetById = Map.fromList ((\migration -> (migrationId migration, migration)) <$> target)
    stored = List.sortOn storedSortKey storedInput
    storedById = firstBy storedMigrationId stored

    duplicateIdentityIssues =
      DuplicateStoredMigration <$> duplicates (storedMigrationId <$> stored)
    duplicatePositionIssues =
      (\(component, position) -> DuplicateStoredPosition component position)
        <$> duplicates (storedPositionKey <$> stored)
    statusIssues = concatMap storedStatusIssues stored
    metadataIssues = concatMap (migrationMetadataIssues storedById) target
    prefixIssues = concatMap (componentPrefixIssues storedById) (planComponents description)

    unknownMigrations =
      filter ((`Map.notMember` targetById) . storedMigrationId) stored
    unknownIssues =
      case unknownPolicy of
        RejectUnknownMigrations -> UnknownStoredMigration . storedMigrationId <$> unknownMigrations
        AllowUnknownMigrations -> []

    appliedMigrations =
      mapMaybe (targetApplied storedById) target
    pendingMigrations =
      mapMaybe (targetPending storedById) target

loadLedger :: LedgerConfig -> Session LedgerSnapshot
loadLedger config = do
  ledgerExists <-
    Session.statement
      (ledgerSchemaText config)
      ledgerMetadataExistsStatement
  if ledgerExists
    then do
      metadata <- Session.statement () (loadLedgerMetadataStatement config)
      migrations <- Session.statement () (loadStoredMigrationsStatement config)
      pure LedgerSnapshot {metadata = Just metadata, migrations}
    else pure LedgerSnapshot {metadata = Nothing, migrations = []}

statusFromSnapshot :: MigrationPlan -> LedgerSnapshot -> StatusReport
statusFromSnapshot = statusFromSnapshotWith AllowUnknownMigrations

statusFromSnapshotWith ::
  UnknownMigrationsPolicy ->
  MigrationPlan ->
  LedgerSnapshot ->
  StatusReport
statusFromSnapshotWith unknownPolicy plan LedgerSnapshot {migrations} =
  case comparePlanWithLedger unknownPolicy (planDescription plan) migrations of
    VerificationReport
      { issues,
        appliedMigrations,
        pendingMigrations,
        unknownMigrations
      } ->
        StatusReport
          { issues,
            appliedMigrations,
            pendingMigrations,
            unknownMigrations
          }

verifyFromSnapshot :: MigrationPlan -> LedgerSnapshot -> VerificationReport
verifyFromSnapshot plan LedgerSnapshot {migrations} =
  case comparePlanWithLedger RejectUnknownMigrations (planDescription plan) migrations of
    VerificationReport
      { issues,
        appliedMigrations,
        pendingMigrations,
        unknownMigrations
      } ->
        VerificationReport
          { issues = issues <> (PendingMigration <$> pendingMigrations),
            appliedMigrations,
            pendingMigrations,
            unknownMigrations
          }

loadStatus ::
  LedgerConfig ->
  UnknownMigrationsPolicy ->
  MigrationPlan ->
  Session StatusReport
loadStatus config unknownPolicy plan =
  statusFromSnapshotWith unknownPolicy plan <$> loadLedger config

loadVerification :: LedgerConfig -> MigrationPlan -> Session VerificationReport
loadVerification config plan = verifyFromSnapshot plan <$> loadLedger config

flattenPlan :: PlanDescription -> [MigrationDescription]
flattenPlan description =
  concatMap (toList . componentMigrations) (planComponents description)

planComponents :: PlanDescription -> [ComponentDescription]
planComponents (PlanDescription components) = toList components

componentMigrations :: ComponentDescription -> NonEmpty MigrationDescription
componentMigrations ComponentDescription {migrations} = migrations

storedSortKey :: StoredMigration -> (Text, Int, Text)
storedSortKey StoredMigration {storedMigrationId, position = storedPosition} =
  ( componentNameText (migrationIdComponent storedMigrationId),
    storedPosition,
    migrationNameText (migrationIdName storedMigrationId)
  )

storedPositionKey :: StoredMigration -> (ComponentName, Int)
storedPositionKey StoredMigration {storedMigrationId, position = storedPosition} =
  (migrationIdComponent storedMigrationId, storedPosition)

firstBy :: (Ord key) => (value -> key) -> [value] -> Map key value
firstBy keyOf =
  foldl
    (\values value -> Map.insertWith (\_ previous -> previous) (keyOf value) value values)
    Map.empty

duplicates :: (Ord value) => [value] -> [value]
duplicates = go Set.empty Set.empty
  where
    go _ _ [] = []
    go seen reported (value : rest)
      | value `Set.member` reported = go seen reported rest
      | value `Set.member` seen = value : go seen (Set.insert value reported) rest
      | otherwise = go (Set.insert value seen) reported rest

storedStatusIssues :: StoredMigration -> [VerificationIssue]
storedStatusIssues stored =
  case status stored of
    Running -> [StoredMigrationRunning (storedMigrationId stored)]
    Applied -> []
    Failed -> [StoredMigrationFailed (storedMigrationId stored)]

migrationMetadataIssues ::
  Map MigrationId StoredMigration ->
  MigrationDescription ->
  [VerificationIssue]
migrationMetadataIssues storedById expected =
  case Map.lookup expectedId storedById of
    Nothing -> []
    Just
      StoredMigration
        { position = actualPosition,
          checksum = actualChecksum,
          kind = actualKind,
          transactionMode = actualMode
        } ->
        concat
          [ [ MigrationPositionMismatch expectedId expectedPosition actualPosition
            | actualPosition /= expectedPosition
            ],
            [ MigrationChecksumMismatch expectedId expectedChecksum actualChecksum
            | actualChecksum /= expectedChecksum
            ],
            [ MigrationKindMismatch expectedId expectedKind actualKind
            | actualKind /= expectedKind
            ],
            [ MigrationTransactionModeMismatch expectedId expectedMode actualMode
            | actualMode /= expectedMode
            ]
          ]
  where
    MigrationDescription
      { migrationId = expectedId,
        position = expectedPosition,
        checksum = expectedChecksum,
        kind = expectedKind,
        transactionMode = expectedMode
      } = expected

componentPrefixIssues ::
  Map MigrationId StoredMigration ->
  ComponentDescription ->
  [VerificationIssue]
componentPrefixIssues storedById ComponentDescription {migrations} =
  snd (foldl step (Nothing, []) (toList migrations))
  where
    step (firstGap, accumulated) MigrationDescription {migrationId}
      | Map.member migrationId storedById =
          case firstGap of
            Nothing -> (Nothing, accumulated)
            Just missing ->
              (Just missing, accumulated <> [AppliedMigrationAfterGap migrationId missing])
      | otherwise = (Just (fromMaybe migrationId firstGap), accumulated)

targetApplied ::
  Map MigrationId StoredMigration ->
  MigrationDescription ->
  Maybe MigrationId
targetApplied storedById MigrationDescription {migrationId} = do
  stored <- Map.lookup migrationId storedById
  case status stored of
    Applied -> Just migrationId
    Running -> Nothing
    Failed -> Nothing

targetPending ::
  Map MigrationId StoredMigration ->
  MigrationDescription ->
  Maybe MigrationId
targetPending storedById MigrationDescription {migrationId} =
  case Map.lookup migrationId storedById of
    Just stored | status stored == Applied -> Nothing
    _ -> Just migrationId
