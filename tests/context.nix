{ bake, ... }:
let
  inherit (bake) mkContext;

  # mkContext returns a store path. We can verify the name component.
  ctx = mkContext "mymod" ./.; # current dir as context
  ctxStr = toString ctx;
in
{
  # Store path contains the prefix + basename.
  testMkContextNameContainsPrefix = {
    expr = builtins.match ".*mymod-.*-context.*" ctxStr != null;
    expected = true;
  };

  # Result starts with /nix/store (a valid store path).
  testMkContextIsStorePath = {
    expr = builtins.match "/nix/store/.*" ctxStr != null;
    expected = true;
  };

  # Different paths produce different store hashes.
  testMkContextDifferentPathsDiffer = {
    expr = toString (mkContext "a" ./.) == toString (mkContext "a" ./fixtures);
    expected = false;
  };

  # Same path + same prefix → same store path (deterministic).
  testMkContextDeterministic = {
    expr = toString (mkContext "x" ./.) == toString (mkContext "x" ./.);
    expected = true;
  };
}
