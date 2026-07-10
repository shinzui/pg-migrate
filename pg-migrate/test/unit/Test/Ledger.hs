module Test.Ledger (tests) where

import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate qualified as Migrate
import Database.PostgreSQL.Migrate.Internal
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ledger"
    [ testCase "default configuration is valid" testDefaultConfiguration,
      testCase "custom quoted identifiers are valid" testQuotedIdentifier,
      testCase "empty schema identifiers are rejected" testEmptyIdentifier,
      testCase "NUL schema identifiers are rejected" testNulIdentifier,
      testCase "PostgreSQL's reserved schema prefix is rejected" testReservedIdentifier,
      testCase "schema identifiers use PostgreSQL's byte limit" testIdentifierLength,
      testCase "quoted identifiers escape embedded quotes" testIdentifierQuoting,
      testCase "ledger upgrade paths are ordered and bounded" testUpgradePath,
      testCase "an applied prefix leaves the remainder pending" testAppliedPrefix,
      testCase "comparison reports every immutable metadata mismatch" testMetadataMismatches,
      testCase "running and failed rows remain pending and block progress" testInterruptedRows,
      testCase "duplicate identities and component positions are corrupt" testDuplicateRows,
      testCase "a stored migration after a gap is not a valid prefix" testPrefixGap,
      testCase "unknown history follows the explicit policy" testUnknownPolicy,
      testCase "strict verification rejects every pending migration" testPendingVerification,
      testCase "lenient status preserves unknown rows separately" testLenientStatus
    ]

testDefaultConfiguration :: IO ()
testDefaultConfiguration =
  defaultLedgerConfig @?= requireRight (ledgerConfig "pgmigrate" defaultLockKey)

testQuotedIdentifier :: IO ()
testQuotedIdentifier =
  assertRight (ledgerConfig "application \"migrations\"" 17)

testEmptyIdentifier :: IO ()
testEmptyIdentifier =
  ledgerConfig "" 17
    @?= Left
      InvalidLedgerSchema
        { input = "",
          postgresIdentifierReason = EmptyPostgresIdentifier
        }

testNulIdentifier :: IO ()
testNulIdentifier =
  ledgerConfig "invalid\NULschema" 17
    @?= Left
      InvalidLedgerSchema
        { input = "invalid\NULschema",
          postgresIdentifierReason = PostgresIdentifierContainsNul
        }

testReservedIdentifier :: IO ()
testReservedIdentifier =
  ledgerConfig "pg_custom" 17
    @?= Left
      InvalidLedgerSchema
        { input = "pg_custom",
          postgresIdentifierReason = PostgresIdentifierHasReservedPrefix
        }

testIdentifierLength :: IO ()
testIdentifierLength =
  ledgerConfig tooLong 17
    @?= Left
      InvalidLedgerSchema
        { input = tooLong,
          postgresIdentifierReason =
            PostgresIdentifierTooLong
              { actualBytes = 64,
                maximumBytes = 63
              }
        }
  where
    tooLong = Text.replicate 64 "a"

testIdentifierQuoting :: IO ()
testIdentifierQuoting =
  quotePostgresIdentifier (PostgresIdentifier "application \"migrations\"")
    @?= "\"application \"\"migrations\"\"\""

testUpgradePath :: IO ()
testUpgradePath = do
  ledgerMigrationVersions @?= [1]
  ledgerUpgradePath 0 @?= Right [1]
  ledgerUpgradePath 1 @?= Right []
  ledgerUpgradePath 2
    @?= Left
      LedgerTooNew
        { databaseVersion = 2,
          supportedVersion = currentLedgerVersion
        }

testAppliedPrefix :: IO ()
testAppliedPrefix = do
  let (firstDescription, secondDescription) = twoDescriptions
      firstId = descriptionId firstDescription
      secondId = descriptionId secondDescription
  comparePlanWithLedger
    AllowUnknownMigrations
    twoPlanDescription
    [storedFromDescription Applied firstDescription]
    @?= VerificationReport
      { issues = [],
        appliedMigrations = [firstId],
        pendingMigrations = [secondId],
        unknownMigrations = []
      }

testMetadataMismatches :: IO ()
testMetadataMismatches = do
  let (firstDescription, _) = twoDescriptions
      firstId = descriptionId firstDescription
      expectedChecksum = descriptionChecksum firstDescription
      actualChecksum = migrationFingerprint "changed"
      actual =
        storedMigration
          firstDescription
          2
          actualChecksum
          HaskellKind
          NonTransactional
          Applied
  verificationIssues
    (comparePlanWithLedger AllowUnknownMigrations twoPlanDescription [actual])
    @?= [ MigrationPositionMismatch firstId 1 2,
          MigrationChecksumMismatch firstId expectedChecksum actualChecksum,
          MigrationKindMismatch firstId SqlKind HaskellKind,
          MigrationTransactionModeMismatch firstId Transactional NonTransactional
        ]

testInterruptedRows :: IO ()
testInterruptedRows = do
  let (firstDescription, secondDescription) = twoDescriptions
      firstId = descriptionId firstDescription
      secondId = descriptionId secondDescription
      report =
        comparePlanWithLedger
          AllowUnknownMigrations
          twoPlanDescription
          [ storedFromDescription Running firstDescription,
            storedFromDescription Failed secondDescription
          ]
  verificationIssues report
    @?= [StoredMigrationRunning firstId, StoredMigrationFailed secondId]
  verificationPending report @?= [firstId, secondId]

