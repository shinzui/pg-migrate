{-# OPTIONS_HADDOCK hide #-}

module Database.PostgreSQL.Migrate.Embed.Internal
  ( newMigrationWithRename,
    renderNextMigrationName,
    numericPrefix,
  )
where

import Database.PostgreSQL.Migrate.Embed.Authoring
  ( newMigrationWithRename,
    numericPrefix,
    renderNextMigrationName,
  )
