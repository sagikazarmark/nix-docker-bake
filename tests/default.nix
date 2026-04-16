{
  lib,
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

  allTests = builtins.foldl' (acc: s: acc // s) { } subjects;

  failures = lib.runTests allTests;
in
if failures == [ ] then
  "all tests passed (${toString (builtins.length (builtins.attrNames allTests))} assertions)"
else
  throw "test failures:\n${builtins.toJSON failures}"
