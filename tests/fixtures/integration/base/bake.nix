# Leaf module: single target, no module dependencies, string context passthrough.
{
  lib,
  defaultRoot,
  platforms,
  ...
}:
let
  main = lib.mkTarget {
    context = lib.mkContext ./.;
    inherit platforms;
    contexts = {
      root = defaultRoot;
    };
  };
in
{
  namespace = "base";
  targets = {
    inherit main;
  };
  groups = { };
}
