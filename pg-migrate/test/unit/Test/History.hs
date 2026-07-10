module Test.History (tests) where

import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Internal
  ( ResolvedHistoryMapping (..),
    resolveHistoryImport,
    stateVerifiedEvidence,
  )
import PgMigrate.Prelude ()
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "history"
    [ testCase "evidence keys are non-empty" testEvidenceKey,
      testCase "static evidence identities are non-empty" testEvidenceIdentity,
      testCase "imports require source and reason" testSourceAndReason,
      testCase "state validators cannot collide with static evidence" testValidatorCollision,
      testCase "mapping targets are unique" testUniqueTargets,
      testCase "requirements reference known evidence" testKnownRequirement,
      testCase "same-payload evidence participates in its requirement" testSamePayloadRequirement,
      testCase "equivalent history is rejected by default" testEquivalentDefault,
      testCase "same-payload prefixes resolve from target metadata" testResolvePrefix,
      testCase "each affected component resolves its own prefix" testMultiComponentPrefix,
      testCase "component gaps are rejected" testPrefixGap,
      testCase "unknown targets are rejected" testUnknownTarget,
      testCase "payload checksum mismatches are rejected" testChecksumMismatch,
      testCase "same-payload cannot import Haskell migrations" testHaskellSamePayload,
      testCase "equivalent state requires policy and verified evidence" testEquivalentState,
      testCase "multiple satisfied AnyOf branches are ambiguous" testAmbiguousRequirement
    ]

testEvidenceKey :: IO ()
testEvidenceKey = do
  evidenceKey " " @?= Left EmptyEvidenceKey
  evidenceKey "legacy:0001" @?= Right (requireEvidenceKey "legacy:0001")

testEvidenceIdentity :: IO ()
testEvidenceIdentity =
  ledgerOnlyEvidence "" Nothing Nothing Aeson.Null @?= Left EmptyEvidenceIdentity

testSourceAndReason :: IO ()
testSourceAndReason = do
  assertDefinitionError EmptyHistorySource (historyImport "" evidenceMap [] (mapping :| []) "reason")
  assertDefinitionError EmptyHistoryReason (historyImport "source" evidenceMap [] (mapping :| []) " ")

testValidatorCollision :: IO ()
testValidatorCollision =
  assertDefinitionError
    (EvidenceKeyCollision key)
    ( historyImport
        "source"
        evidenceMap
        [stateValidator key (pure (Right Aeson.Null))]
        (mapping :| [])
        "reason"
    )

testUniqueTargets :: IO ()
testUniqueTargets =
  assertDefinitionError
    (DuplicateHistoryTarget targetId)
    (historyImport "source" evidenceMap [] (mapping :| [mapping]) "reason")

testKnownRequirement :: IO ()
testKnownRequirement =
  assertDefinitionError
    (UnknownRequirementEvidence unknownKey)
    ( historyImport
        "source"
        evidenceMap
        []
        (historyMapping targetId (Evidence unknownKey) (SamePayload unknownKey) :| [])
        "reason"
    )

testSamePayloadRequirement :: IO ()
testSamePayloadRequirement =
  assertDefinitionError
    (SamePayloadEvidenceNotRequired otherKey)
    ( historyImport
        "source"
        evidenceWithOther
        []
        (historyMapping targetId (Evidence key) (SamePayload otherKey) :| [])
        "reason"
    )
  where
    otherKey = requireEvidenceKey "legacy:other"
    evidenceWithOther = Map.fromList [(key, staticEvidence), (otherKey, staticEvidence)]

testEquivalentDefault :: IO ()
testEquivalentDefault =
  importEquivalentHistoryPolicy defaultImportOptions @?= RejectEquivalentHistory

testResolvePrefix :: IO ()
testResolvePrefix = do
  let imported = requireHistoryImport prefixEvidence [prefixMapping 1, prefixMapping 2] []
  resolved <- requireValidationRight (resolveHistoryImport RejectEquivalentHistory prefixPlan prefixEvidence imported)
  (resolvedPosition <$> resolved) @?= (1 :| [2])
  (resolvedChecksum <$> resolved)
    @?= (migrationFingerprint "SELECT 1" :| [migrationFingerprint "SELECT 2"])

