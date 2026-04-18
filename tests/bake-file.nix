{ bake, ... }:
let
  inherit (bake) mkScope mkBakeFile;

  moduleFile = builtins.toFile "bake-file-mod.nix" ''
    { lib, myConfigValue, ... }:
    {
      targets = { main = lib.mkTarget { name = "main"; context = ./.; args.VAL = myConfigValue; }; };
      groups = {};
    }
  '';

  scope = mkScope {
    config = {
      myConfigValue = "hello";
    };
    modules.test = moduleFile;
  };

  bakeFilePath = mkBakeFile scope.modules.test;

  parsed = builtins.fromJSON (builtins.readFile bakeFilePath);

  # mkBakeFile must work on a module returned by .override.
  overriddenBakeFile = mkBakeFile (scope.modules.test.override { myConfigValue = "via-override"; });
  parsedOverridden = builtins.fromJSON (builtins.readFile overriddenBakeFile);

  # Chained override: mechanically the same path through mkModule, but
  # assert it so a future refactor cannot silently break the chain case.
  chainedBakeFile = mkBakeFile (
    (scope.modules.test.override { myConfigValue = "first"; }).override {
      myConfigValue = "second";
    }
  );
  parsedChained = builtins.fromJSON (builtins.readFile chainedBakeFile);

  # Module with a group referencing its own targets by value. Under `.override`
  # the module function re-runs — mkTarget produces fresh `overrideAttrs`
  # closures whose pointer identity no longer matches the scope's original
  # targets. Serialization must still resolve group members to their canonical
  # names rather than synthesizing `group__<name>__<i>`.
  groupModuleFile = builtins.toFile "bake-file-group-mod.nix" ''
    { lib, version ? "v1.0.0", ... }:
    let
      main = lib.mkTarget { name = "main"; context = ./.; args.VERSION = version; };
      worker = lib.mkTarget { name = "worker"; context = ./.; args.VERSION = version; };
    in {
      targets = { inherit main worker; };
      groups.default = [ main worker ];
    }
  '';

  groupScope = mkScope {
    config = { };
    modules.demo = groupModuleFile;
  };

  groupBaselineBake = mkBakeFile groupScope.modules.demo;
  groupBaseline = builtins.fromJSON (builtins.readFile groupBaselineBake);

  groupIdentityOverrideBake = mkBakeFile (groupScope.modules.demo.override { version = "v1.0.0"; });
  groupIdentityOverride = builtins.fromJSON (builtins.readFile groupIdentityOverrideBake);

  groupValueOverrideBake = mkBakeFile (groupScope.modules.demo.override { version = "v2.0.0"; });
  groupValueOverride = builtins.fromJSON (builtins.readFile groupValueOverrideBake);

  # Context-reference counterpart of the group-under-override case. Same
  # identity-resolution mechanism, different call site (contexts path rather
  # than groups path). Asserted separately so a future refactor that touches
  # only one path cannot silently regress the other.
  ctxRefModuleFile = builtins.toFile "bake-file-ctxref-mod.nix" ''
    { lib, version ? "v1.0.0", ... }:
    let
      base = lib.mkTarget { name = "base"; context = ./.; args.VERSION = version; };
      derived = lib.mkTarget {
        name = "derived";
        context = ./.;
        args.VERSION = version;
        contexts.base = base;
      };
    in {
      targets = { inherit base derived; };
      groups = {};
    }
  '';

  ctxRefScope = mkScope {
    config = { };
    modules.ctxref = ctxRefModuleFile;
  };

  ctxRefOverrideBake = mkBakeFile (ctxRefScope.modules.ctxref.override { version = "v2.0.0"; });
  ctxRefOverride = builtins.fromJSON (builtins.readFile ctxRefOverrideBake);
in
{
  testMkBakeFileReturnsStorePath = {
    expr = builtins.match "/nix/store/.*-docker-bake.json" (toString bakeFilePath) != null;
    expected = true;
  };

  testMkBakeFileContainsExpectedTargetArgs = {
    expr = parsed.target.main.args.VAL;
    expected = "hello";
  };

  testMkBakeFileWorksOnOverriddenModule = {
    expr = parsedOverridden.target.main.args.VAL;
    expected = "via-override";
  };

  testMkBakeFileWorksOnChainedOverriddenModule = {
    expr = parsedChained.target.main.args.VAL;
    expected = "second";
  };

  # ---------- group identity under .override ----------

  # Baseline: groups in an unoverridden module serialize to canonical target
  # names. Guards against regression of the no-override path.
  testMkBakeFileGroupBaselineUsesCanonicalNames = {
    expr = groupBaseline.group.default.targets;
    expected = [
      "main"
      "worker"
    ];
  };

  testMkBakeFileGroupBaselineHasNoSyntheticTargets = {
    expr = builtins.attrNames groupBaseline.target;
    expected = [
      "main"
      "worker"
    ];
  };

  # Identity-equal override (value matches default) serializes byte-identically
  # to the baseline. Pure triggering of `.override` must not perturb output.
  testMkBakeFileGroupIdentityOverrideMatchesBaseline = {
    expr = groupIdentityOverride == groupBaseline;
    expected = true;
  };

  # Value-changing override preserves canonical group names and does not
  # duplicate targets under synthetic names.
  testMkBakeFileGroupValueOverrideUsesCanonicalNames = {
    expr = groupValueOverride.group.default.targets;
    expected = [
      "main"
      "worker"
    ];
  };

  testMkBakeFileGroupValueOverrideHasNoSyntheticTargets = {
    expr = builtins.attrNames groupValueOverride.target;
    expected = [
      "main"
      "worker"
    ];
  };

  testMkBakeFileGroupValueOverridePropagatesArgs = {
    expr = groupValueOverride.target.main.args.VERSION;
    expected = "v2.0.0";
  };

  # ---------- context identity under .override ----------

  # After an override, a context reference to a sibling target resolves to
  # that target's canonical name, not a synthetic `<target>__<ctx>` fallback.
  testMkBakeFileCtxRefOverrideUsesCanonicalName = {
    expr = ctxRefOverride.target.derived.contexts.base;
    expected = "target:base";
  };

  testMkBakeFileCtxRefOverrideHasNoSyntheticTargets = {
    expr = builtins.attrNames ctxRefOverride.target;
    expected = [
      "base"
      "derived"
    ];
  };

  testMkBakeFileCtxRefOverridePropagatesArgs = {
    expr = ctxRefOverride.target.base.args.VERSION;
    expected = "v2.0.0";
  };
}
