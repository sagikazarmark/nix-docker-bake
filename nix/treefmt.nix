# flake-parts module: configure treefmt-nix with nixfmt for *.nix files.
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem = _: {
    treefmt = {
      projectRootFile = "flake.nix";

      programs.nixfmt.enable = true;
    };
  };
}
