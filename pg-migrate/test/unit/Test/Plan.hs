module Test.Plan (tests) where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Internal
import PgMigrate.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck qualified as QuickCheck

tests :: TestTree
tests =
  testGroup
    "plan"
    [ testCase "explicit plans preserve caller order" testExplicitOrder,
      QuickCheck.testProperty
        "explicit plans preserve every permutation of unrelated components"
        propertyExplicitOrder,
      testCase "duplicate component names have a distinct error" testDuplicateComponent,
      testCase "duplicate local migration names have a distinct error" testDuplicateMigration,
      testCase "identical local names in different components are valid" testLocalNameScope,
      testCase "missing dependencies have a distinct error" testMissingDependency,
      testCase "dependencies after consumers have a distinct error" testInvalidOrder,
      testCase "dependency cycles have a distinct error" testCycle,
      testCase "stable resolution changes only constrained order" testStableResolution,
      testCase "stable resolution is deterministic" testStableResolutionDeterministic,
      testCase "plan descriptions include positions and migration metadata" testDescription
    ]

testExplicitOrder :: IO ()
testExplicitOrder = do
  let queue = makeComponent "queue" Set.empty ["0001"]
      eventStore = makeComponent "event-store" Set.empty ["0001"]
  plan <- requireRight (migrationPlan (queue :| [eventStore]))
  componentNames (planDescription plan)
    @?= requireNames ["queue", "event-store"]

propertyExplicitOrder :: QuickCheck.Property
propertyExplicitOrder =
  QuickCheck.forAll (QuickCheck.shuffle ["alpha", "bravo", "charlie"]) $ \rawNames ->
    let textNames = Text.pack <$> rawNames
        components = fmap (\name -> makeComponent name Set.empty ["0001"]) textNames
     in case NonEmpty.nonEmpty components of
          Nothing -> QuickCheck.property False
          Just nonEmptyComponents ->
            case migrationPlan nonEmptyComponents of
              Left err -> QuickCheck.counterexample (show err) False
              Right plan ->
                componentNames (planDescription plan)
                  QuickCheck.=== requireNames textNames

testDuplicateComponent :: IO ()
testDuplicateComponent = do
  duplicateName <- requireRight (componentName "duplicate")
  assertPlanError
    (DuplicateComponentName duplicateName)
    ( migrationPlan
        ( makeComponent "duplicate" Set.empty ["0001"]
            :| [makeComponent "duplicate" Set.empty ["0002"]]
        )
    )

testDuplicateMigration :: IO ()
testDuplicateMigration = do
  owner <- requireRight (componentName "owner")
  duplicateName <- requireRight (migrationName "0001")
  assertPlanError
    (DuplicateMigrationName owner duplicateName)
    (migrationPlan (makeComponent "owner" Set.empty ["0001", "0001"] :| []))

testLocalNameScope :: IO ()
testLocalNameScope =
  assertRight
    ( migrationPlan
        ( makeComponent "alpha" Set.empty ["0001"]
            :| [makeComponent "bravo" Set.empty ["0001"]]
        )
    )

testMissingDependency :: IO ()
testMissingDependency = do
  consumer <- requireRight (componentName "consumer")
  missing <- requireRight (componentName "missing")
  assertPlanError
    (MissingComponentDependency consumer missing)
    ( migrationPlan
        (makeComponent "consumer" (Set.singleton "missing") ["0001"] :| [])
    )

testInvalidOrder :: IO ()
testInvalidOrder = do
  consumer <- requireRight (componentName "consumer")
  dependency <- requireRight (componentName "dependency")
  assertPlanError
    (DependencyPlacedAfterConsumer consumer dependency)
    ( migrationPlan
        ( makeComponent "consumer" (Set.singleton "dependency") ["0001"]
            :| [makeComponent "dependency" Set.empty ["0001"]]
        )
    )

testCycle :: IO ()
testCycle =
  case migrationPlan
    ( makeComponent "alpha" (Set.singleton "bravo") ["0001"]
        :| [makeComponent "bravo" (Set.singleton "alpha") ["0001"]]
    ) of
    Left (ComponentDependencyCycle _) -> pure ()
    other -> assertFailure ("expected ComponentDependencyCycle, received " <> show other)

testStableResolution :: IO ()
testStableResolution = do
  let queue = makeComponent "queue" Set.empty ["0001"]
      eventStore = makeComponent "event-store" Set.empty ["0001"]
      eventSourcing = makeComponent "event-sourcing" (Set.singleton "event-store") ["0001"]
  plan <- requireRight (resolveMigrationPlan (eventSourcing :| [queue, eventStore]))
  componentNames (planDescription plan)
    @?= requireNames ["queue", "event-store", "event-sourcing"]

testStableResolutionDeterministic :: IO ()
testStableResolutionDeterministic = do
  let queue = makeComponent "queue" Set.empty ["0001"]
      eventStore = makeComponent "event-store" Set.empty ["0001"]
      eventSourcing = makeComponent "event-sourcing" (Set.singleton "event-store") ["0001"]
      input = eventSourcing :| [queue, eventStore]
  firstPlan <- requireRight (resolveMigrationPlan input)
  secondPlan <- requireRight (resolveMigrationPlan input)
  planDescription firstPlan @?= planDescription secondPlan

testDescription :: IO ()
testDescription = do
  let firstMigration = makeMigration "0001"
      secondMigration =
        requireDefinition
          (sessionMigration "0002" (migrationFingerprint "session-v1") (pure ()))
      component = requireDefinition (migrationComponent "owner" Set.empty (firstMigration :| [secondMigration]))
  plan <- requireRight (migrationPlan (component :| []))
  case planDescription plan of
    PlanDescription
      ( ComponentDescription
          { position = 1,
            migrations =
              MigrationDescription
                { position = 1,
                  kind = HaskellKind,
                  transactionMode = Transactional
                }
                :| [ MigrationDescription
                       { position = 2,
                         kind = HaskellKind,
                         transactionMode = NonTransactional
                       }
                     ]
          }
          :| []
        ) -> pure ()
    description -> assertFailure ("unexpected plan description: " <> show description)

componentNames :: PlanDescription -> [ComponentName]
componentNames (PlanDescription descriptions) =
  fmap (\ComponentDescription {name} -> name) (toList descriptions)

requireNames :: [Text] -> [ComponentName]
requireNames = fmap (requireDefinition . componentName)

makeComponent :: Text -> Set Text -> [Text] -> MigrationComponent
makeComponent name dependencies migrationNames =
  case NonEmpty.nonEmpty (makeMigration <$> migrationNames) of
    Nothing -> error "makeComponent requires at least one migration"
    Just migrations -> requireDefinition (migrationComponent name dependencies migrations)

makeMigration :: Text -> Migration
makeMigration name =
  requireDefinition
    (transactionMigration name (migrationFingerprint (Text.Encoding.encodeUtf8 name)) (pure ()))

requireDefinition :: Either DefinitionError value -> value
requireDefinition = \case
  Left err -> error (show err)
  Right value -> value

requireRight :: (Show error) => Either error value -> IO value
requireRight = \case
  Left err -> assertFailure (show err) >> error "assertFailure returned"
  Right value -> pure value

assertRight :: (Show error) => Either error value -> IO ()
assertRight result = do
  _ <- requireRight result
  pure ()

assertPlanError :: PlanError -> Either PlanError MigrationPlan -> IO ()
assertPlanError expected = \case
  Left actual -> actual @?= expected
  Right plan -> assertFailure ("expected Left " <> show expected <> ", received Right " <> show plan)