testMultiComponentPrefix :: IO ()
testMultiComponentPrefix = do
  let firstKey = requireEvidenceKey "legacy:first"
      secondKey = requireEvidenceKey "legacy:second"
      firstTarget = requireRight (migrationId "history-first" "0001-one")
      secondTarget = requireRight (migrationId "history-second" "0001-one")
      firstChecksum = migrationFingerprint "SELECT 'first'"
      secondChecksum = migrationFingerprint "SELECT 'second'"
      available =
        Map.fromList
          [ (firstKey, requireRight (sourceManifestVerifiedEvidence "first" Nothing (Just firstChecksum) Aeson.Null)),
            (secondKey, requireRight (sourceManifestVerifiedEvidence "second" Nothing (Just secondChecksum) Aeson.Null))
          ]
      imported =
        requireRight
          ( historyImport
              "legacy"
              available
              []
              ( historyMapping firstTarget (Evidence firstKey) (SamePayload firstKey)
                  :| [historyMapping secondTarget (Evidence secondKey) (SamePayload secondKey)]
              )
              "cutover"
          )
      firstComponent =
        requireRight
          ( migrationComponent
              "history-first"
              Set.empty
              (requireRight (sqlMigration "0001-one" "SELECT 'first'") :| [])
          )
      secondComponent =
        requireRight
          ( migrationComponent
              "history-second"
              Set.empty
              (requireRight (sqlMigration "0001-one" "SELECT 'second'") :| [])
          )
      plan = requireRight (migrationPlan (firstComponent :| [secondComponent]))
  resolved <- requireValidationRight (resolveHistoryImport RejectEquivalentHistory plan available imported)
  (resolvedPosition <$> resolved) @?= (1 :| [1])

testPrefixGap :: IO ()
testPrefixGap = do
  let imported = requireHistoryImport prefixEvidence [prefixMapping 1, prefixMapping 3] []
  resolveHistoryImport RejectEquivalentHistory prefixPlan prefixEvidence imported
    @?= Left (HistoryComponentPrefixGap (requireRight (componentName "history-prefix")) 2)

testUnknownTarget :: IO ()
testUnknownTarget = do
  let unknown = requireRight (migrationId "history-prefix" "9999-unknown")
      imported =
        requireRight
          ( historyImport
              "legacy"
              prefixEvidence
              []
              (historyMapping unknown (Evidence (prefixKey 1)) (SamePayload (prefixKey 1)) :| [])
              "cutover"
          )
  resolveHistoryImport RejectEquivalentHistory prefixPlan prefixEvidence imported
    @?= Left (HistoryTargetUnknown unknown)

testChecksumMismatch :: IO ()
testChecksumMismatch = do
  let mismatchedEvidence =
        Map.singleton
          (prefixKey 1)
          ( requireRight
              ( sourceManifestVerifiedEvidence
                  "legacy/0001.sql"
                  Nothing
                  (Just (migrationFingerprint "SELECT changed"))
                  Aeson.Null
              )
          )
      imported = requireHistoryImport mismatchedEvidence [prefixMapping 1] []
  resolveHistoryImport RejectEquivalentHistory prefixPlan mismatchedEvidence imported
    @?= Left (HistoryPayloadChecksumMismatch (prefixTarget 1) (prefixKey 1))

testHaskellSamePayload :: IO ()
testHaskellSamePayload = do
  let target = requireRight (migrationId "history-haskell" "0001-action")
      checksum = migrationFingerprint "haskell-v1"
      sourceEvidence =
        Map.singleton
          key
          (requireRight (sourceManifestVerifiedEvidence "legacy-action" Nothing (Just checksum) Aeson.Null))
      imported =
        requireRight
          ( historyImport
              "legacy"
              sourceEvidence
              []
              (historyMapping target (Evidence key) (SamePayload key) :| [])
              "cutover"
          )
      migration = requireRight (transactionMigration "0001-action" checksum (pure ()))
      component = requireRight (migrationComponent "history-haskell" Set.empty (migration :| []))
      plan = requireRight (migrationPlan (component :| []))
  resolveHistoryImport RejectEquivalentHistory plan sourceEvidence imported
    @?= Left (HistorySamePayloadForHaskell target)

testEquivalentState :: IO ()
testEquivalentState = do
  let target = prefixTarget 1
      verified = stateVerifiedEvidence key (Aeson.object ["table" Aeson..= ("ready" :: Text)])
      available = Map.singleton key verified
      validator = stateValidator key (pure (Right Aeson.Null))
      imported =
        requireRight
          ( historyImport
              "legacy"
              Map.empty
              [validator]
              (historyMapping target (Evidence key) EquivalentState :| [])
              "cutover"
          )
  resolveHistoryImport RejectEquivalentHistory prefixPlan available imported
    @?= Left (HistoryEquivalentStateDisallowed target)
  _ <- requireValidationRight (resolveHistoryImport AllowEquivalentHistory prefixPlan available imported)
  pure ()

