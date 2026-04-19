# Aggregate all test subjects into one attrset suitable for nix-unit.
{
  bake ? import ../lib { },
}:
let
  subjects = [
    (import ./target.nix { inherit bake; })
    (import ./context.nix { inherit bake; })
    (import ./check-module.nix { inherit bake; })
    (import ./serialize.nix { inherit bake; })
    (import ./scope.nix { inherit bake; })
    (import ./bake-file.nix { inherit bake; })
    (import ./describe.nix { inherit bake; })
    (import ./integration.nix { inherit bake; })
  ];
in
builtins.foldl' (acc: s: acc // s) { } subjects
