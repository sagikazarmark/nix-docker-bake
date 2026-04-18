# Leaf module: single target, no module dependencies, string context passthrough.
{
  lib,
  defaultRoot,
  platforms,
  ...
}:
let
  main = lib.mkTarget {
    name = "main";
    context = lib.mkContext ./.;
    inherit platforms;
    contexts = {
      root = defaultRoot;
    };
  };
in
{
  targets = {
    inherit main;
  };
  groups = { };
}
