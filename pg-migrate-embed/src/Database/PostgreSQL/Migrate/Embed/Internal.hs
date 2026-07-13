{-# OPTIONS_HADDOCK hide #-}

module Database.PostgreSQL.Migrate.Embed.Internal
  ( newMigrationWithRename,
    renderNextMigrationName,
    numericPrefix,
    byteStringExpression,
  )
where

import Database.PostgreSQL.Migrate.Embed.Authoring
  ( newMigrationWithRename,
    numericPrefix,
    renderNextMigrationName,
  )
import Database.PostgreSQL.Migrate.Embed.Manifest (byteStringExpression)
