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

  # lib.extend witness module: consumes `val` from scope so overlay propagation
  # into a forked module can be observed on the resolved module's args.
  cwsMkCtxScope = mkScope {
    config.val = "default";
    modules.forkable = ./fixtures/forkable-mkctx-mod.nix;
  };
  cwsMkCtxForked = (cwsMkCtxScope.lib.extend (final: prev: { val = "overridden"; })).modules.forkable;

  # scope.extend
  extendedScope = scope1.extend (final: prev: { myConfigValue = "extended"; });

  # lib.extend
  libExtendedScope = scope1.lib.extend (final: prev: { myConfigValue = "lib-extended"; });

  # callModule shallow isolation: overriding a config value when resolving one
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
  aOverridden = shallowScope.lib.callModule sharedA { shared = "overridden"; };

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

  # ---------- content-addressed dedup fixtures (issue #31) ----------
  #
  # Capture hazard: a let-binding that is both registered under
  # `targets.<key>` AND captured via another registered target's
  # `contexts.<name>`. Without content-addressed dedup, the serializer
  # materializes both: one as the first-level `base`, the other as a
  # spurious second-level entry. Content-hash dedup collapses them.

  dedupAFile = builtins.toFile "dedup-a.nix" ''
    { lib, ... }:
    {
      targets.base = lib.mkTarget { name = "base"; context = ./.; };
      groups = {};
    }
  '';

  # b registers `base` (a `//` re-export) AND captures the let-binding
  # via `main.contexts.root`. Content-hash dedup collapses both into
  # the first-level `base` — bake file has exactly two target entries.
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
  # level let-bindings, one captured by the other. Content hash matches
  # the registered counterpart → dedup into the first-level id. No
  # `_containerd_<hash>` entry appears.
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
  # first-level set → emits as `_base_<hash>`.
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
  # `_<name>_<hash>`, does NOT collapse.
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

  # Groups + dedup: a group member captured from another module
  # resolves to the first-level bare name via content-hash dedup,
  # not to a hash-suffixed wire id.
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
    expr = stringPathScope.test.targets ? main;
    expected = true;
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

  # lib.extend on a scope with a module that reads a scope config key: the
  # forked module's args reflect the overlay's value, confirming the overlay
  # propagates through callModule's auto-injection.
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

  # ---------- callModule shallow isolation ----------

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

  # callModule's result is itself overridable: the API doc lists callModule
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

  # ---------- content-addressed dedup (issue #31) ----------

  # Reproducer from issue #31: `main.contexts.root` captures the `aBase`
  # let-binding while `targets.base = aBase` is also registered. Content-
  # hash dedup collapses the capture into the first-level `base` — bake
  # file has exactly two target entries.
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

  # Transitive dedup (cri pattern): crio's containerdBase capture
  # collapses into the registered `containerd` first-level. No
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
    expr = builtins.match "target:_base_[0-9a-f]{8}" foreignParsed.target.main.contexts.root != null;
    expected = true;
  };

  testForeignSecondLevelEmitsEntry = {
    expr = builtins.any (n: builtins.match "_base_[0-9a-f]{8}" n != null) (
      builtins.attrNames foreignParsed.target
    );
    expected = true;
  };

  # Scope-fork with patched args: same `name` as first-level but
  # distinct content → emits as second-level, does NOT collapse.
  testScopeForkPatchedArgsNoCollapse = {
    expr = builtins.any (n: builtins.match "_base_[0-9a-f]{8}" n != null) (
      builtins.attrNames forkParsed.target
    );
    expected = true;
  };

  testScopeForkPatchedArgsMainContextIsSecondLevel = {
    expr = builtins.match "target:_base_[0-9a-f]{8}" forkParsed.target.main.contexts.root != null;
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
