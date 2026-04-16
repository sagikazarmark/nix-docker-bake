# Public entry point for the bake library.
# Usage (external via flake): inputs.bake.lib
{ }:
let
  nixLib = import ./nix-lib.nix;
  core = import ./core.nix;
  serialize = import ./serialize.nix;
  scope = import ./scope.nix { inherit nixLib core serialize; };
  describe = import ./describe.nix;
in
{
  # Target construction and module validation
  inherit (core)
    mkTarget
    checkModule
    extendTarget
    mkContext
    ;

  # Scope and bake file generation
  inherit (scope) mkScope mkBakeFile;

  # Nix primitives
  inherit (nixLib) fix extends;

  # Debugging helpers
  inherit (describe) describeScope;
}
