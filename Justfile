create-database:
    psql --dbname postgres --set ON_ERROR_STOP=1 --set database="$PGDATABASE" --command "SELECT format('CREATE DATABASE %I', :'database') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'database') \\gexec"

format:
    nix fmt

unit:
    cabal test pg-migrate:pg-migrate-unit

test:
    cabal test all
