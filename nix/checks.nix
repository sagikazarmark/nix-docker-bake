# flake-parts module: nix-unit tests, API doc generation, and drift check.
{ inputs, ... }:
{
  imports = [ inputs.nix-unit.modules.flake.default ];

  perSystem =
    {
      pkgs,
      self',
      ...
    }:
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

      packages.api-docs =
        pkgs.runCommand "bake-api-docs"
          {
            nativeBuildInputs = [ pkgs.nixdoc ];
          }
          ''
            {
              echo "# Bake Library API"
              echo
              echo "> Generated. Do not edit by hand; edit the nixdoc comments in \`lib/*.nix\` and run \`nix build .#api-docs\`."
              echo

              nixdoc --category "core" \
                --description "Target construction and module validation." \
                --file ${../lib/core.nix}

              echo

              nixdoc --category "scope" \
                --description "Scope aggregation and bake file generation." \
                --file ${../lib/scope.nix}

              echo

              nixdoc --category "describe" \
                --description "Debugging helpers." \
                --file ${../lib/describe.nix}
            } > $out
          '';

      checks.api-docs =
        pkgs.runCommand "bake-api-docs-drift"
          {
            nativeBuildInputs = [ pkgs.diffutils ];
          }
          ''
            if ! diff -u ${../API.md} ${self'.packages.api-docs}; then
              echo "API.md is out of date. Run 'nix build .#api-docs && cp result API.md' and commit."
              exit 1
            fi
            touch $out
          '';
    };
}
