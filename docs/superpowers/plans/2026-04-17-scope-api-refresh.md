# Scope API Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop string-keyed module lookups from the public API so module access goes through attribute paths, matching nixpkgs idioms (`pkgs.foo`, `pkgs.extend`, `pkg.override`).

**Architecture:** Three coordinated changes. (1) Each resolved module in a scope gains a hidden `_scope` back-reference so serialization no longer needs the scope passed separately. (2) `mkBakeFile` stops taking `{ scope; module = "name"; }` and instead takes the module value directly. (3) Inside modules, `lib.callBakeWithScope "name" overlay` is replaced by `(lib.extend overlay).modules.name`. A plain-attrs `override` sugar is added on both `scope` and `lib` as a secondary convenience.

**Tech Stack:** Nix (pure; no nixpkgs dependency in `lib/`). Tests are `lib.runTests`-style attrsets batched through `nix flake check`. Formatting is `nix fmt` (nixfmt-tree).

---

## File Structure

- `lib/scope.nix` — all API surface changes live here: `_scope` back-reference, new `mkBakeFile` signature, `lib.extend`, `lib.override`, `scope.override`, removal of `callBakeWithScope`.
- `lib/default.nix` — no changes expected; `mkBakeFile`, `mkScope` still re-exported.
- `lib/core.nix`, `lib/serialize.nix`, `lib/describe.nix`, `lib/nix-lib.nix` — unchanged.
- `tests/scope.nix` — migrate `callBakeWithScope` cases to new shape; add `scope.override` / `lib.extend` / `lib.override` cases.
- `tests/bake-file.nix` — migrate to new `mkBakeFile` signature.
- `tests/integration.nix` — migrate all `mkBakeFile { scope; module = "x"; }` calls and the inline `callBakeWithScope` fixture.
- `tests/fixtures/forkable-mkctx-mod.nix` — unchanged; exercised via the new `lib.extend` path.
- `API.md` — rewrite `mkBakeFile`, `scope.extend` sections; add `scope.override`, `lib.extend`, `lib.override`; remove `callBakeWithScope`.
- `README.md` — rewrite the "Overrides" table and "Deep override" subsection; update the "A bake file" example.

---

## Ground rules for every task

