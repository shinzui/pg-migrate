module Database.PostgreSQL.Migrate.History.Validation
  ( ResolvedHistoryMapping (..),
    resolveHistoryImport,
    stateVerifiedEvidence,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as ByteString
import Data.Int (Int32)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate.History.Types
import Database.PostgreSQL.Migrate.Types
import Numeric (showHex)
import PgMigrate.Prelude

data ResolvedHistoryMapping = ResolvedHistoryMapping
  { resolvedTarget :: !MigrationId,
    resolvedPosition :: !Int32,
    resolvedChecksum :: !MigrationChecksum,
    resolvedKind :: !MigrationKind,
    resolvedTransactionMode :: !TransactionMode,
    resolvedAuditEvidence :: !Value
  }
  deriving stock (Generic, Eq, Show)

data PlannedTarget = PlannedTarget
  { plannedComponent :: !ComponentName,
    plannedPosition :: !Int32,
    plannedMigration :: !Migration
  }

data RequirementResult
  = RequirementUnsatisfied
  | RequirementSatisfied !(Set EvidenceKey)
  | RequirementAmbiguous

resolveHistoryImport ::
  EquivalentHistoryPolicy ->
  MigrationPlan ->
  Map EvidenceKey ImportEvidence ->
  HistoryImport ->
  Either HistoryValidationError (NonEmpty ResolvedHistoryMapping)
resolveHistoryImport policy plan availableEvidence history = do
  targets <- traverse (lookupTarget plannedTargets) (mappings history)
  validatePrefixes targets
  traverse (resolveMapping policy availableEvidence history) targets
  where
    plannedTargets = flattenPlan plan

stateVerifiedEvidence :: EvidenceKey -> Value -> ImportEvidence
stateVerifiedEvidence key details =
  ImportEvidence
    { identity = unEvidenceKey key,
      appliedAt = Nothing,
      strength = StateVerified,
      payloadChecksum = Nothing,
      details
    }

flattenPlan :: MigrationPlan -> Map MigrationId PlannedTarget
flattenPlan plan =
  Map.fromList
    [ ( MigrationId (componentNameOf component) (migrationNameOf migration),
        PlannedTarget
          { plannedComponent = componentNameOf component,
            plannedPosition = position,
            plannedMigration = migration
          }
      )
    | component <- toList (planComponentsOf plan),
      (position, migration) <- zip [1 ..] (toList (componentMigrationsOf component))
    ]

lookupTarget ::
  Map MigrationId PlannedTarget ->
  HistoryMapping ->
  Either HistoryValidationError (HistoryMapping, PlannedTarget)
lookupTarget plannedTargets mapping =
  case Map.lookup (target mapping) plannedTargets of
    Nothing -> Left (HistoryTargetUnknown (target mapping))
    Just planned -> Right (mapping, planned)

validatePrefixes ::
  NonEmpty (HistoryMapping, PlannedTarget) ->
  Either HistoryValidationError ()
validatePrefixes targets =
  for_ (Map.toAscList positionsByComponent) $ \(component, positions) ->
    case firstMissingPrefixPosition (List.sort positions) of
      Nothing -> Right ()
      Just missing -> Left (HistoryComponentPrefixGap component missing)
  where
    positionsByComponent =
      Map.fromListWith
        (<>)
        [ (plannedComponent planned, [fromIntegral (plannedPosition planned)])
        | (_, planned) <- toList targets
        ]

firstMissingPrefixPosition :: [Int] -> Maybe Int
firstMissingPrefixPosition positions =
  find (\expected -> expected `notElem` positions) [1 .. maximum positions]

resolveMapping ::
  EquivalentHistoryPolicy ->
  Map EvidenceKey ImportEvidence ->
  HistoryImport ->
  (HistoryMapping, PlannedTarget) ->
  Either HistoryValidationError ResolvedHistoryMapping
resolveMapping policy availableEvidence history (mapping, planned) = do
  usedKeys <-
    case evaluateRequirement availableEvidence (requirement mapping) of
      RequirementUnsatisfied -> Left (HistoryRequirementUnsatisfied (target mapping))
      RequirementAmbiguous -> Left (HistoryRequirementAmbiguous (target mapping))
      RequirementSatisfied keys -> Right keys
  validatePayload policy availableEvidence mapping planned usedKeys
  let migration = plannedMigration planned
  Right
    ResolvedHistoryMapping
      { resolvedTarget = target mapping,
        resolvedPosition = plannedPosition planned,
        resolvedChecksum = migrationChecksumOf migration,
        resolvedKind = migrationKindOf migration,
        resolvedTransactionMode = migrationModeOf migration,
        resolvedAuditEvidence = auditEvidence history mapping planned availableEvidence usedKeys
      }

evaluateRequirement ::
  Map EvidenceKey ImportEvidence ->
  EvidenceRequirement ->
  RequirementResult
evaluateRequirement available = \case
  Evidence key ->
    if Map.member key available
      then RequirementSatisfied (Set.singleton key)
      else RequirementUnsatisfied
  AllOf requirements ->
    combineAll (evaluateRequirement available <$> toList requirements)
  AnyOf requirements ->
    combineAny (evaluateRequirement available <$> toList requirements)

combineAll :: [RequirementResult] -> RequirementResult
combineAll results
  | any isAmbiguous results = RequirementAmbiguous
  | any isUnsatisfied results = RequirementUnsatisfied
  | otherwise = RequirementSatisfied (Set.unions [keys | RequirementSatisfied keys <- results])

combineAny :: [RequirementResult] -> RequirementResult
combineAny results =
  case [keys | RequirementSatisfied keys <- results] of
    []
      | any isAmbiguous results -> RequirementAmbiguous
      | otherwise -> RequirementUnsatisfied
    [keys]
      | any isAmbiguous results -> RequirementAmbiguous
      | otherwise -> RequirementSatisfied keys
    _ -> RequirementAmbiguous

isUnsatisfied :: RequirementResult -> Bool
isUnsatisfied RequirementUnsatisfied = True
isUnsatisfied _ = False

isAmbiguous :: RequirementResult -> Bool
isAmbiguous RequirementAmbiguous = True
isAmbiguous _ = False

validatePayload ::
  EquivalentHistoryPolicy ->
  Map EvidenceKey ImportEvidence ->
  HistoryMapping ->
  PlannedTarget ->
  Set EvidenceKey ->
  Either HistoryValidationError ()
validatePayload policy available mapping planned usedKeys =
  case payload mapping of
    SamePayload key -> do
      when
        (migrationKindOf (plannedMigration planned) == HaskellKind)
        (Left (HistorySamePayloadForHaskell (target mapping)))
      unless
        (Set.member key usedKeys)
        (Left (HistoryPayloadEvidenceMissing (target mapping) key))
      sourceEvidence <-
        maybe
          (Left (HistoryPayloadEvidenceMissing (target mapping) key))
          Right
          (Map.lookup key available)
      sourceChecksum <-
        maybe
          (Left (HistoryPayloadChecksumMissing (target mapping) key))
          Right
          (payloadChecksum sourceEvidence)
      unless
        (sourceChecksum == migrationChecksumOf (plannedMigration planned))
        (Left (HistoryPayloadChecksumMismatch (target mapping) key))
    EquivalentState -> do
      unless
        (policy == AllowEquivalentHistory)
        (Left (HistoryEquivalentStateDisallowed (target mapping)))
      unless
        ( any
            ((== StateVerified) . strength)
            (mapMaybe (`Map.lookup` available) (Set.toAscList usedKeys))
        )
        (Left (HistoryEquivalentStateUnverified (target mapping)))

auditEvidence ::
  HistoryImport ->
  HistoryMapping ->
  PlannedTarget ->
  Map EvidenceKey ImportEvidence ->
  Set EvidenceKey ->
  Value
auditEvidence history mapping planned available usedKeys =
  object
    [ "source" .= source history,
      "reason" .= reason history,
      "target" .= migrationIdValue (target mapping),
      "position" .= plannedPosition planned,
      "kind" .= kindText (migrationKindOf (plannedMigration planned)),
      "transaction_mode" .= modeText (migrationModeOf (plannedMigration planned)),
      "target_checksum" .= checksumText (migrationChecksumOf (plannedMigration planned)),
      "requirement" .= requirementValue (requirement mapping),
      "payload_relation" .= payloadValue (payload mapping),
      "satisfying_evidence"
        .= [ evidenceValue key sourceEvidence
           | key <- Set.toAscList usedKeys,
             sourceEvidence <- maybeToList (Map.lookup key available)
           ]
    ]

evidenceValue :: EvidenceKey -> ImportEvidence -> Value
evidenceValue key sourceEvidence =
  object
    [ "key" .= unEvidenceKey key,
      "identity" .= identity sourceEvidence,
      "applied_at" .= timestampValue (appliedAt sourceEvidence),
      "strength" .= strengthText (strength sourceEvidence),
      "payload_checksum" .= (checksumText <$> payloadChecksum sourceEvidence),
      "details" .= details sourceEvidence
    ]

requirementValue :: EvidenceRequirement -> Value
requirementValue = \case
  Evidence key -> object ["evidence" .= unEvidenceKey key]
  AllOf requirements -> object ["all_of" .= (requirementValue <$> toList requirements)]
  AnyOf requirements -> object ["any_of" .= (requirementValue <$> toList requirements)]

payloadValue :: PayloadRelation -> Value
payloadValue = \case
  SamePayload key -> object ["same_payload" .= unEvidenceKey key]
  EquivalentState -> object ["equivalent_state" .= True]

migrationIdValue :: MigrationId -> Value
migrationIdValue identifier =
  object
    [ "component" .= componentNameText (migrationIdComponent identifier),
      "migration" .= migrationNameText (migrationIdName identifier)
    ]

timestampValue :: Maybe SourceTimestamp -> Value
timestampValue = \case
  Nothing -> object ["kind" .= ("missing" :: Text)]
  Just (AbsoluteTime timestamp) ->
    object ["kind" .= ("absolute" :: Text), "value" .= show timestamp]
  Just (LocalTimeWithoutZone timestamp) ->
    object ["kind" .= ("local-without-zone" :: Text), "value" .= show timestamp]

strengthText :: EvidenceStrength -> Text
strengthText = \case
  LedgerOnly -> "ledger-only"
  SourceManifestVerified -> "source-manifest-verified"
  SourceLedgerChecksumVerified -> "source-ledger-checksum-verified"
  StateVerified -> "state-verified"

kindText :: MigrationKind -> Text
kindText = \case
  SqlKind -> "sql"
  HaskellKind -> "haskell"

modeText :: TransactionMode -> Text
modeText = \case
  Transactional -> "transactional"
  NonTransactional -> "nontransactional"

checksumText :: MigrationChecksum -> Text
checksumText (MigrationChecksum bytes) =
  Text.concat (twoHexDigits <$> ByteString.unpack bytes)
  where
    twoHexDigits byte =
      let encoded = Text.pack (showHex byte "")
       in if Text.length encoded == 1 then "0" <> encoded else encoded

maybeToList :: Maybe value -> [value]
maybeToList Nothing = []
maybeToList (Just value) = [value]
