module Database.PostgreSQL.Migrate.Plan
  ( PlanError (..),
    MigrationDescription (..),
    ComponentDescription (..),
    PlanDescription (..),
    migrationPlan,
    resolveMigrationPlan,
    planDescription,
  )
where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate.Types
import PgMigrate.Prelude

data PlanError
  = DuplicateComponentName !ComponentName
  | DuplicateMigrationName !ComponentName !MigrationName
  | MissingComponentDependency !ComponentName !ComponentName
  | DependencyPlacedAfterConsumer !ComponentName !ComponentName
  | ComponentDependencyCycle !(NonEmpty ComponentName)
  deriving stock (Generic, Eq, Show)

data MigrationDescription = MigrationDescription
  { migrationId :: !MigrationId,
    position :: !Int,
    checksum :: !MigrationChecksum,
    kind :: !MigrationKind,
    transactionMode :: !TransactionMode
  }
  deriving stock (Generic, Eq, Show)

data ComponentDescription = ComponentDescription
  { name :: !ComponentName,
    position :: !Int,
    dependencies :: !(Set ComponentName),
    migrations :: !(NonEmpty MigrationDescription)
  }
  deriving stock (Generic, Eq, Show)

newtype PlanDescription = PlanDescription
  { components :: NonEmpty ComponentDescription
  }
  deriving stock (Generic, Eq, Show)

migrationPlan :: NonEmpty MigrationComponent -> Either PlanError MigrationPlan
migrationPlan components = do
  validateUniqueNames components
  validateDependenciesExist components
  _ <- stableTopologicalOrder components
  validateExplicitOrder components
  pure (MigrationPlan components)

resolveMigrationPlan :: NonEmpty MigrationComponent -> Either PlanError MigrationPlan
resolveMigrationPlan components = do
  validateUniqueNames components
  validateDependenciesExist components
  MigrationPlan <$> stableTopologicalOrder components

planDescription :: MigrationPlan -> PlanDescription
planDescription (MigrationPlan components) =
  PlanDescription
    ( NonEmpty.zipWith
        describeComponent
        (1 :| [2 ..])
        components
    )

describeComponent :: Int -> MigrationComponent -> ComponentDescription
describeComponent componentPosition component =
  ComponentDescription
    { name = componentNameOf component,
      position = componentPosition,
      dependencies = componentDependenciesOf component,
      migrations =
        NonEmpty.zipWith
          (describeMigration (componentNameOf component))
          (1 :| [2 ..])
          (componentMigrationsOf component)
    }

describeMigration :: ComponentName -> Int -> Migration -> MigrationDescription
describeMigration component migrationPosition migration =
  MigrationDescription
    { migrationId = MigrationId component (migrationNameOf migration),
      position = migrationPosition,
      checksum = migrationChecksumOf migration,
      kind = migrationKindOf migration,
      transactionMode = migrationModeOf migration
    }

validateUniqueNames :: NonEmpty MigrationComponent -> Either PlanError ()
validateUniqueNames components = do
  case firstDuplicate (componentNameOf <$> toList components) of
    Just duplicate -> Left (DuplicateComponentName duplicate)
    Nothing -> pure ()
  traverse_ validateMigrationNames components

validateMigrationNames :: MigrationComponent -> Either PlanError ()
validateMigrationNames component =
  case firstDuplicate (migrationNameOf <$> toList (componentMigrationsOf component)) of
    Just duplicate -> Left (DuplicateMigrationName (componentNameOf component) duplicate)
    Nothing -> pure ()

validateDependenciesExist :: NonEmpty MigrationComponent -> Either PlanError ()
validateDependenciesExist components =
  traverse_ validateComponent components
  where
    knownNames = Set.fromList (componentNameOf <$> toList components)
    validateComponent component =
      case find (`Set.notMember` knownNames) (Set.toAscList (componentDependenciesOf component)) of
        Just missing -> Left (MissingComponentDependency (componentNameOf component) missing)
        Nothing -> pure ()

validateExplicitOrder :: NonEmpty MigrationComponent -> Either PlanError ()
validateExplicitOrder components =
  traverse_ validateComponent (toList components)
  where
    positions = Map.fromList (zip (componentNameOf <$> toList components) [1 :: Int ..])
    validateComponent component =
      case find (isAfter component) (Set.toAscList (componentDependenciesOf component)) of
        Just dependency -> Left (DependencyPlacedAfterConsumer (componentNameOf component) dependency)
        Nothing -> pure ()
    isAfter component dependency =
      Map.lookup dependency positions > Map.lookup (componentNameOf component) positions

stableTopologicalOrder ::
  NonEmpty MigrationComponent ->
  Either PlanError (NonEmpty MigrationComponent)
stableTopologicalOrder components =
  go Set.empty [] (toList components)
  where
    go _ ordered [] =
      case ordered of
        firstComponent : remainingComponents -> Right (firstComponent :| remainingComponents)
        [] -> error "stableTopologicalOrder: NonEmpty input produced empty output"
    go resolved ordered remaining =
      case removeFirst (dependenciesResolved resolved) remaining of
        Just (next, rest) ->
          go
            (Set.insert (componentNameOf next) resolved)
            (ordered <> [next])
            rest
        Nothing ->
          case componentNameOf <$> remaining of
            firstName : remainingNames -> Left (ComponentDependencyCycle (firstName :| remainingNames))
            [] -> error "stableTopologicalOrder: unresolved set unexpectedly empty"

dependenciesResolved :: Set ComponentName -> MigrationComponent -> Bool
dependenciesResolved resolved component =
  componentDependenciesOf component `Set.isSubsetOf` resolved

removeFirst :: (a -> Bool) -> [a] -> Maybe (a, [a])
removeFirst predicate = go []
  where
    go _ [] = Nothing
    go before (candidate : after)
      | predicate candidate = Just (candidate, reverse before <> after)
      | otherwise = go (candidate : before) after

firstDuplicate :: (Ord a) => [a] -> Maybe a
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (value : rest)
      | value `Set.member` seen = Just value
      | otherwise = go (Set.insert value seen) rest
