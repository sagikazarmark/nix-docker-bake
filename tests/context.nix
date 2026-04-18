{ bake, ... }:
let
  inherit (bake) mkContext mkContextWith;

  ctx = mkContext ./.;
  ctxStr = toString ctx;
in
{
  # Store-path name carries the source basename.
  testMkContextNameContainsBasename = {
    expr = builtins.match ".*-tests-context.*" ctxStr != null;
    expected = true;
  };

  # Result is a valid store path.
  testMkContextIsStorePath = {
    expr = builtins.match "/nix/store/.*" ctxStr != null;
    expected = true;
  };

  # Different paths produce different store hashes.
  testMkContextDifferentPathsDiffer = {
    expr = toString (mkContext ./.) == toString (mkContext ./fixtures);
    expected = false;
  };

  # Same path → same store path (deterministic).
  testMkContextDeterministic = {
    expr = toString (mkContext ./.) == toString (mkContext ./.);
    expected = true;
  };

  # mkContextWith with no filter is equivalent to mkContext (same store path).
  testMkContextWithNoFilterEqualsMkContext = {
    expr =
      toString (mkContextWith {
        path = ./fixtures;
      }) == toString (mkContext ./fixtures);
    expected = true;
  };

  # Different filters on the same path produce different store hashes.
  testMkContextWithFilterAffectsHash = {
    expr =
      toString (mkContextWith {
        path = ./fixtures;
        filter = _p: _t: true;
      }) == toString (mkContextWith {
        path = ./fixtures;
        filter = p: _t: baseNameOf p != "integration";
      });
    expected = false;
  };

  # Same filter + same path → deterministic store path.
  testMkContextWithDeterministic =
    let
      f = p: _t: baseNameOf p != "integration";
    in
    {
      expr =
        toString (mkContextWith {
          path = ./fixtures;
          filter = f;
        }) == toString (mkContextWith {
          path = ./fixtures;
          filter = f;
        });
      expected = true;
    };
}