- After each impl change, run `nix flake check` (see expected output per task).
- Before every commit: run `nix fmt` so the commit is pre-formatted (user preference — don't ship trailing fmt fixups).
- Commit message style follows existing history (`feat:`, `refactor:`, `docs:` prefixes — see recent commits).
- Tests in this repo live as attrsets consumed by `lib.runTests`; a failing assertion causes `nix flake check` to throw with a JSON blob of failures. There is no selective-test CLI.

---

## Task 1: Attach `_scope` back-reference to resolved modules

**Files:**
- Modify: `lib/scope.nix:77-89` (the `mapAttrs` that builds per-module values)
- Test: `tests/scope.nix`

This is the foundation: once each `scope.modules.X` carries a reference to the scope it was resolved in, `mkBakeFile` can take the module value alone and reconstruct what `serialize` needs.

- [ ] **Step 1: Add failing test for the back-reference**

Append to `tests/scope.nix` in the `# ---------- mkScope ----------` section (after `testMkScopeExposesModules`):

```nix
  # Witness-style assertion: confirms the back-ref points at a scope with the
  # expected shape. Avoids structural `==` on cyclic attrsets (the back-ref
  # creates a cycle between the scope and its modules).
  testMkScopeModuleCarriesScopeBackref = {
    expr = scope1.modules.test._scope.test.targets.main.args.VAL;
    expected = "hello";
  };
```

- [ ] **Step 2: Run `nix flake check` to verify the test fails**

Run: `nix flake check`
Expected: failure with `testMkScopeModuleCarriesScopeBackref` in the `test failures` JSON.

- [ ] **Step 3: Attach `_scope` in `mkScope`**

In `lib/scope.nix`, change the module-resolution `mapAttrs` (currently at lines 77-89) so each resolved module gets `_scope = self;` merged onto its attrset:

```nix
        // builtins.mapAttrs (
          moduleName: modulePath:
          let
            moduleLib = libFunctions // {
              mkContext = core.mkContext moduleName;
              mkContextWith = core.mkContextWith moduleName;
            };
            resolved = libFunctions.callBake modulePath { lib = moduleLib; };
          in
          # _scope is attached AFTER callBake (which runs checkModule) so
          # validation only sees consumer-authored keys. Do not reorder.
          resolved // { _scope = self; }
        ) modules
```

- [ ] **Step 4: Run `nix flake check` to verify all tests pass**

Run: `nix flake check`
Expected: `all tests passed (...)`.

- [ ] **Step 5: Format and commit**

```bash
nix fmt
git add lib/scope.nix tests/scope.nix
git commit -m "feat(scope): attach _scope back-reference to resolved modules"
```

---

## Task 2: `mkBakeFile` accepts a module value

**Files:**
- Modify: `lib/scope.nix:104-115` (the `mkBakeFile` definition)
- Test: `tests/bake-file.nix`, `tests/integration.nix`

Replaces `mkBakeFile { scope, module = "name" }` with `mkBakeFile module`, where `module` is any resolved module value (it carries `_scope` from Task 1).

- [ ] **Step 1: Rewrite `mkBakeFile` to take a module value**

Replace the current `mkBakeFile` block in `lib/scope.nix` (lines 104-115) with:

```nix
  # Generate a docker-bake.json file as a Nix-store path.
  # Takes a resolved module value (from scope.modules.X or scope.X).
  # The module carries a _scope back-reference so cross-module target
  # identity resolution in the serializer has what it needs.
  #
  # builtins.unsafeDiscardStringContext is needed because builtins.toFile
  # cannot reference store paths produced by builtins.path (used by mkContext).
  # The context paths are already realized at eval time and Docker reads them
  # at runtime, so Nix dependency tracking on the bake file is not needed.
  mkBakeFile =
    module:
    let
      scope =
        module._scope
          or (throw "mkBakeFile: module is missing _scope back-reference; was it produced by mkScope?");
      serialized = serialize.serialize scope module;
    in
    builtins.toFile "docker-bake.json" (
      builtins.unsafeDiscardStringContext (builtins.toJSON serialized)
    );
```

- [ ] **Step 2: Migrate `tests/bake-file.nix` to the new signature**

Replace lines 21-24:

```nix
  bakeFilePath = mkBakeFile scope.modules.test;
```

(Leaving the surrounding `parsed = builtins.fromJSON ...` and assertions untouched.)

- [ ] **Step 3: Migrate `tests/integration.nix` to the new signature**

Replace the `parse` helper (currently lines 26-32):

```nix
  parse =
    moduleName:
    builtins.fromJSON (builtins.readFile (mkBakeFile scope.modules.${moduleName}));
```

Replace the `extBaseSer` definition (currently lines 41-46):

```nix
  extBaseSer = builtins.fromJSON (
    builtins.readFile (mkBakeFile extendedScope.modules.base)
  );
```

Replace the `cwsAParsed` / `cwsBParsed` definitions (currently lines 76-87):

```nix
  cwsAParsed = builtins.fromJSON (
    builtins.readFile (mkBakeFile cwsScope.modules.a)
  );
  cwsBParsed = builtins.fromJSON (
    builtins.readFile (mkBakeFile cwsScope.modules.b)
  );
```

- [ ] **Step 4: Run `nix flake check` to verify**

Run: `nix flake check`
Expected: `all tests passed (...)`. If tests referencing `_scope` from Task 1 somehow interact with serialization (they should not — `_scope` is keyed by `_` prefix and `serialize` already uses an allowlist), investigate; the serializer consults `scope.modules.X.targets`, not arbitrary module keys, so the back-reference should pass through invisibly.

- [ ] **Step 5: Format and commit**

```bash
nix fmt
git add lib/scope.nix tests/bake-file.nix tests/integration.nix
git commit -m "feat!: mkBakeFile takes a module value instead of { scope, module = \"name\" }"
```

---

## Task 3: Expose `lib.extend` on the per-module lib

**Files:**
- Modify: `lib/scope.nix:31-65` (the `libFunctions` attrset inside `scopeFn`)
- Test: `tests/scope.nix`

Currently module authors fork the scope via `lib.callBakeWithScope "name" overlay`. After this task they can write `(lib.extend overlay).modules.name`. This reuses the same fixed-point fork mechanism that `scope.extend` uses, exposed via the per-module `lib`.

- [ ] **Step 1: Add failing test for `lib.extend`**

The simplest proof is to fork an existing scope's `lib` and verify the fork propagates an overlay to its modules. Reuse the existing `scope1` fixture in `tests/scope.nix` — no new fixtures needed, and Task 4 will migrate the other existing fixtures onto `lib.extend`.

Add to the `let` block in `tests/scope.nix` (next to the existing `extendedScope` binding around line 75):

```nix
  libExtendedScope = scope1.lib.extend (final: prev: { myConfigValue = "lib-extended"; });
```

Add to the outer attrset in a new section before the closing `}`:

```nix
  # ---------- lib.extend ----------

  testLibExtendForksScope = {
    expr = libExtendedScope.modules.test.targets.main.args.VAL;
    expected = "lib-extended";
  };

  testLibExtendDoesNotMutateOriginalScope = {
    expr = scope1.test.targets.main.args.VAL;
    expected = "hello";
  };
```

- [ ] **Step 2: Run `nix flake check` to verify the test fails**

Run: `nix flake check`
Expected: failure mentioning `testLibExtendForksScope` and `testLibExtendDoesNotMutateOriginalScope`; typically an "attribute 'extend' missing" trace.

- [ ] **Step 3: Add `extend` to `libFunctions`**

This is an additive edit: insert a single line between the existing `callBake` entry (ends at `lib/scope.nix:43`) and the existing `callBakeWithScope` entry (starts around `lib/scope.nix:45` with a comment block).

Before:

```nix
              core.checkModule modulePath module;

            # callBakeWithScope: fork the scope with an overlay and re-resolve
            # a registered module under the fork. ...
            callBakeWithScope =
```

After (insert an `extend` entry between `callBake`'s closing line and `callBakeWithScope`'s comment):

```nix
              core.checkModule modulePath module;

            # Fork the scope with an overlay and return the forked scope.
            # Consumers typically access `.modules.<name>` on the result to
            # pull in a specific module resolved under the fork. Transitive
            # callBake calls inside the resolved module see the overlay.
            extend = overlay: nixLib.fix (nixLib.extends overlay scopeFn);

            # callBakeWithScope: fork the scope with an overlay and re-resolve
            # a registered module under the fork. ...
            callBakeWithScope =
```

Do not touch `callBakeWithScope` in this task — it is removed in Task 4.

- [ ] **Step 4: Run `nix flake check` to verify all tests pass**

Run: `nix flake check`
Expected: `all tests passed (...)`.

- [ ] **Step 5: Format and commit**

```bash
nix fmt
git add lib/scope.nix tests/scope.nix
git commit -m "feat(scope): expose lib.extend for forking the scope from inside a module"
```

---

## Task 4: Remove `callBakeWithScope`

**Files:**
- Modify: `lib/scope.nix` (remove the `callBakeWithScope` entry from `libFunctions`)
- Modify: `tests/scope.nix` (migrate `callBakeWithScope` tests to `lib.extend`)
- Modify: `tests/integration.nix` (migrate the `cws-b.nix` fixture string)

- [ ] **Step 1: Migrate the `callBakeWithScope` cases in `tests/scope.nix`**

Leave `aFile` (`tests/scope.nix:30-37`) and the `scope2` binding (`tests/scope.nix:48-56`) unchanged — only the `bFile` body needs migration (it is the file that calls `callBakeWithScope`).

Replace the `bFile` fixture (currently `tests/scope.nix:38-47`) with a version using `lib.extend`:

```nix
  bFile = builtins.toFile "cbws-b.nix" ''
    { lib, ... }:
    let
      aOverridden = (lib.extend (final: prev: { val = "overridden"; })).modules.a;
    in {
      namespace = "b";
      targets = { t = lib.mkTarget { context = ./.; contexts.root = aOverridden.targets.t; }; };
      groups = {};
    }
  '';
```

Replace the `cwsMkCtxForked` binding (currently `tests/scope.nix:70-72`):

```nix
  cwsMkCtxForked = (cwsMkCtxScope.lib.extend (final: prev: { val = "overridden"; })).modules.forkable;
```

Rename the tests for clarity (and to avoid stale "callBakeWithScope" naming leaking into a post-removal codebase). In `tests/scope.nix`, replace the section header and the six tests that mention `callBakeWithScope` (currently lines 135-174):

```nix
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
      (builtins.tryEval (cwsMkCtxScope.lib.extend (_: _: { })).modules.nonexistent).success;
    expected = false;
  };
```

**Accepted DX tradeoff:** the "unknown module throws" assertion now relies on Nix's default `error: attribute 'nonexistent' missing` rather than the previous custom `callBakeWithScope: module '...' not found. Available modules: ...` message. This is a deliberate choice — nixpkgs surfaces the same class of error the same way (`pkgs.nonexistent` does not list available packages), and wrapping `.modules` with a custom throw would add machinery that consumers would then have to learn around. Do not add a follow-up for this; it is resolved by acceptance.

- [ ] **Step 2: Migrate `tests/integration.nix` `cws-b.nix` fixture and stale comments**

Replace the `cwsBFile` fixture (currently `tests/integration.nix:58-66`):

```nix
  cwsBFile = builtins.toFile "cws-b.nix" ''
    { lib, ... }:
    let a = (lib.extend (final: prev: { val = "overridden"; })).modules.a;
    in {
      namespace = "b";
      targets = { t = lib.mkTarget { context = ./.; contexts.root = a.targets.t; }; };
      groups = {};
    }
  '';
```

Update the stale `callBakeWithScope` comments so the Self-Review grep passes:

- `tests/integration.nix:48` — change `# callBakeWithScope: inline modules ...` to `# lib.extend: inline modules (builtins.toFile) since they don't need mkContext.`
- `tests/integration.nix:255` — change `# ---------- Scenario 6: callBakeWithScope through mkBakeFile ----------` to `# ---------- Scenario 6: lib.extend through mkBakeFile ----------`

Leave the `cws*` symbol names (`cwsAFile`, `cwsBFile`, `cwsScope`, `cwsAParsed`, `cwsBParsed`) and the `testIntCws*` test names as-is — they are internal identifiers, not references to `callBakeWithScope`, and renaming them is out of scope for this refactor.

- [ ] **Step 3: Remove `callBakeWithScope` from `lib/scope.nix`**

Delete the `callBakeWithScope` entry from `libFunctions` (`lib/scope.nix:45-64` — this covers the comment block starting at line 45 and the function body ending at line 64). The `libFunctions` attrset shrinks to: `mkTarget`, `mkContext`, `mkContextWith`, `callBake`, `extend`.

- [ ] **Step 4: Run `nix flake check` to verify all tests pass**

Run: `nix flake check`
Expected: `all tests passed (...)`. If any test still references `callBakeWithScope`, grep for it and migrate (`grep -r callBakeWithScope lib/ tests/` must return nothing).

- [ ] **Step 5: Format and commit**

```bash
nix fmt
git add lib/scope.nix tests/scope.nix tests/integration.nix
git commit -m "refactor!: remove lib.callBakeWithScope in favor of lib.extend"
```

---

## Task 5: Add `override` sugar on `scope` and `lib`

**Files:**
- Modify: `lib/scope.nix` (add `override` on the scope attrset and in `libFunctions`; add `"override"` to `reservedNames`)
- Test: `tests/scope.nix`

Pure sugar. `scope.override attrs` = `scope.extend (_: _: attrs)`. Same for `lib.override`. Matches the nixpkgs convention where `override` takes a plain attrset of replacement values and `extend` takes an overlay function. Since `override` becomes a scope-level attribute, add it to `reservedNames` so a module named `override` can't silently shadow the sugar.

- [ ] **Step 1: Add failing tests for `override` sugar**

Append to `tests/scope.nix` (inside the `let` block, then inside the outer attrset):

```nix
  # Inside the let block:
  scopeOverridden = scope1.override { myConfigValue = "overridden-via-override"; };

  libOverrideAFile = builtins.toFile "libov-a.nix" ''
    { lib, val, ... }:
    {
      namespace = "a";
      targets = { t = lib.mkTarget { context = ./.; args.VAL = val; }; };
      groups = {};
    }
  '';
  libOverrideBFile = builtins.toFile "libov-b.nix" ''
    { lib, ... }:
    let
      aOverridden = (lib.override { val = "via-lib-override"; }).modules.a;
    in {
      namespace = "b";
      targets = { t = lib.mkTarget { context = ./.; contexts.root = aOverridden.targets.t; }; };
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
```

```nix
  # In the outer attrset, in a new section before the closing `}`:

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

  testMkScopeRejectsReservedNameOverride = {
    expr =
      (builtins.tryEval (mkScope {
        config = { };
        modules.override = scopeTestModuleFile;
      })).success;
    expected = false;
  };
```

