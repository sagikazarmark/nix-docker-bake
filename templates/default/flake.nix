{
  description = "A docker-bake project using nix-docker-bake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    bake = {
      url = "github:sagikazarmark/nix-docker-bake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      nixpkgs,
      bake,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      scope = bake.lib.mkScope {
        config = { };
        modules = {
          app = ./bake.nix;
        };
      };
    in
    {
      packages.${system}.default = bake.lib.mkBakeFile scope.modules.app;

      apps.${system}.default = bake.lib.mkBakeApp {
        inherit pkgs;
        module = scope.modules.app;
        name = "app";
      };
    };
}
