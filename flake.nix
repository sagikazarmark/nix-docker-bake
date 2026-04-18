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
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import inputs.systems;

      imports = [
        ./nix/lib.nix
        ./nix/overlay.nix
        ./nix/treefmt.nix
      ];

      perSystem =
        { pkgs, ... }:
        {
          checks = {
            tests = pkgs.writeText "bake-tests" (
              import ./tests {
                inherit (pkgs) lib;
                bake = import ./lib { };
              }
            );
          };
        };
    };
}
