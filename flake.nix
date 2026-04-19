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

        ./nix/checks.nix
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
          ...
        }:
        {
          treefmt = {
            projectRootFile = "flake.nix";

            programs.nixfmt.enable = true;
          };

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
