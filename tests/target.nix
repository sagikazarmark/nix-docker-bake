{ bake, ... }:
let
  inherit (bake) mkTarget;

  t1 = mkTarget { context = ./.; };
  t2 = mkTarget {
    context = ./foo;
    dockerfile = "Dockerfile.alt";
    target = "base";
    args = {
      FOO = "bar";
    };
    tags = [ "test" ];
    platforms = [ "linux/arm64" ];
    contexts = {
      root = "docker-image://example";
    };
  };
  t3 = t2 // {
    target = "ready";
  };

  baseTarget = mkTarget {
    context = ./.;
    args = {
      A = "1";
      B = "2";
    };
  };

  # Function form: merge by referencing old values.
  mergedArgs = baseTarget.overrideAttrs (old: {
    args = old.args // {
      B = "x";
      C = "3";
    };
  });

  # Function form: pure replacement (ignore old).
  replacedArgs = baseTarget.overrideAttrs (_: {
    args = {
      Z = "9";
    };
  });

  # Attrset form: shorthand for replacement (no `old` access).
  shorthandReplaced = baseTarget.overrideAttrs {
    args = {
      Z = "9";
    };
  };

  # Function form: append to a list — only expressible with access to `old`.
  withExtraTag =
    let
      base = mkTarget {
        context = ./.;
        tags = [ "a" ];
      };
    in
    base.overrideAttrs (old: {
      tags = old.tags ++ [ "b" ];
    });

  # Chaining: each call returns a target with its own overrideAttrs.
  chained =
    (baseTarget.overrideAttrs (_: {
      args = {
        X = "1";
      };
    })).overrideAttrs
      (old: {
        args = old.args // {
          Y = "2";
        };
      });

  withCtx = mkTarget {
    context = ./.;
    contexts = {
      root = "base";
      config = "x";
    };
  };
  mergedCtx = withCtx.overrideAttrs (old: {
    contexts = old.contexts // {
      root = "override";
      extra = "new";
    };
  });
in
{
  # ---------- mkTarget ----------

  testMkTargetDefaultsDockerfile = {
    expr = t1.dockerfile;
    expected = "Dockerfile";
  };

  testMkTargetPreservesContext = {
    expr = t1.context;
    expected = ./.;
  };

  testMkTargetPreservesExplicitDockerfile = {
    expr = t2.dockerfile;
    expected = "Dockerfile.alt";
  };

  testMkTargetPreservesTarget = {
    expr = t2.target;
    expected = "base";
  };

  testMkTargetPreservesArgs = {
    expr = t2.args.FOO;
    expected = "bar";
  };

  testMkTargetPreservesPlatforms = {
    expr = t2.platforms;
    expected = [ "linux/arm64" ];
  };

  testMkTargetDoesNotDefaultPlatforms = {
    expr = t1 ? platforms;
    expected = false;
  };

  testMkTargetRawUpdatePreservesTarget = {
    expr = t3.target;
    expected = "ready";
  };

  testMkTargetRawUpdatePreservesArgs = {
    expr = t3.args.FOO;
    expected = "bar";
  };

  testMkTargetRawUpdatePreservesOverrideAttrs = {
    expr =
      (t3.overrideAttrs (_: {
        tags = [ "x" ];
      })).tags;
    expected = [ "x" ];
  };

  testMkTargetRejectsUnknownKeys = {
    expr =
      (builtins.tryEval (mkTarget {
        context = ./.;
        dockerrfile = "Dockerfile.x"; # typo
      })).success;
    expected = false;
  };

  testMkTargetAcceptsPassthru = {
    expr =
      (mkTarget {
        context = ./.;
        passthru = {
          pushRef = "oci://example/x:abc";
        };
      }).passthru.pushRef;
    expected = "oci://example/x:abc";
  };

  # ---------- overrideAttrs ----------

  testOverrideAttrsMergePreservesExistingArg = {
    expr = mergedArgs.args.A;
    expected = "1";
  };

  testOverrideAttrsMergeOverridesArg = {
    expr = mergedArgs.args.B;
    expected = "x";
  };

  testOverrideAttrsMergeAddsArg = {
    expr = mergedArgs.args.C;
    expected = "3";
  };

  testOverrideAttrsReplaceDropsOldArgs = {
    expr = replacedArgs.args ? A;
    expected = false;
  };

  testOverrideAttrsReplaceSetsNewArgs = {
    expr = replacedArgs.args.Z;
    expected = "9";
  };

  testOverrideAttrsAttrsetFormIsShorthand = {
    expr = shorthandReplaced.args;
    expected = {
      Z = "9";
    };
  };

  testOverrideAttrsAppendsToTags = {
    expr = withExtraTag.tags;
    expected = [
      "a"
      "b"
    ];
  };

  testOverrideAttrsChainable = {
    expr = chained.args;
    expected = {
      X = "1";
      Y = "2";
    };
  };

  testOverrideAttrsMergesContextsOverride = {
    expr = mergedCtx.contexts.root;
    expected = "override";
  };

  testOverrideAttrsMergesContextsPreserve = {
    expr = mergedCtx.contexts.config;
    expected = "x";
  };

  testOverrideAttrsMergesContextsAdd = {
    expr = mergedCtx.contexts.extra;
    expected = "new";
  };

  testOverrideAttrsRejectsUnknownKeys = {
    expr =
      (builtins.tryEval (
        baseTarget.overrideAttrs {
          foo = "bar";
        }
      )).success;
    expected = false;
  };

  testOverrideAttrsPreservesPassthruWhenNotTouched =
    let
      base = mkTarget {
        context = ./.;
        passthru = {
          pushRef = "oci://example/x:abc";
        };
      };
      patched = base.overrideAttrs (_: {
        tags = [ "t" ];
      });
    in
    {
      expr = patched.passthru.pushRef;
      expected = "oci://example/x:abc";
    };

  testOverrideAttrsReplacesPassthruWholesale =
    let
      base = mkTarget {
        context = ./.;
        passthru = {
          a = "1";
          b = "2";
        };
      };
      patched = base.overrideAttrs (_: {
        passthru = {
          b = "x";
        };
      });
    in
    {
      expr = patched.passthru;
      expected = {
        b = "x";
      };
    };

  testOverrideAttrsMergesPassthruViaOld =
    let
      base = mkTarget {
        context = ./.;
        passthru = {
          a = "1";
          b = "2";
        };
      };
      patched = base.overrideAttrs (old: {
        passthru = old.passthru // {
          b = "x";
        };
      });
    in
    {
      expr = patched.passthru;
      expected = {
        a = "1";
        b = "x";
      };
    };
}
