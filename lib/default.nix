# Public entry point for the bake library.
# Usage (external via flake): inputs.bake.lib
{ }:
let
  nixLib = import ./nix-lib.nix;
  core = import ./core.nix;
  serialize = import ./serialize.nix;
  scope = import ./scope.nix { inherit nixLib core serialize; };
  describe = import ./describe.nix;
  apps = import ./apps.nix { inherit scope; };
in
{
  # Target construction and module validation
  inherit (core)
    mkTarget
    checkModule
    mkContext
    mkContextWith
    ;

  # Scope and bake file generation
  inherit (scope) mkScope mkBakeFile;

  # App helpers
  inherit (apps) mkBakeApp;

  # Debugging helpers
  inherit (describe) describeScope;
}