- [ ] **Step 2: Run `nix flake check` to verify the tests fail**

Run: `nix flake check`
Expected: failure with the four new tests in the JSON list. The first three error on missing `override` attribute; `testMkScopeRejectsReservedNameOverride` fails because `override` is not yet in `reservedNames` — registering a module named `override` still succeeds pre-implementation.

- [ ] **Step 3: Implement `override` on both scope and lib, and reserve the name**

Add `"override"` to the `reservedNames` list in `lib/scope.nix` (currently `lib/scope.nix:17-21`):

```nix
      reservedNames = [
        "lib"
        "extend"
        "override"
        "modules"
      ];
```

In the scope attrset (near the existing `extend` entry — line numbers will have shifted from 75 due to prior tasks; locate by searching for `extend = overlay:` in the scope attrset, not in `libFunctions`), add `override` directly beneath `extend`:

```nix
          # Return a new scope with the given overlay applied.
          extend = overlay: nixLib.fix (nixLib.extends overlay scopeFn);

          # Plain-attrs sugar over extend. Use this when you just want to
          # replace config values; reach for extend when you need the
          # (final: prev: ...) form (e.g., self-referential rewrites).
          override = attrs: nixLib.fix (nixLib.extends (_: _: attrs) scopeFn);
```

And in `libFunctions`, directly beneath the `extend` entry added in Task 3:

