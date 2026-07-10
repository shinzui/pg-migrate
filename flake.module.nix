{ inputs, lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      haskellPackages = pkgs.haskell.packages.ghc9124.override {
        overrides = hself: _hsuper: {
          crypton = pkgs.haskell.lib.dontCheck (
            hself.callHackageDirect
              {
                pkg = "crypton";
                ver = "1.1.2";
                sha256 = "sha256-lkVJJTjyIlSOTpkfPXfKivxGDd0YJLvkWgEOGlnFzVM=";
              }
              { }
          );
          hasql = pkgs.haskell.lib.dontCheck (
            hself.callHackageDirect
              {
                pkg = "hasql";
                ver = "1.10.3.5";
                sha256 = "sha256-HrDp+FRgzhfBgXYwZPeRA18w8FYFFESe1sqOZhQptLs=";
              }
              { }
          );
          hasql-transaction = pkgs.haskell.lib.dontCheck (
            hself.callHackageDirect
              {
                pkg = "hasql-transaction";
                ver = "1.2.2";
                sha256 = "sha256-o53h6ly2Kukhw9dcyAOvywzwlZDdgb+b/jqbw72lLHg=";
              }
              { }
          );
          postgresql-binary = pkgs.haskell.lib.dontCheck (
            hself.callHackageDirect
              {
                pkg = "postgresql-binary";
                ver = "0.15.0.1";
                sha256 = "sha256-q5t2OgiDxyt8WU+zHVxpyVhFF9PtDu2BlQRfuPpBkgk=";
              }
              { }
          );
        };
      };
    in
    {
      packages = lib.mkForce {
        default =
          haskellPackages.callCabal2nix
            "pg-migrate"
            (inputs.self + "/pg-migrate")
            { };
      };
    };
}
