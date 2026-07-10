{ inputs, lib, ... }:
{
  perSystem = { pkgs, ... }: {
    packages.default = lib.mkForce (
      pkgs.haskell.packages.ghc9124.callCabal2nix
        "pg-migrate"
        (inputs.self + "/pg-migrate")
        { }
    );
  };
}
