-- mori.dhall
-- Project identity manifest for pg-migrate
-- See: https://github.com/shinzui/mori
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/06588f0a31e97784398f1260bc88321684219908/package.dhall
        sha256:4f9f90bd930eb8d27e8bce70e504d7d366bc302d58a139c9b6874b8c51c952e4

let augDefault =
      { extraDocs = [] : List Schema.DocRef.Type
      , localPathOverride = None Text
      , kind = None Schema.DependencyKind
      , source = None Schema.DependencySource
      , scope = None Schema.DependencyScope
      }

let internalDep =
      \(name : Text) ->
        Schema.Dependency.WithAugmentation
          (augDefault // { name, kind = Some Schema.DependencyKind.Internal })

let thirdPartyDep =
      \(name : Text) ->
        Schema.Dependency.WithAugmentation
          (   augDefault
           // { name
              , kind = Some Schema.DependencyKind.ThirdParty
              , source = Some Schema.DependencySource.Hackage
              }
          )

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "pg-migrate"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , description = Some
          "Hasql-native PostgreSQL migration library: libraries own embedded migration components, applications compose them in explicit order"
      , domains = [ "PostgreSQL", "Migrations", "Backend" ]
      , owners = [ "shinzui" ]
      }
    , repos =
      [ Schema.Repo::{
        , name = "pg-migrate"
        , github = Some "shinzui/pg-migrate"
        , localPath = Some "./"
        }
      ]
    , packages =
      [ Schema.Package::{
        , name = "pg-migrate"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "./pg-migrate"
        , description = Some
            "Stable model, pure plan validation, versioned ledger, Hasql runner, and source-agnostic history importer"
        , dependencies =
          [ thirdPartyDep "hasql"
          , thirdPartyDep "hasql-transaction"
          , thirdPartyDep "aeson"
          , thirdPartyDep "containers"
          , thirdPartyDep "crypton"
          , thirdPartyDep "ram"
          , thirdPartyDep "text"
          , thirdPartyDep "bytestring"
          , thirdPartyDep "time"
          ]
        }
      , Schema.Package::{
        , name = "pg-migrate-embed"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "./pg-migrate-embed"
        , description = Some
            "Template Haskell manifest embedding: compiles ordered SQL manifests into the binary"
        , dependencies =
          [ internalDep "pg-migrate"
          , thirdPartyDep "template-haskell"
          , thirdPartyDep "bytestring"
          ]
        }
      , Schema.Package::{
        , name = "pg-migrate-cli"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "./pg-migrate-cli"
        , description = Some
            "Reusable optparse-applicative parsers and command handlers for service migration executables"
        , dependencies =
          [ internalDep "pg-migrate"
          , internalDep "pg-migrate-embed"
          , thirdPartyDep "aeson"
          , thirdPartyDep "containers"
          , thirdPartyDep "optparse-applicative"
          , thirdPartyDep "hasql"
          , thirdPartyDep "bytestring"
          , thirdPartyDep "text"
          , thirdPartyDep "time"
          ]
        }
      , Schema.Package::{
        , name = "pg-migrate-import-codd"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "./pg-migrate-import-codd"
        , description = Some
            "Optional Codd history-import adapter: reads legacy codd ledgers via Hasql without executing applied migrations"
        , dependencies =
          [ internalDep "pg-migrate"
          , internalDep "pg-migrate-cli"
          , thirdPartyDep "aeson"
          , thirdPartyDep "bytestring"
          , thirdPartyDep "containers"
          , thirdPartyDep "hasql"
          , thirdPartyDep "optparse-applicative"
          , thirdPartyDep "text"
          , thirdPartyDep "time"
          ]
        }
      , Schema.Package::{
        , name = "pg-migrate-import-hasql-migration"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "./pg-migrate-import-hasql-migration"
        , description = Some
            "Optional hasql-migration history-import adapter: reads schema_migrations and verifies legacy MD5 checksums"
        , dependencies =
          [ internalDep "pg-migrate"
          , thirdPartyDep "hasql"
          , thirdPartyDep "optparse-applicative"
          ]
        }
      , Schema.Package::{
        , name = "pg-migrate-test-support"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "./pg-migrate-test-support"
        , description = Some
            "ephemeral-pg-backed test helpers; never enters the production dependency closure"
        , dependencies =
          [ internalDep "pg-migrate"
          , thirdPartyDep "ephemeral-pg"
          , thirdPartyDep "hasql"
          ]
        }
      ]
    , bundles =
      [ Schema.PackageBundle::{
        , name = "pg-migrate-author"
        , description = Some
            "The set a migration-owning library depends on: core plus compile-time embedding"
        , packages = [ "pg-migrate", "pg-migrate-embed" ]
        , primary = "pg-migrate"
        }
      ]
    , dependencies =
      [ "hasql/hasql"
      , "jappeace/ram"
      , "shinzui/hasql-migration"
      , "mzabani/codd"
      , "pcapriotti/optparse-applicative"
      , "shinzui/ephemeral-pg"
      , "shinzui/haskell-jitsurei"
      ]
    , docs =
      [ Schema.DocRef::{
        , key = "initial-spec"
        , kind = Schema.DocKind.Spec
        , audience = Schema.DocAudience.Module
        , description = Some "First releasable version specification"
        , location = Schema.DocLocation.LocalFile "./docs/initial-spec.md"
        }
      , Schema.DocRef::{
        , key = "haskell-standards"
        , kind = Schema.DocKind.BestPractice
        , audience = Schema.DocAudience.Module
        , description = Some
            "Shared Haskell conventions the implementation follows"
        , location =
            Schema.DocLocation.Canonical
              "mori://shinzui/haskell-jitsurei/docs/core-standards"
        }
      ]
    }
