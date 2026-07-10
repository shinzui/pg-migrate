module Test.History (tests) where

import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.PostgreSQL.Migrate
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
      testCase "equivalent history is rejected by default" testEquivalentDefault
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
