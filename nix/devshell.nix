# flake-parts module: development shell.
{ ... }:
{
  perSystem =
    {
      pkgs,
      config,
      inputs',
      ...
    }:
    {
      devShells.default = pkgs.mkShellNoCC {
        packages = [
          config.treefmt.build.wrapper

          pkgs.nixd
          pkgs.nixdoc

          inputs'.nix-unit.packages.default
        ];
      };
    };
}
