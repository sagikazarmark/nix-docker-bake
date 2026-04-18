{ bake, ... }:
let
  inherit (bake) mkScope;

  scopeTestModuleFile = builtins.toFile "scope-test-mod.nix" ''
    { lib, myConfigValue, ... }:
    {
      targets = { main = lib.mkTarget { name = "main"; context = ./.; args.VAL = myConfigValue; }; };
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

  # lib.extend propagation
  aFile = builtins.toFile "cbws-a.nix" ''
    { lib, val, ... }:
    {
      targets = { t = lib.mkTarget { name = "t"; context = ./.; args.VAL = val; }; };
      groups = {};
    }
  '';
  bFile = builtins.toFile "cbws-b.nix" ''
    { lib, ... }:
    let
      aOverridden = (lib.extend (final: prev: { val = "overridden"; })).modules.a;
    in {
      targets = { t = lib.mkTarget { name = "t"; context = ./.; contexts.root = aOverridden.targets.t; }; };
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

  # lib.extend with mkContext: a forked module must still receive a
  # per-module-specialized lib.mkContext (not the unspecialized curried form).
  cwsMkCtxScope = mkScope {
    config.val = "default";
    modules.forkable = ./fixtures/forkable-mkctx-mod.nix;
  };
  cwsMkCtxForked = (cwsMkCtxScope.lib.extend (final: prev: { val = "overridden"; })).modules.forkable;

  # scope.extend
  extendedScope = scope1.extend (final: prev: { myConfigValue = "extended"; });

  # lib.extend
  libExtendedScope = scope1.lib.extend (final: prev: { myConfigValue = "lib-extended"; });

  # callBake shallow isolation: overriding a config value when resolving one
  # module must not affect sibling modules that read the same value.
  sharedA = builtins.toFile "shallow-a.nix" ''
    { lib, shared, ... }:
    {
      targets = { t = lib.mkTarget { name = "t"; context = ./.; args.VAL = shared; }; };
      groups = {};
    }
  '';
  sharedB = builtins.toFile "shallow-b.nix" ''
    { lib, shared, ... }:
    {
      targets = { t = lib.mkTarget { name = "t"; context = ./.; args.VAL = shared; }; };
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

  scopeOverridden = scope1.override { myConfigValue = "overridden-via-override"; };

  libOverrideAFile = builtins.toFile "libov-a.nix" ''
    { lib, val, ... }:
    {
      targets = { t = lib.mkTarget { name = "t"; context = ./.; args.VAL = val; }; };
      groups = {};
    }
  '';
  libOverrideBFile = builtins.toFile "libov-b.nix" ''
    { lib, ... }:
    let
      aOverridden = (lib.override { val = "via-lib-override"; }).modules.a;
    in {
      targets = { t = lib.mkTarget { name = "t"; context = ./.; contexts.root = aOverridden.targets.t; }; };
      groups = {};
    }
  '';
  libOverrideScope = mkScope {
    config.val = "default";
    modules = {
      a = libOverrideAFile;
      b = libOverrideBFile;
    };
  };

  # Per-module .override: a module with a defaulted arg that is NOT in scope
  # config. The override should swap the arg without touching the scope.
  perModuleArgFile = builtins.toFile "permod-arg.nix" ''
    { lib, version ? "1.0.0", ... }:
    {
      targets = { t = lib.mkTarget { name = "t"; context = ./.; args.VAL = version; }; };
      groups = {};
    }
  '';
  perModuleScope = mkScope {
    config = { };
    modules.perm = perModuleArgFile;
  };

  # Per-instance override of a scope-wide arg: two modules both read `shared`
  # from scope config. Overriding it on one must not affect the other.
  instOverrideScope = mkScope {
    config.shared = "base";
    modules = {
      a = sharedA;
      b = sharedB;
    };
  };

  # Registration-time validation: a target's `name` field must match its
  # attrset key. Catches the three silent-collision idioms documented in
  # docs/issue-27-analysis.md:
  #   (1) let-binding identifier ≠ attrset key
  #   (2) `//` composition silently inherits `name` from LHS
  #   (3) project-level wrapper helpers compounding (1) or (2)

  # Idiom 1: name explicitly mismatches attrset key.
  nameMismatchFile = builtins.toFile "name-mismatch.nix" ''
    { lib, ... }:
    {
      targets = { foo = lib.mkTarget { name = "bar"; context = ./.; }; };
      groups = {};
    }
  '';

  # Idiom 2: `//` composition inherits `name` from LHS without an explicit override.
  slashInheritFile = builtins.toFile "slash-inherit.nix" ''
    { lib, ... }:
    let
      base = lib.mkTarget { name = "base"; context = ./.; };
      derived = base // { tags = [ "x" ]; };  # name still "base", not "derived"
    in {
      targets = { inherit base; derived = derived; };
      groups = {};
    }
  '';

  # Idiom 3: registered target with no `name` field at all.
  missingNameFile = builtins.toFile "missing-name.nix" ''
    { lib, ... }:
    {
      targets = { main = lib.mkTarget { context = ./.; }; };
      groups = {};
    }
  '';
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

  # ---------- lib.extend propagation ----------

  testLibExtendBaseValue = {
    expr = scope2.a.targets.t.args.VAL;
    expected = "default";
  };

  testLibExtendPropagatesOverrideViaModules = {
    expr = scope2.b.targets.t.contexts.root.args.VAL;
    expected = "overridden";
  };

  testLibExtendMkContextIsStorePath = {
    expr = builtins.match "/nix/store/.*-forkable-.*-context" cwsMkCtxForked._ctxStr != null;
    expected = true;
  };

  testLibExtendMkContextWithIsStorePath = {
    expr = builtins.match "/nix/store/.*-forkable-.*-context" cwsMkCtxForked._ctxWithStr != null;
    expected = true;
  };

  # Renamed from testCallBakeWithScopeMkContextUsesRegistryKey — the original
  # asserted on args.VAL (i.e., overlay propagation into the forked module's
  # args), not on the mkContext registry-key specialization. The store-path
  # specialization is covered by the two *IsStorePath tests above.
  testLibExtendPropagatesToForkedModuleArgs = {
    expr = cwsMkCtxForked.targets.t.args.VAL;
    expected = "overridden";
  };

  testLibExtendUnknownModuleThrows = {
    expr =
      (builtins.tryEval (
        (cwsMkCtxScope.lib.extend (_: _: { })).modules.nonexistent
          or (throw "module 'nonexistent' not found in scope")
      )).success;
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

  testMkScopeRejectsReservedNameOverride = {
    expr =
      (builtins.tryEval (mkScope {
        config = { };
        modules.override = scopeTestModuleFile;
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

  # callBake's result is itself overridable: the API doc lists callBake
  # alongside scope.<name> as a source of overridable modules.
  testCallBakeResultIsOverridable = {
    expr = (aOverridden.override { shared = "twice-overridden"; }).targets.t.args.VAL;
    expected = "twice-overridden";
  };

  # ---------- scope.override / lib.override sugar ----------

  testScopeOverrideAppliesAttrs = {
    expr = scopeOverridden.test.targets.main.args.VAL;
    expected = "overridden-via-override";
  };

  testScopeOverrideDoesNotMutateOriginal = {
    expr = scope1.test.targets.main.args.VAL;
    expected = "hello";
  };

  testLibOverridePropagates = {
    expr = libOverrideScope.b.targets.t.contexts.root.args.VAL;
    expected = "via-lib-override";
  };

  # ---------- per-module .override ----------

  # Baseline: module with a defaulted arg resolves to the default.
  testModuleOverrideBaseline = {
    expr = perModuleScope.perm.targets.t.args.VAL;
    expected = "1.0.0";
  };

  # .override swaps the arg.
  testModuleOverrideSwapsArg = {
    expr = (perModuleScope.perm.override { version = "2.0.0"; }).targets.t.args.VAL;
    expected = "2.0.0";
  };

  # Override is local to the returned instance; the scope's view is unaffected.
  # Both values must be forced in the same expr so the override actually runs;
  # a `let _ = override; in scope.X` would never evaluate the override.
  testModuleOverrideDoesNotMutateScope = {
    expr = {
      overridden = (perModuleScope.perm.override { version = "2.0.0"; }).targets.t.args.VAL;
      original = perModuleScope.perm.targets.t.args.VAL;
    };
    expected = {
      overridden = "2.0.0";
      original = "1.0.0";
    };
  };

  # .override chains: latest call wins.
  testModuleOverrideChains = {
    expr =
      ((perModuleScope.perm.override { version = "2.0.0"; }).override { version = "3.0.0"; })
      .targets.t.args.VAL;
    expected = "3.0.0";
  };

  # The overridden module still carries _scope so mkBakeFile works on it.
  testModuleOverridePreservesScope = {
    expr = (perModuleScope.perm.override { version = "2.0.0"; }) ? _scope;
    expected = true;
  };

  # `scope.modules.<name>.override` works the same as `scope.<name>.override`.
  # The two paths reference the same value via mapAttrs, but the API doc
  # explicitly lists both, so assert the equivalence.
  testModuleOverrideViaModulesAttr = {
    expr = (perModuleScope.modules.perm.override { version = "2.0.0"; }).targets.t.args.VAL;
    expected = "2.0.0";
  };

  # Per-instance override of a scope-wide arg: only the overridden module
  # sees the new value; siblings reading the same scope key are unaffected.
  testModuleOverrideOfScopeArgIsLocal = {
    expr = (instOverrideScope.a.override { shared = "only-a"; }).targets.t.args.VAL;
    expected = "only-a";
  };

  # Forcing both `a` (overridden) and `b` (sibling) in the same attrset
  # ensures the override is evaluated, not skipped by laziness.
  testModuleOverrideOfScopeArgDoesNotAffectSibling = {
    expr = {
      a = (instOverrideScope.a.override { shared = "only-a"; }).targets.t.args.VAL;
      b = instOverrideScope.b.targets.t.args.VAL;
    };
    expected = {
      a = "only-a";
      b = "base";
    };
  };

  # ---------- attrset-key-matches-name validation (registration-time) ----------

  # Idiom 1: explicit name vs key mismatch throws at module load.
  testRegistrationRejectsNameKeyMismatch = {
    expr =
      (builtins.tryEval
        (mkScope {
          config = { };
          modules.nm = nameMismatchFile;
        }).nm.targets
      ).success;
    expected = false;
  };

  # Idiom 2: `//` inherits name from LHS — registered under a different key
  # than its inherited name → throws at module load.
  testRegistrationRejectsSlashInheritedName = {
    expr =
      (builtins.tryEval
        (mkScope {
          config = { };
          modules.si = slashInheritFile;
        }).si.targets
      ).success;
    expected = false;
  };

  # Idiom 3: target without a name field at all → throws at module load.
  testRegistrationRejectsMissingName = {
    expr =
      (builtins.tryEval
        (mkScope {
          config = { };
          modules.mn = missingNameFile;
        }).mn.targets
      ).success;
    expected = false;
  };
}
