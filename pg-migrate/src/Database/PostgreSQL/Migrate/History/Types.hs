{-# LANGUAGE RankNTypes #-}

module Database.PostgreSQL.Migrate.History.Types
  ( EvidenceKey (..),
    evidenceKey,
    EvidenceStrength (..),
    SourceTimestamp (..),
    ImportEvidence (..),
    ledgerOnlyEvidence,
    sourceManifestVerifiedEvidence,
    sourceLedgerChecksumVerifiedEvidence,
    EvidenceRequirement (..),
    PayloadRelation (..),
    HistoryMapping (..),
    historyMapping,
    historyMappingPayloadRelation,
    StateValidationError (..),
    stateValidationError,
    StateValidator (..),
    stateValidator,
    HistoryImport (..),
    historyImport,
    HistoryDefinitionError (..),
    EquivalentHistoryPolicy (..),
    ImportOptions (..),
    defaultImportOptions,
    withEquivalentHistory,
    withImportRunOptions,
    importEquivalentHistoryPolicy,
    HistoryImportOutcome (..),
    HistoryImportResult (..),
    HistoryImportReport (..),
    HistoryValidationError (..),
    HistoryImportError (..),
  )
where

import Data.Aeson (Value)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (LocalTime, UTCTime)
import Database.PostgreSQL.Migrate.Runner.Types
import Database.PostgreSQL.Migrate.Types
import Hasql.Transaction qualified as Transaction
import PgMigrate.Prelude

-- | Validated key naming one independently checked source fact.
newtype EvidenceKey = EvidenceKey
  { unEvidenceKey :: Text
  }
  deriving stock (Generic, Eq, Ord, Show)

-- | Increasing classes of source-history assurance.
data EvidenceStrength
  = LedgerOnly
  | SourceManifestVerified
  | SourceLedgerChecksumVerified
  | StateVerified
  deriving stock (Generic, Eq, Ord, Show)

-- | Source time preserving whether a timezone was actually available.
data SourceTimestamp
  = AbsoluteTime !UTCTime
  | LocalTimeWithoutZone !LocalTime
  deriving stock (Generic, Eq, Ord, Show)

-- | Auditable source identity, assurance, checksum, and adapter details.
data ImportEvidence = ImportEvidence
  { identity :: !Text,
    appliedAt :: !(Maybe SourceTimestamp),
    strength :: !EvidenceStrength,
    payloadChecksum :: !(Maybe MigrationChecksum),
    details :: !Value
  }
  deriving stock (Generic, Eq, Show)

-- | Boolean evidence expression required by one target mapping.
data EvidenceRequirement
  = Evidence !EvidenceKey
  | AllOf !(NonEmpty EvidenceRequirement)
  | AnyOf !(NonEmpty EvidenceRequirement)
  deriving stock (Generic, Eq, Show)

-- | Whether source bytes match or only verified database state is equivalent.
data PayloadRelation
  = SamePayload !EvidenceKey
  | EquivalentState
  deriving stock (Generic, Eq, Show)

-- | One target migration and the evidence required to import it.
data HistoryMapping = HistoryMapping
  { target :: !MigrationId,
    requirement :: !EvidenceRequirement,
    payload :: !PayloadRelation
  }
  deriving stock (Generic, Eq, Show)

-- | Validated diagnostic returned by a read-only state validator.
newtype StateValidationError = StateValidationError
  { stateValidationErrorText :: Text
  }
  deriving stock (Generic, Eq, Show)

-- | Read-only transaction that produces state evidence or a diagnostic.
data StateValidator = StateValidator
  { validatorEvidenceKey :: !EvidenceKey,
    runStateValidator :: !(Transaction.Transaction (Either StateValidationError Value))
  }

-- | Fully validated source, evidence, mappings, validators, and audit reason.
data HistoryImport = HistoryImport
  { source :: !Text,
    evidence :: !(Map EvidenceKey ImportEvidence),
    validators :: ![StateValidator],
    mappings :: !(NonEmpty HistoryMapping),
    reason :: !Text
  }

-- | Static error in an import definition.
data HistoryDefinitionError
  = EmptyEvidenceKey
  | EmptyEvidenceIdentity
  | EmptyStateValidationError
  | EmptyHistorySource
  | EmptyHistoryReason
  | DuplicateStateValidator !EvidenceKey
  | EvidenceKeyCollision !EvidenceKey
  | DuplicateHistoryTarget !MigrationId
  | UnknownRequirementEvidence !EvidenceKey
  | AmbiguousEvidenceRequirement !EvidenceRequirement
  | SamePayloadEvidenceNotRequired !EvidenceKey
  deriving stock (Generic, Eq, Show)

-- | Whether state-equivalent imports may be considered.
data EquivalentHistoryPolicy
  = RejectEquivalentHistory
  | AllowEquivalentHistory
  deriving stock (Generic, Eq, Ord, Show)

-- | Runner lifecycle and equivalent-history policy for an import.
data ImportOptions = ImportOptions
  { importRunOptions :: !RunOptions,
    equivalentHistoryPolicy :: !EquivalentHistoryPolicy
  }

-- | Whether an audit row was written now or already matched exactly.
data HistoryImportOutcome
  = Imported
  | AlreadyImported
  deriving stock (Generic, Eq, Ord, Show)

-- | Idempotent result for one imported target migration.
data HistoryImportResult = HistoryImportResult
  { importedMigration :: !MigrationId,
    importOutcome :: !HistoryImportOutcome
  }
  deriving stock (Generic, Eq, Show)

-- | Non-empty successful result set and lifecycle cleanup observations for an import operation.
data HistoryImportReport = HistoryImportReport
  { importResults :: !(NonEmpty HistoryImportResult),
    cleanupIssues :: ![CleanupIssue]
  }
  deriving stock (Generic, Eq, Show)

-- | Dynamic inconsistency between source evidence, mappings, policy, and plan.
data HistoryValidationError
  = HistoryTargetUnknown !MigrationId
  | HistoryComponentPrefixGap !ComponentName !Int
  | HistoryRequirementUnsatisfied !MigrationId
  | HistoryRequirementAmbiguous !MigrationId
  | HistoryPayloadEvidenceMissing !MigrationId !EvidenceKey
  | HistoryPayloadEvidenceTooWeak !MigrationId !EvidenceKey
  | HistoryPayloadChecksumMissing !MigrationId !EvidenceKey
  | HistoryPayloadChecksumMismatch !MigrationId !EvidenceKey
  | HistorySamePayloadForHaskell !MigrationId
  | HistoryEquivalentStateDisallowed !MigrationId
  | HistoryEquivalentStateUnverified !MigrationId
  deriving stock (Generic, Eq, Show)

-- | Structured runner, validator, mapping, conflict, or transition failure.
data HistoryImportError
  = HistoryImportRunnerError !MigrationError
  | HistoryStateValidationFailed !EvidenceKey !StateValidationError
  | HistoryImportValidationFailed !HistoryValidationError
  | HistoryImportConflict !MigrationId
  | HistoryImportTransitionFailed !MigrationId
  deriving stock (Generic, Show)

-- | Validate a non-empty evidence key.
evidenceKey :: Text -> Either HistoryDefinitionError EvidenceKey
evidenceKey value
  | Text.null (Text.strip value) = Left EmptyEvidenceKey
  | otherwise = Right (EvidenceKey value)

-- | Construct evidence based only on the predecessor ledger row.
ledgerOnlyEvidence ::
  Text ->
  Maybe SourceTimestamp ->
  Maybe MigrationChecksum ->
  Value ->
  Either HistoryDefinitionError ImportEvidence
ledgerOnlyEvidence = staticEvidence LedgerOnly

-- | Construct evidence whose selected payload was verified against a source manifest.
sourceManifestVerifiedEvidence ::
  Text ->
  Maybe SourceTimestamp ->
  Maybe MigrationChecksum ->
  Value ->
  Either HistoryDefinitionError ImportEvidence
sourceManifestVerifiedEvidence = staticEvidence SourceManifestVerified

-- | Construct evidence whose payload reproduced the predecessor checksum.
sourceLedgerChecksumVerifiedEvidence ::
  Text ->
  Maybe SourceTimestamp ->
  Maybe MigrationChecksum ->
  Value ->
  Either HistoryDefinitionError ImportEvidence
sourceLedgerChecksumVerifiedEvidence = staticEvidence SourceLedgerChecksumVerified

staticEvidence ::
  EvidenceStrength ->
  Text ->
  Maybe SourceTimestamp ->
  Maybe MigrationChecksum ->
  Value ->
  Either HistoryDefinitionError ImportEvidence
staticEvidence strength identity appliedAt payloadChecksum details
  | Text.null (Text.strip identity) = Left EmptyEvidenceIdentity
  | otherwise = Right ImportEvidence {identity, appliedAt, strength, payloadChecksum, details}

-- | Associate one target migration with evidence and payload semantics.
historyMapping :: MigrationId -> EvidenceRequirement -> PayloadRelation -> HistoryMapping
historyMapping target requirement payload = HistoryMapping {target, requirement, payload}

-- | Inspect the declared payload relationship without exposing record construction.
historyMappingPayloadRelation :: HistoryMapping -> PayloadRelation
historyMappingPayloadRelation HistoryMapping {payload} = payload

-- | Validate a non-empty state-validation diagnostic.
stateValidationError :: Text -> Either HistoryDefinitionError StateValidationError
stateValidationError value
  | Text.null (Text.strip value) = Left EmptyStateValidationError
  | otherwise = Right (StateValidationError value)

-- | Define read-only state evidence produced under the importer transaction mode.
stateValidator ::
  EvidenceKey ->
  Transaction.Transaction (Either StateValidationError Value) ->
  StateValidator
stateValidator validatorEvidenceKey runStateValidator =
  StateValidator {validatorEvidenceKey, runStateValidator}

-- | Validate a complete source history import definition.
historyImport ::
  Text ->
  Map EvidenceKey ImportEvidence ->
  [StateValidator] ->
  NonEmpty HistoryMapping ->
  Text ->
  Either HistoryDefinitionError HistoryImport
historyImport source evidence validators mappings reason = do
  when (Text.null (Text.strip source)) (Left EmptyHistorySource)
  when (Text.null (Text.strip reason)) (Left EmptyHistoryReason)
  validateUnique validatorEvidenceKey DuplicateStateValidator validators
  for_ validators $ \validator ->
    when
      (Map.member (validatorEvidenceKey validator) evidence)
      (Left (EvidenceKeyCollision (validatorEvidenceKey validator)))
  validateUnique target DuplicateHistoryTarget (toList mappings)
  let knownKeys = Map.keysSet evidence <> Set.fromList (validatorEvidenceKey <$> validators)
  for_ mappings $ \mapping -> do
    validateRequirementReferences knownKeys (requirement mapping)
    case payload mapping of
      SamePayload key ->
        unless (requirementContains key (requirement mapping)) (Left (SamePayloadEvidenceNotRequired key))
      EquivalentState -> Right ()
  Right HistoryImport {source, evidence, validators, mappings, reason}

validateUnique ::
  (Ord key) =>
  (value -> key) ->
  (key -> HistoryDefinitionError) ->
  [value] ->
  Either HistoryDefinitionError ()
validateUnique keyOf duplicateError = go Set.empty
  where
    go _ [] = Right ()
    go seen (value : rest)
      | Set.member key seen = Left (duplicateError key)
      | otherwise = go (Set.insert key seen) rest
      where
        key = keyOf value

validateRequirementReferences ::
  Set EvidenceKey ->
  EvidenceRequirement ->
  Either HistoryDefinitionError ()
validateRequirementReferences knownKeys requirement =
  case requirement of
    Evidence key
      | Set.member key knownKeys -> Right ()
      | otherwise -> Left (UnknownRequirementEvidence key)
    AllOf requirements -> traverse_ (validateRequirementReferences knownKeys) requirements
    AnyOf requirements -> traverse_ (validateRequirementReferences knownKeys) requirements

requirementContains :: EvidenceKey -> EvidenceRequirement -> Bool
requirementContains wanted = \case
  Evidence key -> key == wanted
  AllOf requirements -> any (requirementContains wanted) requirements
  AnyOf requirements -> any (requirementContains wanted) requirements

-- | Use strict runner defaults and reject state-equivalent history.
defaultImportOptions :: ImportOptions
defaultImportOptions =
  ImportOptions
    { importRunOptions = defaultRunOptions,
      equivalentHistoryPolicy = RejectEquivalentHistory
    }

-- | Select the equivalent-history policy.
withEquivalentHistory :: EquivalentHistoryPolicy -> ImportOptions -> ImportOptions
withEquivalentHistory equivalentHistoryPolicy options = options {equivalentHistoryPolicy}

-- | Select the runner lock, timeout, ledger, and event configuration.
withImportRunOptions :: RunOptions -> ImportOptions -> ImportOptions
withImportRunOptions importRunOptions options = options {importRunOptions}

-- | Inspect the configured equivalent-history policy.
importEquivalentHistoryPolicy :: ImportOptions -> EquivalentHistoryPolicy
importEquivalentHistoryPolicy ImportOptions {equivalentHistoryPolicy} = equivalentHistoryPolicy
