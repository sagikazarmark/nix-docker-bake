{ bake, ... }:
let
  inherit (bake) mkScope;

  scopeTestModuleFile = builtins.toFile "scope-test-mod.nix" ''
    { lib, myConfigValue, ... }:
    {
      namespace = "test";
      targets = { main = lib.mkTarget { context = ./.; args.VAL = myConfigValue; }; };
      groups = {};
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
    modules.test = toString scopeTestModuleFile;
  };

  # callBakeWithScope propagation
  aFile = builtins.toFile "cbws-a.nix" ''
    { lib, val, ... }:
    {
      namespace = "a";
      targets = { t = lib.mkTarget { context = ./.; args.VAL = val; }; };
      groups = {};
    }
  '';
  bFile = builtins.toFile "cbws-b.nix" ''
    { lib, ... }:
    let
      aOverridden = lib.callBakeWithScope "a" (final: prev: { val = "overridden"; });
    in {
      namespace = "b";
      targets = { t = lib.mkTarget { context = ./.; contexts.root = aOverridden.targets.t; }; };
      groups = {};
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

  # callBakeWithScope with mkContext: a forked module must still receive a
  # per-module-specialized lib.mkContext (not the unspecialized curried form).
  cwsMkCtxScope = mkScope {
    config.val = "default";
    modules.forkable = ./fixtures/forkable-mkctx-mod.nix;
  };
  cwsMkCtxForked = cwsMkCtxScope.lib.callBakeWithScope "forkable" (
    final: prev: { val = "overridden"; }
  );

  # scope.extend
  extendedScope = scope1.extend (final: prev: { myConfigValue = "extended"; });

  # lib.extend
  libExtendedScope = scope1.lib.extend (final: prev: { myConfigValue = "lib-extended"; });

  # callBake shallow isolation: overriding a config value when resolving one
  # module must not affect sibling modules that read the same value.
  sharedA = builtins.toFile "shallow-a.nix" ''
    { lib, shared, ... }:
    {
      namespace = "a";
      targets = { t = lib.mkTarget { context = ./.; args.VAL = shared; }; };
      groups = {};
    }
  '';
  sharedB = builtins.toFile "shallow-b.nix" ''
    { lib, shared, ... }:
    {
      namespace = "b";
      targets = { t = lib.mkTarget { context = ./.; args.VAL = shared; }; };
      groups = {};
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

  # Witness-style assertion: confirms the back-ref points at a scope with the
  # expected shape. Avoids structural `==` on cyclic attrsets (the back-ref
  # creates a cycle between the scope and its modules).
  testMkScopeModuleCarriesScopeBackref = {
    expr = scope1.modules.test._scope.test.targets.main.args.VAL;
    expected = "hello";
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

  # callBakeWithScope must specialize mkContext with the module's registry key,
  # same as the default mapAttrs path. Without specialization, lib.mkContext
  # returns a lambda and downstream serialization breaks.
  testCallBakeWithScopeMkContextIsStorePath = {
    expr = builtins.match "/nix/store/.*-forkable-.*-context" cwsMkCtxForked._ctxStr != null;
    expected = true;
  };

  # Same guarantee for mkContextWith: the forked scope must pre-apply the
  # registry key, otherwise `lib.mkContextWith { path = ...; }` inside the
  # module would see mkContextWith as a lambda awaiting `prefix` and crash.
  testCallBakeWithScopeMkContextWithIsStorePath = {
    expr = builtins.match "/nix/store/.*-forkable-.*-context" cwsMkCtxForked._ctxWithStr != null;
    expected = true;
  };

  testCallBakeWithScopeMkContextUsesRegistryKey = {
    expr = cwsMkCtxForked.targets.t.args.VAL;
    expected = "overridden";
  };

  testCallBakeWithScopeUnknownModuleThrows = {
    expr = (builtins.tryEval (cwsMkCtxScope.lib.callBakeWithScope "nonexistent" (_: _: { }))).success;
    expected = false;
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

  # lib.mkContextWith is pre-applied with the registry key in exactly the same
  # way as lib.mkContext, so a module calling `lib.mkContextWith { path = ...; }`
  # (no prefix arg) gets the module name baked into the store-path name.
  testScopeMkContextWithAutoPrefix = {
    expr = builtins.match ".*my-module-.*-context.*" mkCtxScope.my-module._ctxWithStr != null;
    expected = true;
  };

  # Without a filter, scope-injected mkContextWith must match scope-injected
  # mkContext hash-for-hash (same module, same path).
  testScopeMkContextWithMatchesMkContext = {
    expr = mkCtxScope.my-module._ctxWithStr == mkCtxScope.my-module._ctxStr;
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

  # ---------- lib.extend ----------

  testLibExtendForksScope = {
    expr = libExtendedScope.modules.test.targets.main.args.VAL;
    expected = "lib-extended";
  };

  testLibExtendDoesNotMutateOriginalScope = {
    expr = scope1.test.targets.main.args.VAL;
    expected = "hello";
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
