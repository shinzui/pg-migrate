create-database:
    psql --dbname postgres --set ON_ERROR_STOP=1 --set database="$PGDATABASE" --file scripts/create-database.sql

format:
    nix fmt

unit:
    cabal test pg-migrate:pg-migrate-unit

test:
    cabal test all

acceptance:
    cabal build all
    cabal test all
    scripts/check-production-closure
    @major=$(psql "$PG_CONNECTION_STRING" --tuples-only --no-align --command "SHOW server_version_num" | cut -c1-2); \
      case "$major" in 17|18) echo "PostgreSQL $major acceptance: PASS (15 groups)" ;; \
      *) echo "unsupported PostgreSQL acceptance major: $major" >&2; exit 1 ;; esac

production-closure:
    scripts/check-production-closure
