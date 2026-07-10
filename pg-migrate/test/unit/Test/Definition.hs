module Test.Definition (tests) where

import Data.ByteString qualified as ByteString
import Data.Set qualified as Set
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
import Database.PostgreSQL.Migrate.Internal (migrationChecksumBytes)
import PgMigrate.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "definition"
    [ testGroup
        "component names"
        (fmap invalidComponentCase invalidIdentifierCases),
      testGroup
        "migration names"
        (fmap invalidMigrationCase invalidIdentifierCases),
      testCase "printable internal spaces are valid" $
        assertRight (componentName "event store"),
      testCase "migration identity validates both names" $
        assertRight (migrationId "event-store" "0001-bootstrap"),
      testCase "SHA-256 uses the exact input bytes" $
        migrationChecksumBytes (migrationFingerprint "abc") @?= sha256Abc,
      testCase "fingerprints are deterministic" $
        migrationFingerprint "version-1" @?= migrationFingerprint "version-1",
      testCase "different fingerprints differ" $
        assertBool
          "different inputs must not share this fingerprint"
          (migrationFingerprint "version-1" /= migrationFingerprint "version-2"),
      testCase "transaction migrations validate their local name" $
        assertDefinitionLeft
          (InvalidMigrationName " bad" IdentifierHasSurroundingWhitespace)
          (transactionMigration " bad" (migrationFingerprint "v1") (pure ())),
      testCase "session migrations validate their local name" $
        assertDefinitionLeft
          (InvalidMigrationName "bad/part" IdentifierContainsSlash)
          (sessionMigration "bad/part" (migrationFingerprint "v1") (pure ())),
      testCase "component dependencies use component-name validation" $
        assertDefinitionLeft
          (InvalidComponentName " invalid" IdentifierHasSurroundingWhitespace)
          ( migrationComponent
              "owner"
              (Set.singleton " invalid")
              (validMigration :| [])
          )
    ]

invalidIdentifierCases :: [(Text, IdentifierError)]
invalidIdentifierCases =
  [ ("", EmptyIdentifier),
    (" event-store", IdentifierHasSurroundingWhitespace),
    ("event-store ", IdentifierHasSurroundingWhitespace),
    ("event/store", IdentifierContainsSlash),
    (Text.replicate 201 "a", IdentifierTooLong 201 200),
    ("event\nstore", IdentifierContainsNonPrintableAscii '\n'),
    ("café", IdentifierContainsNonPrintableAscii 'é')
  ]

invalidComponentCase :: (Text, IdentifierError) -> TestTree
invalidComponentCase (input, reason) =
  testCase (Text.unpack (caseLabel input)) $
    componentName input @?= Left (InvalidComponentName input reason)

invalidMigrationCase :: (Text, IdentifierError) -> TestTree
invalidMigrationCase (input, reason) =
  testCase (Text.unpack (caseLabel input)) $
    migrationName input @?= Left (InvalidMigrationName input reason)

caseLabel :: Text -> Text
caseLabel value
  | Text.null value = "empty"
  | otherwise = Text.pack (show value)

assertRight :: (Show error) => Either error value -> IO ()
assertRight = \case
  Left err -> fail ("expected Right, received Left " <> show err)
  Right _ -> pure ()

assertDefinitionLeft :: DefinitionError -> Either DefinitionError value -> IO ()
assertDefinitionLeft expected = \case
  Left actual -> actual @?= expected
  Right _ -> assertFailure ("expected Left " <> show expected <> ", received Right")

validMigration :: Migration
validMigration =
  case transactionMigration "0001-bootstrap" (migrationFingerprint "v1") (pure ()) of
    Left err -> error (show err)
    Right migration -> migration

sha256Abc :: ByteString
sha256Abc =
  ByteString.pack
    [ 0xBA,
      0x78,
      0x16,
      0xBF,
      0x8F,
      0x01,
      0xCF,
      0xEA,
      0x41,
      0x41,
      0x40,
      0xDE,
      0x5D,
      0xAE,
      0x22,
      0x23,
      0xB0,
      0x03,
      0x61,
      0xA3,
      0x96,
      0x17,
      0x7A,
      0x9C,
      0xB4,
      0x10,
      0xFF,
      0x61,
      0xF2,
      0x00,
      0x15,
      0xAD
    ]
