# flake-parts module: nix-unit check for the bake test suite.
{ ... }:
{
  perSystem =
    { pkgs, inputs', ... }:
    {
      checks.tests =
        pkgs.runCommand "bake-tests"
          {
            nativeBuildInputs = [ inputs'.nix-unit.packages.default ];
            src = ../.;
          }
          ''
            export HOME=$(mktemp -d)
            cp -r $src/. ./repo
            chmod -R u+w ./repo
            nix-unit --eval-store "$HOME" ./repo/tests/default.nix
            touch $out
          '';
    };
}
