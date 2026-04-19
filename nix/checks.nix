# flake-parts module: nix-unit tests and API doc drift check.
{ ... }:
let
  prepRepo = ''
    cp -r $src/. ./repo
    chmod -R u+w ./repo
  '';
in
{
  perSystem =
    { pkgs, inputs', ... }:
    let
      src = pkgs.lib.cleanSource ../.;
    in
    {
      checks.tests =
        pkgs.runCommand "bake-tests"
          {
            inherit src;
            nativeBuildInputs = [ inputs'.nix-unit.packages.default ];
          }
          ''
            export HOME=$(mktemp -d)
            ${prepRepo}
            nix-unit --eval-store "$HOME" ./repo/tests/default.nix
            touch $out
          '';

      checks.api-docs =
        pkgs.runCommand "bake-api-docs"
          {
            inherit src;
            nativeBuildInputs = [
              pkgs.nixdoc
              pkgs.diffutils
            ];
          }
          ''
            ${prepRepo}
            cd ./repo
            bash scripts/gen-api-docs.sh ./api-generated.md
            if ! diff -u API.md ./api-generated.md; then
              echo "API.md is out of date. Run scripts/gen-api-docs.sh and commit."
              exit 1
            fi
            touch $out
          '';
    };
}
