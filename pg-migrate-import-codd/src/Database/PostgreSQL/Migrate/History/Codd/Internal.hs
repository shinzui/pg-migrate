{-# OPTIONS_HADDOCK hide #-}

module Database.PostgreSQL.Migrate.History.Codd.Internal
  ( classifyCoddSchema,
    buildCoddEvidence,
    validateCoddRows,
  )
where

import Database.PostgreSQL.Migrate.History.Codd.Import (buildCoddEvidence)
import Database.PostgreSQL.Migrate.History.Codd.Ledger
  ( classifyCoddSchema,
    validateCoddRows,
  )
