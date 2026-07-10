{ ... }:
{
  perSystem =
    { pkgs, config, ... }:
    let
      matrixShell = name: postgres:
        config.devShells.ghc9124.overrideAttrs (old: {
          shellHook = ''
            export PATH="${postgres}/bin:$PATH"
            ${old.shellHook or ""}

            export PGHOST="$PWD/.dev/${name}"
            export PGDATA="$PGHOST/data"
            export PGLOG="$PGHOST/postgres.log"
            export PGDATABASE=pg-migrate
            export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x "$PGHOST" '$x|@uri')/$PGDATABASE

            mkdir -p "$PGHOST"
            if [ ! -d "$PGDATA" ]; then
              initdb --auth=trust --no-locale --encoding=UTF8
            fi
          '';
        });
    in
    {
      devShells.postgresql17 = matrixShell "postgresql17" pkgs.postgresql_17;
      devShells.postgresql18 = matrixShell "postgresql18" pkgs.postgresql_18;
    };
}
