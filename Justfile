create-database:
    psql --dbname postgres --set ON_ERROR_STOP=1 --set database="$PGDATABASE" --file scripts/create-database.sql

format:
    nix fmt

unit:
    cabal test pg-migrate:pg-migrate-unit

test:
    cabal test all
