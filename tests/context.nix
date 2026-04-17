{ bake, ... }:
let
  inherit (bake) mkContext mkContextWith;

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

  # mkContextWith with no filter is equivalent to mkContext (same store path).
  testMkContextWithNoFilterEqualsMkContext = {
    expr = toString (mkContextWith "m" { path = ./fixtures; }) == toString (mkContext "m" ./fixtures);
    expected = true;
  };

  # Name component still carries the prefix and basename.
  testMkContextWithNameContainsPrefix = {
    expr =
      builtins.match ".*mymod-.*-context.*" (toString (mkContextWith "mymod" { path = ./fixtures; }))
      != null;
    expected = true;
  };

  # Different filters on the same path produce different store hashes.
  testMkContextWithFilterAffectsHash = {
    expr =
      toString (
        mkContextWith "f" {
          path = ./fixtures;
          filter = _p: _t: true;
        }
      ) == toString (
        mkContextWith "f" {
          path = ./fixtures;
          filter = p: _t: baseNameOf p != "integration";
        }
      );
    expected = false;
  };

  # Same filter + same path + same prefix → deterministic store path.
  testMkContextWithDeterministic =
    let
      f = p: _t: baseNameOf p != "integration";
    in
    {
      expr =
        toString (
          mkContextWith "d" {
            path = ./fixtures;
            filter = f;
          }
        ) == toString (
          mkContextWith "d" {
            path = ./fixtures;
            filter = f;
          }
        );
      expected = true;
    };
}
