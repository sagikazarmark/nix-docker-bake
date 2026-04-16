{ bake, ... }:
let
  inherit (bake) mkScope;

  scopeTestModuleFile = builtins.toFile "scope-test-mod.nix" ''
    { lib, myConfigValue, ... }:
    {
      namespace = "test";
      targets = { main = lib.mkTarget { context = ./.; args.VAL = myConfigValue; }; };
      groups = {};
      vars = {};
    }
  '';

  scope1 = mkScope {
    config = {
      myConfigValue = "hello";
    };
    modules.test = scopeTestModuleFile;
  };

  # String-path module (not just Nix paths)
  stringPathScope = mkScope {
    config = {
      myConfigValue = "via-string";
    };
    modules.test = builtins.toString scopeTestModuleFile;
  };

  # callBakeWithScope propagation
  aFile = builtins.toFile "cbws-a.nix" ''
    { lib, val, ... }:
    {
      namespace = "a";
      targets = { t = lib.mkTarget { context = ./.; args.VAL = val; }; };
      groups = {};
      vars = {};
    }
  '';
  bFile = builtins.toFile "cbws-b.nix" ''
    { lib, ... }:
    let
      aOverridden = lib.callBakeWithScope ${aFile} (final: prev: { val = "overridden"; });
    in {
      namespace = "b";
      targets = { t = lib.mkTarget { context = ./.; contexts.root = aOverridden.targets.t; }; };
      groups = {};
      vars = {};
    }
  '';
  scope2 = mkScope {
    config = {
      val = "default";
    };
    modules = {
      a = aFile;
      b = bFile;
    };
  };

  # mkContext auto-injection: module receives lib.mkContext pre-applied with its registry key.
  mkCtxScope = mkScope {
    config = { };
    modules.my-module = ./fixtures/mkctx-mod.nix;
  };

  # scope.extend
  extendedScope = scope1.extend (final: prev: { myConfigValue = "extended"; });

  # callBake shallow isolation: overriding a config value when resolving one
  # module must not affect sibling modules that read the same value.
  sharedA = builtins.toFile "shallow-a.nix" ''
    { lib, shared, ... }:
    {
      namespace = "a";
      targets = { t = lib.mkTarget { context = ./.; args.VAL = shared; }; };
      groups = {};
      vars = {};
    }
  '';
  sharedB = builtins.toFile "shallow-b.nix" ''
    { lib, shared, ... }:
    {
      namespace = "b";
      targets = { t = lib.mkTarget { context = ./.; args.VAL = shared; }; };
      groups = {};
      vars = {};
    }
  '';
  shallowScope = mkScope {
    config.shared = "base";
    modules = {
      a = sharedA;
      b = sharedB;
    };
  };
  # Re-resolve only `a` with an override.
  aOverridden = shallowScope.lib.callBake sharedA { shared = "overridden"; };
in
{
  # ---------- mkScope ----------

  testMkScopeModuleNamespace = {
    expr = scope1.test.namespace;
    expected = "test";
  };

  testMkScopeInjectsConfig = {
    expr = scope1.test.targets.main.args.VAL;
    expected = "hello";
  };

  testMkScopeExposesModules = {
    expr = scope1.modules ? test;
    expected = true;
  };

  # ---------- string-path modules ----------

  testMkScopeAcceptsStringPaths = {
    expr = stringPathScope.test.namespace;
    expected = "test";
  };

  testMkScopeStringPathInjectsConfig = {
    expr = stringPathScope.test.targets.main.args.VAL;
    expected = "via-string";
  };

  # ---------- callBakeWithScope propagation ----------

  # Base scope's a.t has val = "default"
  testCallBakeWithScopeBaseValue = {
    expr = scope2.a.targets.t.args.VAL;
    expected = "default";
  };

  # B resolves A via callBakeWithScope with val = "overridden". The context
  # of B.t is the overridden A.t (not base scope's A.t).
  testCallBakeWithScopePropagatesOverride = {
    expr = scope2.b.targets.t.contexts.root.args.VAL;
    expected = "overridden";
  };

  # ---------- scope.extend ----------

  testScopeExtendAppliesOverlay = {
    expr = extendedScope.test.targets.main.args.VAL;
    expected = "extended";
  };

  testScopeExtendDoesNotMutateOriginal = {
    expr = scope1.test.targets.main.args.VAL;
    expected = "hello";
  };

  # ---------- mkContext auto-injection ----------

  # The module's lib.mkContext is pre-applied with the registry key ("my-module"),
  # so the store path name contains that prefix.
  testScopeMkContextAutoPrefix = {
    expr = builtins.match ".*my-module-.*-context.*" mkCtxScope.my-module._ctxStr != null;
    expected = true;
  };

  # The auto-injected mkContext still produces a valid store path.
  testScopeMkContextIsStorePath = {
    expr = builtins.match "/nix/store/.*" mkCtxScope.my-module._ctxStr != null;
    expected = true;
  };

  # ---------- reserved-name conflicts ----------

  testMkScopeRejectsReservedNameLib = {
    expr =
      (builtins.tryEval (mkScope {
        config = { };
        modules.lib = scopeTestModuleFile;
      })).success;
    expected = false;
  };

  testMkScopeRejectsReservedNameExtend = {
    expr =
      (builtins.tryEval (mkScope {
        config = { };
        modules.extend = scopeTestModuleFile;
      })).success;
    expected = false;
  };

  testMkScopeRejectsReservedNameModules = {
    expr =
      (builtins.tryEval (mkScope {
        config = { };
        modules.modules = scopeTestModuleFile;
      })).success;
    expected = false;
  };

  # ---------- callBake shallow isolation ----------

  # The re-resolved module sees the override.
  testCallBakeAppliesOverride = {
    expr = aOverridden.targets.t.args.VAL;
    expected = "overridden";
  };

  # The sibling module in the original scope is unaffected.
  testCallBakeDoesNotAffectSibling = {
    expr = shallowScope.b.targets.t.args.VAL;
    expected = "base";
  };

  # The original scope's view of the overridden module is also unaffected.
  testCallBakeDoesNotMutateOriginal = {
    expr = shallowScope.a.targets.t.args.VAL;
    expected = "base";
  };
}
