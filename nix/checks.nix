# flake-parts module: nix-unit tests and API doc drift check.
{ inputs, ... }:
{
  imports = [ inputs.nix-unit.modules.flake.default ];

  perSystem =
    { pkgs, ... }:
    {
      nix-unit = {
        inputs = {
          inherit (inputs)
            nixpkgs
            flake-parts
            systems
            treefmt-nix
            nix-unit
            ;
        };

        tests = import ../tests { bake = import ../lib { }; };
      };

      checks.api-docs =
        pkgs.runCommand "bake-api-docs"
          {
            src = pkgs.lib.cleanSource ../.;
            nativeBuildInputs = [
              pkgs.nixdoc
              pkgs.diffutils
            ];
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
