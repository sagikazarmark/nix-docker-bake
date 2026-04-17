{ bake, ... }:
let
  inherit (bake) mkTarget extendTarget;

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
  extended = extendTarget baseTarget {
    args = {
      B = "x";
      C = "3";
    };
  };
  extended2 = extendTarget baseTarget { tags = [ "t" ]; };

  withCtx = mkTarget {
    context = ./.;
    contexts = {
      root = "base";
      config = "x";
    };
  };
  extendedCtx = extendTarget withCtx {
    contexts = {
      root = "override";
      extra = "new";
    };
  };
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

  # ---------- extendTarget ----------

  testExtendTargetPreservesExistingArg = {
    expr = extended.args.A;
    expected = "1";
  };

  testExtendTargetOverridesArg = {
    expr = extended.args.B;
    expected = "x";
  };

  testExtendTargetAddsArg = {
    expr = extended.args.C;
    expected = "3";
  };

  testExtendTargetLeavesArgsAloneWhenPatchingOtherFields = {
    expr = extended2.args.A;
    expected = "1";
  };

  testExtendTargetAppliesNonArgFields = {
    expr = extended2.tags;
    expected = [ "t" ];
  };

  testExtendTargetMergesContextsOverride = {
    expr = extendedCtx.contexts.root;
    expected = "override";
  };

  testExtendTargetMergesContextsPreserve = {
    expr = extendedCtx.contexts.config;
    expected = "x";
  };

  testExtendTargetMergesContextsAdd = {
    expr = extendedCtx.contexts.extra;
    expected = "new";
  };

  testExtendTargetPreservesPassthruWhenPatchOmitsIt =
    let
      base = mkTarget {
        context = ./.;
        passthru = {
          pushRef = "oci://example/x:abc";
        };
      };
      patched = extendTarget base { tags = [ "t" ]; };
    in
    {
      expr = patched.passthru.pushRef;
      expected = "oci://example/x:abc";
    };

  testExtendTargetPatchPassthruReplacesBase =
    let
      base = mkTarget {
        context = ./.;
        passthru = {
          a = "1";
          b = "2";
        };
      };
      # `a` is intentionally absent in the result: passthru is replaced
      # wholesale by the patch, not merged like args/contexts.
      patched = extendTarget base {
        passthru = {
          b = "x";
        };
      };
    in
    {
      expr = patched.passthru;
      expected = {
        b = "x";
      };
    };
}