```nix
            extend = overlay: nixLib.fix (nixLib.extends overlay scopeFn);
            override = attrs: nixLib.fix (nixLib.extends (_: _: attrs) scopeFn);
```

- [ ] **Step 4: Run `nix flake check` to verify all tests pass**

Run: `nix flake check`
Expected: `all tests passed (...)`.

- [ ] **Step 5: Format and commit**

```bash
nix fmt
git add lib/scope.nix tests/scope.nix
git commit -m "feat(scope): add override sugar on scope and lib (plain-attrs form of extend)"
```

---

## Task 6: Rewrite `API.md`

**Files:**
- Modify: `API.md`

The doc currently describes `mkBakeFile { scope, module }`, `scope.extend overlay`, and has no entries for `lib.extend`, `lib.override`, `scope.override`. It references `callBakeWithScope` which no longer exists.

- [ ] **Step 1: Replace the `mkBakeFile` section**

Replace the `## mkBakeFile { scope, module }` block (currently `API.md:75-79`) with:

````markdown
## `mkBakeFile module`

Serializes a module's target graph and writes it via `builtins.toFile`.
Returns a Nix store path directly usable with `docker buildx bake -f`.
The argument is a resolved module value (typically obtained from `scope.modules.<name>` or from `scope.<name>`).
The module carries a hidden back-reference to its originating scope, which the serializer uses to resolve cross-module target identities.

