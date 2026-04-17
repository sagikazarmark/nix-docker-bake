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
  };
  groupScope.modules.grp = groupModule;
  serialized8 = serialize groupScope groupModule;

  # ---------- optional top-level keys ----------
  onlyTargetsModule = {
    namespace = "ot";
    targets = {
      main = mkTarget { context = ./ot; };
    };
  };
  onlyTargetsScope.modules.ot = onlyTargetsModule;
  serialized9 = serialize onlyTargetsScope onlyTargetsModule;

  onlyGroupsModule = {
    namespace = "og";
    groups = {
      empty = [ ];
    };
  };
  onlyGroupsScope.modules.og = onlyGroupsModule;
  serialized10 = serialize onlyGroupsScope onlyGroupsModule;

  emptyModule = {
    namespace = "em";
  };
  emptyScope.modules.em = emptyModule;
  serialized11 = serialize emptyScope emptyModule;
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

  # ---------- optional top-level keys ----------
  testSerializeOmitsGroupKeyWhenNoGroups = {
    expr = serialized9 ? group;
    expected = false;
  };

  testSerializeOnlyTargetsKeepsTarget = {
    expr = serialized9.target ? main;
    expected = true;
  };

  testSerializeOmitsTargetKeyWhenNoTargets = {
    expr = serialized10 ? target;
    expected = false;
  };

  testSerializeOnlyGroupsKeepsGroup = {
    expr = serialized10.group.empty.targets;
    expected = [ ];
  };

  testSerializeEmptyModule = {
    expr = serialized11;
    expected = { };
  };
}