testDuplicateRows :: IO ()
testDuplicateRows = do
  let (firstDescription, secondDescription) = twoDescriptions
      firstId = descriptionId firstDescription
      owner = requireRight (componentName "owner")
      first = storedFromDescription Applied firstDescription
      secondAtFirstPosition =
        storedMigration
          secondDescription
          1
          (descriptionChecksum secondDescription)
          SqlKind
          Transactional
          Applied
  verificationIssues
    (comparePlanWithLedger AllowUnknownMigrations twoPlanDescription [first, first])
    @?= [DuplicateStoredMigration firstId, DuplicateStoredPosition owner 1]
  verificationIssues
    (comparePlanWithLedger AllowUnknownMigrations twoPlanDescription [first, secondAtFirstPosition])
    @?= [DuplicateStoredPosition owner 1, MigrationPositionMismatch (descriptionId secondDescription) 2 1]

testPrefixGap :: IO ()
testPrefixGap = do
  let (firstDescription, secondDescription) = twoDescriptions
      firstId = descriptionId firstDescription
      secondId = descriptionId secondDescription
  verificationIssues
    ( comparePlanWithLedger
        AllowUnknownMigrations
        twoPlanDescription
        [storedFromDescription Applied secondDescription]
    )
    @?= [AppliedMigrationAfterGap secondId firstId]

testUnknownPolicy :: IO ()
testUnknownPolicy = do
  let unknown = unknownStoredMigration
      unknownId = storedMigrationId unknown
  verificationIssues
    (comparePlanWithLedger RejectUnknownMigrations twoPlanDescription [unknown])
    @?= [UnknownStoredMigration unknownId]
  verificationIssues
    (comparePlanWithLedger AllowUnknownMigrations twoPlanDescription [unknown])
    @?= []

testPendingVerification :: IO ()
testPendingVerification = do
  let (firstDescription, secondDescription) = twoDescriptions
  verificationIssues
    (verifyFromSnapshot twoMigrationPlan LedgerSnapshot {metadata = Nothing, storedMigrations = []})
    @?= [ PendingMigration (descriptionId firstDescription),
          PendingMigration (descriptionId secondDescription)
        ]

testLenientStatus :: IO ()
testLenientStatus =
  case statusFromSnapshot
    twoMigrationPlan
    LedgerSnapshot {metadata = Nothing, storedMigrations = [unknownStoredMigration]} of
    StatusReport {issues, appliedMigrations, pendingMigrations, unknownMigrations} -> do
      issues @?= []
      appliedMigrations @?= []
      pendingMigrations
        @?= [ descriptionId (fst twoDescriptions),
              descriptionId (snd twoDescriptions)
            ]
      unknownMigrations @?= [unknownStoredMigration]

defaultLockKey :: Int64
defaultLockKey = 0x70675F6D69677261

requireRight :: (Show error) => Either error value -> value
requireRight = \case
  Left err -> error (show err)
  Right value -> value

assertRight :: (Show error) => Either error value -> IO ()
assertRight = \case
  Left err -> assertFailure (show err)
  Right _ -> pure ()

twoMigrationPlan :: MigrationPlan
twoMigrationPlan =
  requireRight
    ( migrationPlan
        ( requireRight
            ( migrationComponent
                "owner"
                Set.empty
                ( requireRight (sqlMigration "0001-first" "SELECT 1")
                    :| [requireRight (sqlMigration "0002-second" "SELECT 2")]
                )
            )
            :| []
        )
    )

twoPlanDescription :: PlanDescription
twoPlanDescription = planDescription twoMigrationPlan

twoDescriptions :: (MigrationDescription, MigrationDescription)
twoDescriptions =
  case twoPlanDescription of
    PlanDescription
      ( ComponentDescription
          { migrations = firstDescription :| [secondDescription]
          }
          :| []
        ) -> (firstDescription, secondDescription)
    other -> error ("unexpected test plan: " <> show other)

descriptionId :: MigrationDescription -> MigrationId
descriptionId MigrationDescription {migrationId = identifier} = identifier

descriptionChecksum :: MigrationDescription -> MigrationChecksum
descriptionChecksum MigrationDescription {checksum} = checksum

storedFromDescription :: MigrationStatus -> MigrationDescription -> StoredMigration
storedFromDescription status description@MigrationDescription {position, checksum, kind, transactionMode} =
  storedMigration description position checksum kind transactionMode status

storedMigration ::
  MigrationDescription ->
  Int ->
  MigrationChecksum ->
  MigrationKind ->
  TransactionMode ->
  MigrationStatus ->
  StoredMigration
storedMigration description position checksum kind transactionMode status =
  StoredMigration
    { storedMigrationId = descriptionId description,
      position,
      checksum,
      kind,
      transactionMode,
      status,
      startedAt = testTime,
      finishedAt = if status == Running then Nothing else Just testTime,
      executionTimeMilliseconds = if status == Running then Nothing else Just 0,
      errorMessage = if status == Failed then Just "failed" else Nothing,
      runnerVersion = "test"
    }

unknownStoredMigration :: StoredMigration
unknownStoredMigration =
  StoredMigration
    { storedMigrationId = requireRight (Migrate.migrationId "legacy" "0001"),
      position = 1,
      checksum = migrationFingerprint "legacy",
      kind = SqlKind,
      transactionMode = Transactional,
      status = Applied,
      startedAt = testTime,
      finishedAt = Just testTime,
      executionTimeMilliseconds = Just 0,
      errorMessage = Nothing,
      runnerVersion = "legacy"
    }

verificationIssues :: VerificationReport -> [VerificationIssue]
verificationIssues VerificationReport {issues} = issues

verificationPending :: VerificationReport -> [MigrationId]
verificationPending VerificationReport {pendingMigrations} = pendingMigrations

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 7 10) 0