```nix
bakeFile = bake.lib.mkBakeFile scope.modules.hello;
```
````

- [ ] **Step 2: Replace the `scope.extend overlay` section**

Replace the `## scope.extend overlay` block (currently `API.md:81-92`) with:

````markdown
## `scope.extend overlay`

Method on the scope returned by `mkScope`.
Produces a new scope with the given overlay applied; the original scope is unaffected.
The overlay has the standard nixpkgs shape `final: prev: { ... }`.

Use this to layer persistent customizations for a subtree of consumer code (e.g., "a dev scope with a newer app version") rather than forking per-module from within another module.

```nix
devScope = scope.extend (final: prev: { appVersion = "v2.0.0"; });
devBakeFile = bake.lib.mkBakeFile devScope.modules.app;
```

## `scope.override attrs`

Plain-attrs sugar for the common case of `scope.extend (_: _: attrs)`.
Reach for `override` when you are replacing config values; use `extend` when you need the `final: prev: ...` form (e.g., self-referential rewrites).

```nix
devScope = scope.override { appVersion = "v2.0.0"; };
```

## `lib.extend overlay`

Available on the per-module `lib` injected into modules resolved by `mkScope`.
Forks the enclosing scope with the given overlay and returns the forked scope; access modules via `.modules.<name>`.
Every transitive dependency re-resolves with the overlay applied.

```nix
# Inside a bake module
{ lib, ... }:
let
  kubeadm = (lib.extend (final: prev: { kubeVersion = "v1.35.0"; })).modules.kubeadm;
in { ... }
```

