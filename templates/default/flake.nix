{
  description = "A docker-bake project using nix-docker-bake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    bake.url = "github:sagikazarmark/nix-docker-bake";
  };

  outputs =
    { bake, ... }:
    let
      system = "x86_64-linux";

      scope = bake.lib.mkScope {
        config = { };
        modules = {
          app = ./bake.nix;
        };
      };
    in
    {
      packages.${system}.default = bake.lib.mkBakeFile scope.modules.app;
    };
}
