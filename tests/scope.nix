{ bake, ... }:
let
  inherit (bake) mkScope mkBakeFile;

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

  # Registration-time namespace stamping.
  #
  # `//` composition silently inherits `namespace` from the LHS, the same
  # way it inherits `name`. Unlike `name` (which the author writes on every
  # mkTarget call and must match the attrset key), `namespace` is curried
  # in by the per-module lib.mkTarget — the author never writes it. So the
  # fix is to STAMP namespace at registration rather than throw, reifying
  # the D1=a "registry key IS the namespace" invariant structurally.
  nsStampAFile = builtins.toFile "ns-stamp-a.nix" ''
    { lib, ... }:
    {
      targets.base = lib.mkTarget { name = "base"; context = ./.; };
      groups = {};
    }
  '';

  # b re-exports a's target under its own key. Naive `//` leaves
  # namespace = "a"; stamping rewrites it to "b".
  nsStampBFile = builtins.toFile "ns-stamp-b.nix" ''
    { lib, a, ... }:
    {
      targets = {
        base = a.targets.base // { name = "base"; };
        main = lib.mkTarget { name = "main"; context = ./.; };
      };
      groups = {};
    }
  '';

  nsStampScope = mkScope {
    config = { };
    modules = {
      a = nsStampAFile;
      b = nsStampBFile;
    };
  };

  nsStampBake = mkBakeFile nsStampScope.modules.b;
  nsStampParsed = builtins.fromJSON (builtins.readFile nsStampBake);

  # `.override` re-runs the module function through makeOverridable; the
  # stamp must re-apply, not be lost.
  nsStampOverrideFile = builtins.toFile "ns-stamp-override.nix" ''
    { lib, a, version ? "v1", ... }:
    {
      targets = {
        base = a.targets.base // { name = "base"; };
        main = lib.mkTarget { name = "main"; context = ./.; args.V = version; };
      };
      groups = {};
    }
  '';
  nsStampOverrideScope = mkScope {
    config = { };
    modules = {
      a = nsStampAFile;
      b = nsStampOverrideFile;
    };
  };
  nsStampOverridden = nsStampOverrideScope.modules.b.override { version = "v2"; };

  # A foreign target used in `contexts.<name>` (not registered under
  # `targets.<key>`) must KEEP its foreign namespace — that's how the
  # serializer emits a cross-module reference like `target:a_base`.
  nsPreserveBFile = builtins.toFile "ns-preserve-b.nix" ''
    { lib, a, ... }:
    {
      targets.main = lib.mkTarget {
        name = "main";
        context = ./.;
        contexts.root = a.targets.base;
      };
      groups = {};
    }
  '';
  nsPreserveScope = mkScope {
    config = { };
    modules = {
      a = nsStampAFile;
      b = nsPreserveBFile;
    };
  };

  # ---------- content-addressed dedup fixtures (issue #31) ----------
  #
  # The capture hazard: a let-binding that is both registered under
  # `targets.<key>` AND captured via another registered target's
  # `contexts.<name>`. The registered copy gets post-stamp by PR #30;
  # the captured copy is pre-stamp (carries the LHS's silently-inherited
  # foreign namespace). Nix values are immutable, so the two copies are
  # distinct attrsets that differ only on `namespace`. Without
  # content-addressed dedup, the serializer materializes both: one as
  # the first-level `base`, the other as a spurious `a_base`. #31
  # collapses them by content hash.

  dedupAFile = builtins.toFile "dedup-a.nix" ''
    { lib, ... }:
    {
      targets.base = lib.mkTarget { name = "base"; context = ./.; };
      groups = {};
    }
  '';

  # b registers `base` (a `//` re-export, stamp rewrites ns → "b") AND
  # captures the pre-stamp let-binding via `main.contexts.root`. Before
  # #31 that produced a third `a_base` entry; after #31 the two content-
  # hash-match and collapse into the first-level `base`.
  dedupBFile = builtins.toFile "dedup-b.nix" ''
    { lib, a, ... }:
    let
      aBase = a.targets.base // { name = "base"; };
    in
    {
      targets = {
        base = aBase;
        main = lib.mkTarget {
          name = "main";
          context = ./.;
          contexts.root = aBase;
        };
      };
      groups = {};
    }
  '';

  dedupScope = mkScope {
    config = { };
    modules = {
      a = dedupAFile;
      b = dedupBFile;
    };
  };
  dedupParsed = builtins.fromJSON (builtins.readFile (mkBakeFile dedupScope.modules.b));

  # Transitive dedup (cri pattern from issue #31 trace 1): two first-
  # level let-bindings, one captured pre-stamp by the other. Content
  # hash matches the registered counterpart → dedup into the first-
  # level id. No `_containerd_<hash>` entry appears.
  triCAFile = builtins.toFile "tri-c.nix" ''
    { lib, ... }:
    {
      targets.base = lib.mkTarget { name = "base"; context = ./.; };
      groups = {};
    }
  '';
  triBFile = builtins.toFile "tri-b.nix" ''
    { lib, c, ... }:
    let
      containerdBase = c.targets.base // { name = "containerd"; };
      crioBase = c.targets.base // {
        name = "crio";
        contexts.root = containerdBase;
      };
    in
    {
      targets = {
        containerd = containerdBase;
        crio = crioBase;
      };
      groups = {};
    }
  '';
  triScope = mkScope {
    config = { };
    modules = {
      c = triCAFile;
      b = triBFile;
    };
  };
  triParsed = builtins.fromJSON (builtins.readFile (mkBakeFile triScope.modules.b));

  # Foreign second-level (no dedup): b.main.contexts.root = a.targets.base
  # where b registers no counterpart. No hash match anywhere in b's
  # first-level set → emits as `_a_base_<hash>`.
  foreignAFile = builtins.toFile "foreign-a.nix" ''
    { lib, ... }:
    {
      targets.base = lib.mkTarget { name = "base"; context = ./.; };
      groups = {};
    }
  '';
  foreignBFile = builtins.toFile "foreign-b.nix" ''
    { lib, a, ... }:
    {
      targets.main = lib.mkTarget {
        name = "main";
        context = ./.;
        contexts.root = a.targets.base;
      };
      groups = {};
    }
  '';
  foreignScope = mkScope {
    config = { };
    modules = {
      a = foreignAFile;
      b = foreignBFile;
    };
  };
  foreignParsed = builtins.fromJSON (builtins.readFile (mkBakeFile foreignScope.modules.b));

  # Scope-fork with patched args (harikubeadm-cluster pattern): a second-
  # level target derived from a scope-forked target, with args differing
  # from any first-level target. Content hash distinct → emits as
  # `_<ns>_<name>_<hash>`, does NOT collapse.
  forkAFile = builtins.toFile "fork-a.nix" ''
    { lib, version ? "v1", ... }:
    {
      targets.base = lib.mkTarget {
        name = "base";
        context = ./.;
        args.VERSION = version;
      };
      groups = {};
    }
  '';
  forkBFile = builtins.toFile "fork-b.nix" ''
    { lib, a, ... }:
    let
      # Scope-forked a with patched args; referenced without registering.
      patched = (lib.override { version = "v2"; }).modules.a;
    in
    {
      targets = {
        base = lib.mkTarget {
          name = "base";
          context = ./.;
          args.VERSION = "v1";
        };
        main = lib.mkTarget {
          name = "main";
          context = ./.;
          contexts.root = patched.targets.base;
        };
      };
      groups = {};
    }
  '';
  forkScope = mkScope {
    config = { };
    modules = {
      a = forkAFile;
      b = forkBFile;
    };
  };
  forkParsed = builtins.fromJSON (builtins.readFile (mkBakeFile forkScope.modules.b));

  # Cross-scope-fork uniform dedup: when a scope-forked target's
  # content hash DOES match a first-level target, it collapses into
  # the first-level id — no origin-based carve-out.
  uniformBFile = builtins.toFile "uniform-b.nix" ''
    { lib, a, ... }:
    let
      # Scope-forked a; default args still "v1" (identical content).
      forked = (lib.override { }).modules.a;
    in
    {
      targets = {
        base = lib.mkTarget {
          name = "base";
          context = ./.;
          args.VERSION = "v1";
        };
        main = lib.mkTarget {
          name = "main";
          context = ./.;
          contexts.root = forked.targets.base;
        };
      };
      groups = {};
    }
  '';
  uniformScope = mkScope {
    config = { };
    modules = {
      a = forkAFile;
      b = uniformBFile;
    };
  };
  uniformParsed = builtins.fromJSON (builtins.readFile (mkBakeFile uniformScope.modules.b));

  # Groups + dedup: a group member captured pre-stamp from another
  # module resolves to the first-level bare name via content-hash
  # dedup, not to a hash-suffixed wire id.
  groupDedupBFile = builtins.toFile "group-dedup-b.nix" ''
    { lib, a, ... }:
    let
      aBase = a.targets.base // { name = "base"; };
    in
    {
      targets = {
        base = aBase;
        main = lib.mkTarget { name = "main"; context = ./.; };
      };
      groups.default = [ aBase ];
    }
  '';
  groupDedupScope = mkScope {
    config = { };
    modules = {
      a = dedupAFile;
      b = groupDedupBFile;
    };
  };
  groupDedupParsed = builtins.fromJSON (builtins.readFile (mkBakeFile groupDedupScope.modules.b));
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

  # ---------- namespace stamping (registration-time) ----------

  # A `//` re-exported target has its silently-inherited foreign namespace
  # overwritten to the registering module's name.
  testRegistrationStampsReExportedTargetNamespace = {
    expr = nsStampScope.b.targets.base.namespace;
    expected = "b";
  };

  # Native-construction targets already carry the correct namespace via the
  # per-module `lib.mkTarget` curry — assert the stamp is a no-op here (not
  # a silent rewrite that could mask unrelated bugs).
  testRegistrationStampPreservesCurriedNamespace = {
    expr = nsStampScope.b.targets.main.namespace;
    expected = "b";
  };

  # End-to-end reproducer from issue #29. Without the stamp, the
  # alphabetically-first target (`base`) carries namespace "a", so
  # entryNamespace becomes "a" and `main` is emitted as `b_main`. With
  # the stamp, both targets are bare under module b's own namespace.
  testRegistrationStampEmitsBareTargetNames = {
    expr = builtins.sort (x: y: x < y) (builtins.attrNames nsStampParsed.target);
    expected = [
      "base"
      "main"
    ];
  };

  testRegistrationStampDoesNotEmitPrefixedOwnTarget = {
    expr = nsStampParsed.target ? b_main;
    expected = false;
  };

  # The stamp survives `.override`: re-resolving through makeOverridable
  # re-runs the module function and must re-stamp.
  testRegistrationStampSurvivesOverride = {
    expr = nsStampOverridden.targets.base.namespace;
    expected = "b";
  };

  # Foreign targets used as `contexts.<name>` values (not registered under
  # `targets.<key>`) retain their original namespace — otherwise
  # cross-module references would silently collapse into local references.
  testRegistrationStampLeavesContextValuesUntouched = {
    expr = nsPreserveScope.b.targets.main.contexts.root.namespace;
    expected = "a";
  };

  # `.overrideAttrs` on a stamped target must not revive the pre-stamp
  # namespace. This is the reason stampTarget rebuilds through core.mkTarget
  # (so the target's overrideAttrs closure captures the stamped state)
  # instead of using a cheaper `t // { namespace = ...; }`.
  testRegistrationStampSurvivesOverrideAttrs = {
    expr =
      (nsStampScope.b.targets.base.overrideAttrs (_: {
        tags = [ "x" ];
      })).namespace;
    expected = "b";
  };

  # ---------- content-addressed dedup (issue #31) ----------

  # Reproducer from issue #31: `main.contexts.root` captures the pre-
  # stamp `aBase` let-binding while `targets.base = aBase` is also
  # registered. Content-hash dedup collapses the capture into the
  # first-level `base` — bake file has exactly two target entries.
  testDedupCollapseReproducer = {
    expr = builtins.sort (x: y: x < y) (builtins.attrNames dedupParsed.target);
    expected = [
      "base"
      "main"
    ];
  };

  testDedupCollapseContextReference = {
    expr = dedupParsed.target.main.contexts.root;
    expected = "target:base";
  };

  # Transitive dedup (cri pattern): crio's pre-stamp containerdBase
  # capture collapses into the registered `containerd` first-level. No
  # `_containerd_<hash>` entry appears; the bake file has exactly two
  # target entries.
  testTransitiveDedupFirstLevelOnly = {
    expr = builtins.sort (x: y: x < y) (builtins.attrNames triParsed.target);
    expected = [
      "containerd"
      "crio"
    ];
  };

  testTransitiveDedupCrioContext = {
    expr = triParsed.target.crio.contexts.root;
    expected = "target:containerd";
  };

  # Foreign second-level reference (no dedup): captured target has no
  # counterpart in entry module's first-level set → emits as hash-
  # suffixed wire id with leading underscore.
  testForeignSecondLevelPrefixedId = {
    expr = builtins.match "target:_a_base_[0-9a-f]{8}" foreignParsed.target.main.contexts.root != null;
    expected = true;
  };

  testForeignSecondLevelEmitsEntry = {
    expr = builtins.any (n: builtins.match "_a_base_.*" n != null) (
      builtins.attrNames foreignParsed.target
    );
    expected = true;
  };

  # Scope-fork with patched args: same `name` as first-level but
  # distinct content → emits as second-level, does NOT collapse.
  testScopeForkPatchedArgsNoCollapse = {
    expr = builtins.any (n: builtins.match "_a_base_.*" n != null) (
      builtins.attrNames forkParsed.target
    );
    expected = true;
  };

  testScopeForkPatchedArgsMainContextIsSecondLevel = {
    expr = builtins.match "target:_a_base_[0-9a-f]{8}" forkParsed.target.main.contexts.root != null;
    expected = true;
  };

  # Guard: the first-level `base` in forkScope.b does NOT collapse the
  # second-level patched `a.base` into itself (different args → different
  # hashes). Both entries must be present.
  testScopeForkPatchedArgsFirstLevelUnaffected = {
    expr = forkParsed.target ? base;
    expected = true;
  };

  # Cross-scope-fork uniform dedup: when the forked target's content
  # hash matches a first-level target, it collapses — no origin carve-
  # out. Here uniform.b.main.contexts.root is a scope-forked a.base
  # with identical content to uniform.b.targets.base → dedup to `base`.
  testCrossScopeForkUniformDedup = {
    expr = uniformParsed.target.main.contexts.root;
    expected = "target:base";
  };

  testCrossScopeForkUniformNoExtraEntry = {
    expr = builtins.sort (x: y: x < y) (builtins.attrNames uniformParsed.target);
    expected = [
      "base"
      "main"
    ];
  };

  # Group members dedup into first-level names via content hash.
  testGroupDedupsToFirstLevelName = {
    expr = groupDedupParsed.group.default.targets;
    expected = [ "base" ];
  };

  testGroupDedupDoesNotEmitExtraTarget = {
    expr = builtins.sort (x: y: x < y) (builtins.attrNames groupDedupParsed.target);
    expected = [
      "base"
      "main"
    ];
  };
}
