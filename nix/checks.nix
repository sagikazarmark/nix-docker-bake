# flake-parts module: nix-unit tests and API doc drift check.
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

      checks.api-docs =
        pkgs.runCommand "bake-api-docs"
          {
            nativeBuildInputs = [
              pkgs.nixdoc
              pkgs.diffutils
            ];
            src = ../.;
          }
          ''
            cp -r $src/. ./repo
            chmod -R u+w ./repo
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
