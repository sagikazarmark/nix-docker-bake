{ bake, ... }:
let
  inherit (bake) mkTarget;
  # Access serialize/contentHash via the internal path; tests are
  # framework-internal.
  internal = import ../lib/serialize.nix;
  inherit (internal) serialize contentHash;

  # Modules in this file are constructed by hand (not via mkScope), so each
  # mkTarget call sets `namespace` explicitly — the per-module curry that
  # normally injects it is bypassed here.

  # ---------- minimal serialize ----------
  minimalTarget = mkTarget {
    name = "main";
    namespace = "test";
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
  serialized5 = serialize minimalModule;

  # ---------- target contexts (synthetic names for anonymous inline targets) ----------
  # Inline target without a `name` — exercises the synthetic-name fallback.
  innerTarget = mkTarget { context = ./inner; };
  outerTarget = mkTarget {
    name = "outer";
    namespace = "cross";
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
  serialized6 = serialize crossModule;

  # ---------- cross-module identity ----------
  sharedTarget = mkTarget {
    name = "shared";
    namespace = "a";
    context = ./shared;
  };
  moduleB = {
    namespace = "b";
    targets = {
      uses = mkTarget {
        name = "uses";
        namespace = "b";
        context = ./uses;
        contexts = {
          root = sharedTarget;
        };
      };
    };
    groups = { };
  };
  serialized7 = serialize moduleB;

  # ---------- groups ----------
  groupTargets = {
    ga = mkTarget {
      name = "ga";
      namespace = "grp";
      context = ./ga;
    };
    gb = mkTarget {
      name = "gb";
      namespace = "grp";
      context = ./gb;
    };
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
  serialized8 = serialize groupModule;

  # ---------- optional top-level keys ----------
  onlyTargetsModule = {
    namespace = "ot";
    targets = {
      main = mkTarget {
        name = "main";
        namespace = "ot";
        context = ./ot;
      };
    };
  };
  serialized9 = serialize onlyTargetsModule;

  onlyGroupsModule = {
    namespace = "og";
    groups = {
      empty = [ ];
    };
  };
  serialized10 = serialize onlyGroupsModule;

  emptyModule = {
    namespace = "em";
  };
  serialized11 = serialize emptyModule;

  # ---------- value-passing identity across distinct mkTarget calls ----------
  # Under the value-self-identifying model, two mkTarget calls with the same
  # `name` and `namespace` resolve to the same wire-format id. The serializer
  # walks the targets attrset first, so a group member whose name matches a
  # registered target resolves to that target's id and does not duplicate it
  # under a synthetic name. This is the semantic replacement for the old
  # fingerprint-matching behavior — same outcome, but driven by the explicit
  # `name` field rather than a structural comparison of attrsets.
  identityTargetA = mkTarget {
    name = "main";
    namespace = "id";
    context = ./shared;
    args.VERSION = "v1";
  };
  identityTargetB = mkTarget {
    name = "main";
    namespace = "id";
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
  serialized12 = serialize identityModule;

  # ---------- duplicate-wire-id detection in groups ----------
  # Under content-addressing, two values with identical content resolve
  # to the same wire id. Listing them both in one group is redundant;
  # the dup check surfaces it as an error rather than silently emitting
  # a group with a repeated member. Same-name-but-different-content
  # values emit distinct `_<ns>_<name>_<hash>` ids and are NOT flagged.
  dupTargetX = mkTarget {
    name = "shared";
    namespace = "dup";
    context = ./x;
  };
  dupTargetY = mkTarget {
    name = "shared";
    namespace = "dup";
    context = ./x;
  };
  dupModule = {
    namespace = "dup";
    targets = { };
    groups = {
      default = [
        dupTargetX
        dupTargetY
      ];
    };
  };

  # ---------- hand-construction safety: target without namespace ----------
  # A target value reaching the serializer with `name` but no `namespace`
  # indicates it was constructed outside the per-module `lib.mkTarget` curry.
  # The serializer throws loudly rather than emitting a wire-format entry
  # under an ambiguous id.
  noNsTarget = mkTarget {
    name = "main";
    # namespace deliberately omitted
    context = ./.;
  };
  noNsModule = {
    namespace = "ns";
    targets = {
      main = noNsTarget;
    };
    groups = { };
  };

  # ---------- content hash properties ----------
  # Baseline target for hash sensitivity/stability checks.
  hashBase = mkTarget {
    name = "base";
    namespace = "h";
    context = ./ctx;
    dockerfile = "Dockerfile";
    args = {
      A = "1";
    };
    tags = [ "t:1" ];
    platforms = [ "linux/amd64" ];
  };
  hashBaseCopy = mkTarget {
    name = "base";
    namespace = "h";
    context = ./ctx;
    dockerfile = "Dockerfile";
    args = {
      A = "1";
    };
    tags = [ "t:1" ];
    platforms = [ "linux/amd64" ];
  };
  # Renaming changes identity metadata only — hash must be unchanged.
  hashRenamed = hashBase // {
    name = "renamed";
    namespace = "other";
  };
  # overrideAttrs patches that only touch identity metadata also must
  # not shift the hash. Guards the code path where the rebuilt target's
  # .overrideAttrs closure itself sits in the target attrset.
  hashOverrideAttrsRenamed = hashBase.overrideAttrs (_: {
    name = "renamed";
    namespace = "other";
  });
  # Context change shifts the hash.
  hashCtxChanged = hashBase.overrideAttrs (_: {
    context = ./ctx-other;
  });
  # Args change shifts the hash.
  hashArgsChanged = hashBase.overrideAttrs (old: {
    args = old.args // {
      A = "2";
    };
  });
  # Dockerfile change shifts the hash.
  hashDockerfileChanged = hashBase.overrideAttrs (_: {
    dockerfile = "Dockerfile.alt";
  });
  # Sub-context change shifts the hash (hashContext recurses into attrset
  # contexts, so changes inside the referenced target propagate).
  hashWithCtxRef = hashBase.overrideAttrs (_: {
    contexts = {
      root = hashBase;
    };
  });
  hashWithCtxRefChangedInner = hashBase.overrideAttrs (_: {
    contexts = {
      root = hashArgsChanged;
    };
  });
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

  # `name` and `namespace` are identity metadata; they must NOT appear in the
  # wire-format target body (only as the attrset key).
  testSerializeOmitsNameFromBody = {
    expr = serialized5.target.main ? name;
    expected = false;
  };

  testSerializeOmitsNamespaceFromBody = {
    expr = serialized5.target.main ? namespace;
    expected = false;
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
  # A foreign target referenced via contexts (not registered under
  # targets.<key> in the entry module) is a second-level target: wire id
  # is `_<namespace>_<name>_<hash>`. Its content hash doesn't match any
  # first-level target in moduleB, so no dedup.
  testSerializeCrossModuleIdentity = {
    expr = serialized7.target.uses.contexts.root;
    expected = "target:_a_shared_${contentHash sharedTarget}";
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

  # ---------- value-passing identity ----------

  # A group member whose value came from a distinct mkTarget call but
  # carries the same `name` as a registered target resolves to the canonical
  # name, not a synthetic fallback. Same observable outcome as the previous
  # fingerprint-match behavior, achieved via explicit identity instead.
  testSerializeGroupResolvesDistinctButEquivalentTarget = {
    expr = serialized12.group.default.targets;
    expected = [ "main" ];
  };

  # No duplicate target entry is emitted when identity resolves correctly.
  testSerializeGroupIdentityDoesNotDuplicateTarget = {
    expr = builtins.attrNames serialized12.target;
    expected = [ "main" ];
  };

  # ---------- duplicate-name detection ----------

  testSerializeRejectsDuplicateNamesInGroup = {
    expr = (builtins.tryEval (builtins.deepSeq (serialize dupModule) null)).success;
    expected = false;
  };

  # ---------- hand-construction safety ----------

  testSerializeRejectsTargetWithoutNamespace = {
    expr = (builtins.tryEval (builtins.deepSeq (serialize noNsModule) null)).success;
    expected = false;
  };

  # ---------- content hash properties ----------

  # Two independently-constructed targets with byte-identical content
  # produce the same hash — deterministic stringification is stable.
  testContentHashIsStable = {
    expr = contentHash hashBase == contentHash hashBaseCopy;
    expected = true;
  };

  # Hash excludes name, namespace, overrideAttrs — these are identity
  # metadata, not content.
  testContentHashIgnoresName = {
    expr = contentHash hashBase == contentHash hashRenamed;
    expected = true;
  };

  testContentHashIgnoresOverrideAttrsIdentityOnly = {
    expr = contentHash hashBase == contentHash hashOverrideAttrsRenamed;
    expected = true;
  };

  # Sensitivity to content-relevant fields.
  testContentHashSensitiveToContext = {
    expr = contentHash hashBase == contentHash hashCtxChanged;
    expected = false;
  };

  testContentHashSensitiveToArgs = {
    expr = contentHash hashBase == contentHash hashArgsChanged;
    expected = false;
  };

  testContentHashSensitiveToDockerfile = {
    expr = contentHash hashBase == contentHash hashDockerfileChanged;
    expected = false;
  };

  # Sub-context changes propagate through recursive hashing.
  testContentHashRecursesIntoSubContexts = {
    expr = contentHash hashWithCtxRef == contentHash hashWithCtxRefChangedInner;
    expected = false;
  };

  # Hash format: 8 hex characters.
  testContentHashShape = {
    expr = builtins.match "[0-9a-f]{8}" (contentHash hashBase) != null;
    expected = true;
  };
}
