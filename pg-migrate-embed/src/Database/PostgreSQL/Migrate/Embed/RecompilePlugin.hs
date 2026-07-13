-- | GHC 9.12 recompilation support for strict manifest membership checks.
--
-- Put this pragma in each module that calls @embedMigrationManifest@:
--
-- > {-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}
--
-- GHC 9.12 can track existing files but has no Template Haskell directory-dependency
-- API. This no-op Core plugin forces that embedding module to be reconsidered on every
-- build, allowing a newly added or removed sibling SQL file to rerun manifest validation.
module Database.PostgreSQL.Migrate.Embed.RecompilePlugin (plugin) where

import GHC.Plugins
  ( Plugin (pluginRecompile),
    PluginRecompile (ForceRecompile),
    defaultPlugin,
  )

-- | The compiler plugin entry point. Applications load it with the module-local pragma
-- shown above; application code does not call it.
plugin :: Plugin
plugin =
  defaultPlugin
    { pluginRecompile = const (pure ForceRecompile)
    }