testAmbiguousRequirement :: IO ()
testAmbiguousRequirement = do
  let secondKey = requireEvidenceKey "legacy:second"
      available = Map.fromList [(key, prefixEvidence Map.! prefixKey 1), (secondKey, prefixEvidence Map.! prefixKey 1)]
      target = prefixTarget 1
      imported =
        requireRight
          ( historyImport
              "legacy"
              available
              []
              ( historyMapping
                  target
                  (AnyOf (Evidence key :| [Evidence secondKey]))
                  (SamePayload key)
                  :| []
              )
              "cutover"
          )
  resolveHistoryImport RejectEquivalentHistory prefixPlan available imported
    @?= Left (HistoryRequirementAmbiguous target)

key :: EvidenceKey
key = requireEvidenceKey "legacy:0001"

unknownKey :: EvidenceKey
unknownKey = requireEvidenceKey "legacy:unknown"

targetId :: MigrationId
targetId = requireRight (migrationId "history" "0001")

staticEvidence :: ImportEvidence
staticEvidence =
  requireRight
    (sourceManifestVerifiedEvidence "legacy/0001.sql" Nothing Nothing Aeson.Null)

evidenceMap :: Map.Map EvidenceKey ImportEvidence
evidenceMap = Map.singleton key staticEvidence

mapping :: HistoryMapping
mapping = historyMapping targetId (Evidence key) (SamePayload key)

prefixPlan :: MigrationPlan
prefixPlan =
  requireRight
    ( migrationPlan
        ( requireRight
            ( migrationComponent
                "history-prefix"
                Set.empty
                ( requireRight (sqlMigration "0001-one" "SELECT 1")
                    :| [ requireRight (sqlMigration "0002-two" "SELECT 2"),
                         requireRight (sqlMigration "0003-three" "SELECT 3")
                       ]
                )
            )
            :| []
        )
    )

prefixEvidence :: Map.Map EvidenceKey ImportEvidence
prefixEvidence =
  Map.fromList
    [ ( prefixKey number,
        requireRight
          ( sourceManifestVerifiedEvidence
              ("legacy/000" <> showText number <> ".sql")
              Nothing
              (Just (migrationFingerprint (Text.Encoding.encodeUtf8 ("SELECT " <> showText number))))
              Aeson.Null
          )
      )
    | number <- [1 .. 3]
    ]

prefixKey :: Int -> EvidenceKey
prefixKey number = requireEvidenceKey ("legacy:000" <> showText number)

prefixTarget :: Int -> MigrationId
prefixTarget number =
  requireRight (migrationId "history-prefix" ("000" <> showText number <> "-" <> suffix number))
  where
    suffix 1 = "one"
    suffix 2 = "two"
    suffix _ = "three"

prefixMapping :: Int -> HistoryMapping
prefixMapping number =
  historyMapping
    (prefixTarget number)
    (Evidence (prefixKey number))
    (SamePayload (prefixKey number))

requireHistoryImport ::
  Map.Map EvidenceKey ImportEvidence ->
  [HistoryMapping] ->
  [StateValidator] ->
  HistoryImport
requireHistoryImport available importedMappings importedValidators =
  requireRight
    ( historyImport
        "legacy"
        available
        importedValidators
        (case importedMappings of firstMapping : rest -> firstMapping :| rest; [] -> error "empty mappings")
        "cutover"
    )

showText :: (Show value) => value -> Text
showText = Text.pack . show

requireEvidenceKey :: Text -> EvidenceKey
requireEvidenceKey = requireRight . evidenceKey

requireRight :: (Show error) => Either error value -> value
requireRight = \case
  Left err -> error (show err)
  Right value -> value

assertDefinitionError ::
  HistoryDefinitionError ->
  Either HistoryDefinitionError HistoryImport ->
  IO ()
assertDefinitionError expected = \case
  Left actual -> actual @?= expected
  Right _ -> assertFailure ("expected " <> show expected <> ", received Right")

requireValidationRight ::
  Either HistoryValidationError value ->
  IO value
requireValidationRight = \case
  Left err -> assertFailure (show err) >> error "assertFailure returned"
  Right value -> pure value
