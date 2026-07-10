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

newtype EvidenceKey = EvidenceKey
  { unEvidenceKey :: Text
  }
  deriving stock (Generic, Eq, Ord, Show)

data EvidenceStrength
  = LedgerOnly
  | SourceManifestVerified
  | SourceLedgerChecksumVerified
  | StateVerified
  deriving stock (Generic, Eq, Ord, Show)

data SourceTimestamp
  = AbsoluteTime !UTCTime
  | LocalTimeWithoutZone !LocalTime
  deriving stock (Generic, Eq, Ord, Show)

data ImportEvidence = ImportEvidence
  { identity :: !Text,
    appliedAt :: !(Maybe SourceTimestamp),
    strength :: !EvidenceStrength,
    payloadChecksum :: !(Maybe MigrationChecksum),
    details :: !Value
  }
  deriving stock (Generic, Eq, Show)

data EvidenceRequirement
  = Evidence !EvidenceKey
  | AllOf !(NonEmpty EvidenceRequirement)
  | AnyOf !(NonEmpty EvidenceRequirement)
  deriving stock (Generic, Eq, Show)

data PayloadRelation
  = SamePayload !EvidenceKey
  | EquivalentState
  deriving stock (Generic, Eq, Show)

data HistoryMapping = HistoryMapping
  { target :: !MigrationId,
    requirement :: !EvidenceRequirement,
    payload :: !PayloadRelation
  }
  deriving stock (Generic, Eq, Show)

newtype StateValidationError = StateValidationError
  { stateValidationErrorText :: Text
  }
  deriving stock (Generic, Eq, Show)

data StateValidator = StateValidator
  { validatorEvidenceKey :: !EvidenceKey,
    runStateValidator :: !(Transaction.Transaction (Either StateValidationError Value))
  }

data HistoryImport = HistoryImport
  { source :: !Text,
    evidence :: !(Map EvidenceKey ImportEvidence),
    validators :: ![StateValidator],
    mappings :: !(NonEmpty HistoryMapping),
    reason :: !Text
  }

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

data EquivalentHistoryPolicy
  = RejectEquivalentHistory
  | AllowEquivalentHistory
  deriving stock (Generic, Eq, Ord, Show)

data ImportOptions = ImportOptions
  { importRunOptions :: !RunOptions,
    equivalentHistoryPolicy :: !EquivalentHistoryPolicy
  }

data HistoryImportOutcome
  = Imported
  | AlreadyImported
  deriving stock (Generic, Eq, Ord, Show)

data HistoryImportResult = HistoryImportResult
  { importedMigration :: !MigrationId,
    importOutcome :: !HistoryImportOutcome
  }
  deriving stock (Generic, Eq, Show)

newtype HistoryImportReport = HistoryImportReport
  { importResults :: NonEmpty HistoryImportResult
  }
  deriving stock (Generic, Eq, Show)

data HistoryValidationError
  = HistoryTargetUnknown !MigrationId
  | HistoryComponentPrefixGap !ComponentName !Int
  | HistoryRequirementUnsatisfied !MigrationId
  | HistoryRequirementAmbiguous !MigrationId
  | HistoryPayloadEvidenceMissing !MigrationId !EvidenceKey
  | HistoryPayloadChecksumMissing !MigrationId !EvidenceKey
  | HistoryPayloadChecksumMismatch !MigrationId !EvidenceKey
  | HistorySamePayloadForHaskell !MigrationId
  | HistoryEquivalentStateDisallowed !MigrationId
  | HistoryEquivalentStateUnverified !MigrationId
  deriving stock (Generic, Eq, Show)

data HistoryImportError
  = HistoryImportRunnerError !MigrationError
  | HistoryStateValidationFailed !EvidenceKey !StateValidationError
  | HistoryImportValidationFailed !HistoryValidationError
  | HistoryImportConflict !MigrationId
  | HistoryImportTransitionFailed !MigrationId
  deriving stock (Generic, Show)

evidenceKey :: Text -> Either HistoryDefinitionError EvidenceKey
evidenceKey value
  | Text.null (Text.strip value) = Left EmptyEvidenceKey
  | otherwise = Right (EvidenceKey value)

ledgerOnlyEvidence ::
  Text ->
  Maybe SourceTimestamp ->
  Maybe MigrationChecksum ->
  Value ->
  Either HistoryDefinitionError ImportEvidence
ledgerOnlyEvidence = staticEvidence LedgerOnly

sourceManifestVerifiedEvidence ::
  Text ->
  Maybe SourceTimestamp ->
  Maybe MigrationChecksum ->
  Value ->
  Either HistoryDefinitionError ImportEvidence
sourceManifestVerifiedEvidence = staticEvidence SourceManifestVerified

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

historyMapping :: MigrationId -> EvidenceRequirement -> PayloadRelation -> HistoryMapping
historyMapping target requirement payload = HistoryMapping {target, requirement, payload}

stateValidationError :: Text -> Either HistoryDefinitionError StateValidationError
stateValidationError value
  | Text.null (Text.strip value) = Left EmptyStateValidationError
  | otherwise = Right (StateValidationError value)

stateValidator ::
  EvidenceKey ->
  Transaction.Transaction (Either StateValidationError Value) ->
  StateValidator
stateValidator validatorEvidenceKey runStateValidator =
  StateValidator {validatorEvidenceKey, runStateValidator}

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

defaultImportOptions :: ImportOptions
defaultImportOptions =
  ImportOptions
    { importRunOptions = defaultRunOptions,
      equivalentHistoryPolicy = RejectEquivalentHistory
    }

withEquivalentHistory :: EquivalentHistoryPolicy -> ImportOptions -> ImportOptions
withEquivalentHistory equivalentHistoryPolicy options = options {equivalentHistoryPolicy}

withImportRunOptions :: RunOptions -> ImportOptions -> ImportOptions
withImportRunOptions importRunOptions options = options {importRunOptions}

importEquivalentHistoryPolicy :: ImportOptions -> EquivalentHistoryPolicy
importEquivalentHistoryPolicy ImportOptions {equivalentHistoryPolicy} = equivalentHistoryPolicy
