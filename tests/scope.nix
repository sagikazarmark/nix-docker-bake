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
}
