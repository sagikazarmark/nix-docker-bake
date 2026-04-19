{
  description = "Nix library for producing docker-bake.json files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    systems.url = "github:nix-systems/default";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-unit = {
      url = "github:nix-community/nix-unit";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    let
      bakeLib = import ./lib { };
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.nix-unit.modules.flake.default
      ];

      flake = {
        lib = bakeLib;

        overlays.default = _final: _prev: {
          bake = {
            lib = bakeLib;
          };
        };

        templates.default = {
          path = ./templates/default;
          description = "A minimal docker-bake project using nix-docker-bake";
        };
      };

      perSystem =
        {
          pkgs,
          config,
          inputs',
          self',
          ...
        }:
        {
          treefmt = {
            projectRootFile = "flake.nix";

            programs.nixfmt.enable = true;
          };

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

            tests = import ./tests { bake = bakeLib; };
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
                    --file ${./lib/core.nix}

                  echo

                  nixdoc --category "scope" \
                    --description "Scope aggregation and bake file generation." \
                    --file ${./lib/scope.nix}

                  echo

                  nixdoc --category "describe" \
                    --description "Debugging helpers." \
                    --file ${./lib/describe.nix}
                } > $out
              '';

          checks.api-docs =
            pkgs.runCommand "bake-api-docs-drift"
              {
                nativeBuildInputs = [ pkgs.diffutils ];
              }
              ''
                if ! diff -u ${./API.md} ${self'.packages.api-docs}; then
                  echo "API.md is out of date. Run 'nix build .#api-docs && cp result API.md' and commit."
                  exit 1
                fi
                touch $out
              '';

          devShells.default = pkgs.mkShellNoCC {
            packages = [
              config.treefmt.build.wrapper

              pkgs.nixd
              pkgs.nixdoc

              inputs'.nix-unit.packages.default
            ];
          };
        };
    };
}
