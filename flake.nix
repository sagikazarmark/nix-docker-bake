{
  description = "Nix library for producing docker-bake.json files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );
    in
    {
      lib = import ./lib { };

      checks = forAllSystems (
        { pkgs, ... }:
        {
          tests = pkgs.writeText "bake-tests" (
            import ./tests {
              inherit (pkgs) lib;

              bake = self.lib;
            }
          );
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-tree);
    };
}