## `lib.override attrs`

Plain-attrs sugar over `lib.extend`, mirroring `scope.override`.

```nix
# Inside a bake module
{ lib, ... }:
let
  kubeadm = (lib.override { kubeVersion = "v1.35.0"; }).modules.kubeadm;
in { ... }
```
````

- [ ] **Step 3: Run `nix flake check` to verify docs didn't break anything**

Run: `nix flake check`
Expected: `all tests passed (...)`. (Doc changes shouldn't affect tests, but a sanity run is cheap.)

- [ ] **Step 4: Format and commit**

```bash
nix fmt
git add API.md
git commit -m "docs(api): rewrite API.md for new scope/lib surface"
```

---

## Task 7: Rewrite `README.md`

**Files:**
- Modify: `README.md`

Touches two areas: the "A bake file" example (string-keyed `mkBakeFile` form) and the "Overrides" section (table, `callBakeWithScope` subsection, table's recommended API names).

- [ ] **Step 1: Update the "A bake file" example**

Replace the code block at `README.md:89-105`:

````markdown
```nix
# flake.nix
{
  inputs.bake.url = "github:sagikazarmar/nix-docker-bake";
  inputs.bake.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { bake, ... }:
    let
      scope = bake.lib.mkScope {
        config  = { };
        modules = { hello = ./hello.nix; };
      };
    in
    {
      bakeFile = bake.lib.mkBakeFile scope.modules.hello;
    };
}
```
````

- [ ] **Step 2: Update the Overrides table**

Replace the table at `README.md:173-180` with:

```markdown
| You want to... | Use |
|---|---|
| Override a dep in one module, leave siblings alone | `lib.callBake path { specificDep = ...; }` |
| Replace a config value everywhere in the scope (plain attrs) | `(lib.override { key = ...; }).modules.<name>` |
| Same, but with access to prior values / self-reference | `(lib.extend (final: prev: { key = ...; })).modules.<name>` |
| Override a value in some transitive deps but not others | `lib.callBake path { ...; dep = lib.callBake ../dep.nix { ... }; }` (selective) |
```

- [ ] **Step 3: Replace the "Deep override (`callBakeWithScope`)" subsection**

Replace `README.md:196-207` with:

````markdown
### Deep override (`lib.extend` / `lib.override`)

`lib.extend overlay` forks the entire scope with an overlay, then returns the forked scope.
Access modules on it via `.modules.<name>`.
Every transitive dependency re-resolves with the overlay applied.

```nix
# Every module in the forked scope that reads appVersion sees v2.0.0,
# including transitive deps.
customApp = (lib.extend (final: prev: { appVersion = "v2.0.0"; })).modules.app;
```

For the common case of replacing config values, use `lib.override` as sugar:

```nix
customApp = (lib.override { appVersion = "v2.0.0"; }).modules.app;
```

The same pair is available on the scope value itself — use `scope.extend` / `scope.override` when you have a scope in hand (typically in the outer consumer), and the `lib.*` forms when you are inside a module.
````

- [ ] **Step 4: Verify no stale references remain**

Run: `grep -n callBakeWithScope README.md API.md`
Expected: no matches.

Run: `grep -n 'module = "' README.md API.md`
Expected: no matches (no more string-keyed `mkBakeFile` arg in docs).

- [ ] **Step 5: Run `nix flake check` for sanity**

Run: `nix flake check`
Expected: `all tests passed (...)`.

- [ ] **Step 6: Format and commit**

```bash
nix fmt
git add README.md
git commit -m "docs(readme): update overrides and bake-file example for new API"
```

---

## Self-Review Checklist (for the reviewer)

Run this pass after all tasks land — it is a cheap last sanity check before opening the PR.

- [ ] `grep -rn callBakeWithScope lib/ tests/ README.md API.md` — zero results.
- [ ] `grep -rn 'module = "' lib/ tests/ README.md API.md` — zero results (the pattern itself may appear inside generated JSON strings elsewhere, but not as an API call form in source/docs).
- [ ] `nix flake check` — passes.
- [ ] `nix fmt` — no diff after running.
- [ ] README and API.md examples are runnable end-to-end (conceptually; they reference `hello.nix` which the reader writes).
- [ ] Commit history is a coherent story: six small commits, each independently reviewable.
