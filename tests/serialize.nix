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

  # ---------- structural identity across distinct mkTarget calls ----------
  # Two mkTarget invocations with identical inputs produce structurally-equal
  # attrsets except for `overrideAttrs`, which is a fresh closure each call.
  # Identity resolution must match them anyway so group members composed from
  # a re-evaluated module still resolve to their canonical name.
  identityTargetA = mkTarget {
    context = ./shared;
    args.VERSION = "v1";
  };
  identityTargetB = mkTarget {
    context = ./shared;
    args.VERSION = "v1";
  };
  identityModule = {
    namespace = "id";
    targets = {
      main = identityTargetA;
    };
    groups = {
      default = [ identityTargetB ];
    };
  };
  identityScope.modules.id = identityModule;
  serialized12 = serialize identityScope identityModule;

  # ---------- fingerprint-robustness: functions nested inside lists ----------
  # Two targets whose only semantic difference is an opaque function stored
  # inside a list in `passthru`. Distinct closures compare unequal by pointer,
  # so without full function-stripping their fingerprints would differ and
  # identity resolution would fall through to a synthetic name.
  fnListTargetA = mkTarget {
    context = ./fnlist;
    passthru.fns = [ (x: x) ];
  };
  fnListTargetB = mkTarget {
    context = ./fnlist;
    passthru.fns = [ (y: y) ];
  };
  fnListModule = {
    namespace = "fl";
    targets = {
      main = fnListTargetA;
    };
    groups = {
      default = [ fnListTargetB ];
    };
  };
  fnListScope.modules.fl = fnListModule;
  serialized13 = serialize fnListScope fnListModule;
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

  # ---------- structural identity ----------

  # A group member whose value came from a distinct mkTarget call but is
  # otherwise identical to the named target resolves to the canonical name,
  # not a synthetic fallback.
  testSerializeGroupResolvesDistinctButEquivalentTarget = {
    expr = serialized12.group.default.targets;
    expected = [ "main" ];
  };

  # No duplicate target entry is emitted when identity resolves correctly.
  testSerializeGroupIdentityDoesNotDuplicateTarget = {
    expr = builtins.attrNames serialized12.target;
    expected = [ "main" ];
  };

  # Function values buried inside lists (e.g., inside `passthru`) must not
  # leak into the fingerprint. Without recursive function-stripping, distinct
  # closures break structural equality even when every other field matches.
  testSerializeFingerprintIgnoresFunctionsInLists = {
    expr = serialized13.group.default.targets;
    expected = [ "main" ];
  };
}
