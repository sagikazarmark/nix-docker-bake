{ bake, ... }:
let
  inherit (bake) mkTarget;
  # Access serialize via the internal path; tests are framework-internal.
  serialize = (import ../lib/serialize.nix).serialize;

  # ---------- minimal serialize ----------
  minimalTarget = mkTarget {
    context = ./foo;
    platforms = [ "linux/amd64" ];
    args = {
      KEY = "value";
    };
  };
  minimalModule = {
    namespace = "test";
    targets = {
      main = minimalTarget;
    };
    groups = { };
    vars = { };
  };
  minimalScope.modules.test = minimalModule;
  serialized5 = serialize minimalScope minimalModule;

  # ---------- target contexts (synthetic names) ----------
  innerTarget = mkTarget { context = ./inner; };
  outerTarget = mkTarget {
    context = ./outer;
    contexts = {
      root = innerTarget;
    };
  };
  crossModule = {
    namespace = "cross";
    targets = {
      outer = outerTarget;
    };
    groups = { };
    vars = { };
  };
  crossScope.modules.cross = crossModule;
  serialized6 = serialize crossScope crossModule;

  # ---------- cross-module identity ----------
  sharedTarget = mkTarget { context = ./shared; };
  moduleA = {
    namespace = "a";
    targets = {
      shared = sharedTarget;
    };
    groups = { };
    vars = { };
  };
  moduleB = {
    namespace = "b";
    targets = {
      uses = mkTarget {
        context = ./uses;
        contexts = {
          root = sharedTarget;
        };
      };
    };
    groups = { };
    vars = { };
  };
  abScope = {
    modules.a = moduleA;
    modules.b = moduleB;
  };
  serialized7 = serialize abScope moduleB;

  # ---------- groups ----------
  groupTargets = {
    ga = mkTarget { context = ./ga; };
    gb = mkTarget { context = ./gb; };
  };
  groupModule = {
    namespace = "grp";
    targets = groupTargets;
    groups = {
      default = [
        groupTargets.ga
        groupTargets.gb
      ];
    };
    vars = { };
  };
  groupScope.modules.grp = groupModule;
  serialized8 = serialize groupScope groupModule;

  # ---------- variable collection ----------
  varModule = {
    namespace = "v";
    targets = {
      main = mkTarget {
        context = ./.;
        args = {
          FOO = "\${FOO}";
          BAR = "literal";
          lower = "\${lower_var}";
          mixed = "\${MixedCase}";
        };
      };
    };
    groups = { };
    vars = { };
  };
  varScope.modules.v = varModule;
  serialized9 = serialize varScope varModule;
in
{
  # ---------- minimal ----------
  testSerializeEmitsTarget = {
    expr = serialized5.target ? main;
    expected = true;
  };

  testSerializeTargetDockerfile = {
    expr = serialized5.target.main.dockerfile;
    expected = "Dockerfile";
  };

  testSerializeTargetArgs = {
    expr = serialized5.target.main.args.KEY;
    expected = "value";
  };

  testSerializeTargetPlatforms = {
    expr = serialized5.target.main.platforms;
    expected = [ "linux/amd64" ];
  };

  # ---------- target contexts ----------
  testSerializeRewritesContextsToSyntheticName = {
    expr = serialized6.target.outer.contexts.root;
    expected = "target:outer__root";
  };

  testSerializeAddsSyntheticContextTarget = {
    expr = serialized6.target ? "outer__root";
    expected = true;
  };

  # Synthetic context target's path is absolute; verify suffix.
  testSerializeSyntheticContextPathSuffix = {
    expr = builtins.match ".*/inner" serialized6.target.outer__root.context != null;
    expected = true;
  };

  # ---------- cross-module identity ----------
  testSerializeCrossModuleIdentity = {
    expr = serialized7.target.uses.contexts.root;
    expected = "target:a_shared";
  };

  # ---------- groups ----------
  testSerializeGroupTargets = {
    expr = serialized8.group.default.targets;
    expected = [
      "ga"
      "gb"
    ];
  };

  # ---------- variable collection ----------
  testSerializeCollectsTemplateVariable = {
    expr = serialized9.variable ? FOO;
    expected = true;
  };

  testSerializeIgnoresLiteralArg = {
    expr = serialized9.variable ? BAR;
    expected = false;
  };

  testSerializeCollectsLowercaseVariable = {
    expr = serialized9.variable ? lower_var;
    expected = true;
  };

  testSerializeCollectsMixedCaseVariable = {
    expr = serialized9.variable ? MixedCase;
    expected = true;
  };

  testSerializeDoesNotInjectChannel = {
    expr = serialized9.variable ? CHANNEL;
    expected = false;
  };
}
