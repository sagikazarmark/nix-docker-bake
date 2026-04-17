# Target `.overrideAttrs` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `extendTarget` with a nixpkgs-style `.overrideAttrs` method on every target produced by `mkTarget`, removing the implicit merge policy and giving callers explicit control.

**Architecture:** `mkTarget` attaches an `.overrideAttrs` function to the target attrset. The function accepts either `old -> attrs` or a plain attrset; the returned attrs shallow-merge (`//`) onto the current target, the combined value is re-validated by re-invoking `mkTarget`, and the result carries its own `.overrideAttrs` so calls chain. `extendTarget` is deleted outright — no deprecation.

**Tech Stack:** Nix (plain Nix, no nixpkgs lib in-library). Tests live in `tests/*.nix` and run via `nix flake check`. Formatter is `nix fmt` (nixfmt-tree).

**Spec reference:** `docs/superpowers/specs/2026-04-17-target-override-attrs-design.md`

---

## File Map

- `lib/core.nix` — `mkTarget` body is restructured to attach `.overrideAttrs`; `extendTarget` definition is removed.
- `lib/default.nix` — drop `extendTarget` from the `inherit (core) ...` re-export list.
- `lib/scope.nix` — drop `extendTarget` from the per-module `libFunctions` re-export.
- `tests/target.nix` — remove the `extendTarget` test block; add an `overrideAttrs` test block covering replace / merge / append / chain / validate / passthru cases.
- `API.md` — remove `extendTarget` section; add `.overrideAttrs` section.
- `README.md` — no changes needed (grep confirms no `extendTarget` references in README today).

---

## Task 1: Replace `extendTarget` tests with `.overrideAttrs` tests, implement `.overrideAttrs`

**Files:**
- Modify: `tests/target.nix` (rewrite the `extendTarget` block; update imports)
- Modify: `lib/core.nix` (restructure `mkTarget` to attach `.overrideAttrs`)

- [ ] **Step 1: Rewrite the test file — update import and replace the `extendTarget` block**

Change the `let` header in `tests/target.nix` from:

```nix
  inherit (bake) mkTarget extendTarget;
```

to:

```nix
  inherit (bake) mkTarget;
```

Then remove the `extended`, `extended2`, `extendedCtx` bindings (lines ~23–50) and replace them with:

```nix
  baseTarget = mkTarget {
    context = ./.;
    args = {
      A = "1";
      B = "2";
    };
  };

  # Function form: merge by referencing old values.
  mergedArgs = baseTarget.overrideAttrs (old: {
    args = old.args // {
      B = "x";
      C = "3";
    };
  });

  # Function form: pure replacement (ignore old).
  replacedArgs = baseTarget.overrideAttrs (_: {
    args = {
      Z = "9";
    };
  });

  # Attrset form: shorthand for replacement (no `old` access).
  shorthandReplaced = baseTarget.overrideAttrs {
    args = {
      Z = "9";
    };
  };

  # Function form: append to a list (inexpressible under extendTarget).
  withExtraTag =
    let
      base = mkTarget {
        context = ./.;
        tags = [ "a" ];
      };
    in
    base.overrideAttrs (old: {
      tags = old.tags ++ [ "b" ];
    });

  # Chaining: each call returns a target with its own overrideAttrs.
  chained =
    (baseTarget.overrideAttrs (_: {
      args = {
        X = "1";
      };
    })).overrideAttrs
      (old: {
        args = old.args // {
          Y = "2";
        };
      });

  withCtx = mkTarget {
    context = ./.;
    contexts = {
      root = "base";
      config = "x";
    };
  };
  mergedCtx = withCtx.overrideAttrs (old: {
    contexts = old.contexts // {
      root = "override";
      extra = "new";
    };
  });
```

Then replace the entire `# ---------- extendTarget ----------` block (everything from the comment through the closing brace of the outer attrset `}` that ends the file) with:

```nix
  # ---------- overrideAttrs ----------

  testOverrideAttrsMergePreservesExistingArg = {
    expr = mergedArgs.args.A;
    expected = "1";
  };

  testOverrideAttrsMergeOverridesArg = {
    expr = mergedArgs.args.B;
    expected = "x";
  };

  testOverrideAttrsMergeAddsArg = {
    expr = mergedArgs.args.C;
    expected = "3";
  };

  testOverrideAttrsReplaceDropsOldArgs = {
    expr = replacedArgs.args ? A;
    expected = false;
  };

  testOverrideAttrsReplaceSetsNewArgs = {
    expr = replacedArgs.args.Z;
    expected = "9";
  };

  testOverrideAttrsAttrsetFormIsShorthand = {
    expr = shorthandReplaced.args;
    expected = {
      Z = "9";
    };
  };

  testOverrideAttrsAppendsToTags = {
    expr = withExtraTag.tags;
    expected = [
      "a"
      "b"
    ];
  };

  testOverrideAttrsChainable = {
    expr = chained.args;
    expected = {
      X = "1";
      Y = "2";
    };
  };

  testOverrideAttrsMergesContextsOverride = {
    expr = mergedCtx.contexts.root;
    expected = "override";
  };

  testOverrideAttrsMergesContextsPreserve = {
    expr = mergedCtx.contexts.config;
    expected = "x";
  };

  testOverrideAttrsMergesContextsAdd = {
    expr = mergedCtx.contexts.extra;
    expected = "new";
  };

  testOverrideAttrsRejectsUnknownKeys = {
    expr =
      (builtins.tryEval (baseTarget.overrideAttrs {
        foo = "bar";
      })).success;
    expected = false;
  };

  testOverrideAttrsPreservesPassthruWhenNotTouched =
    let
      base = mkTarget {
        context = ./.;
        passthru = {
          pushRef = "oci://example/x:abc";
        };
      };
      patched = base.overrideAttrs (_: { tags = [ "t" ]; });
    in
    {
      expr = patched.passthru.pushRef;
      expected = "oci://example/x:abc";
    };

  testOverrideAttrsReplacesPassthruWholesale =
    let
      base = mkTarget {
        context = ./.;
        passthru = {
          a = "1";
          b = "2";
        };
      };
      patched = base.overrideAttrs (_: {
        passthru = {
          b = "x";
        };
      });
    in
    {
      expr = patched.passthru;
      expected = {
        b = "x";
      };
    };

  testOverrideAttrsMergesPassthruViaOld =
    let
      base = mkTarget {
        context = ./.;
        passthru = {
          a = "1";
          b = "2";
        };
      };
      patched = base.overrideAttrs (old: {
        passthru = old.passthru // {
          b = "x";
        };
      });
    in
    {
      expr = patched.passthru;
      expected = {
        a = "1";
        b = "x";
      };
    };
}
```

Leave the `# ---------- mkTarget ----------` block and its tests untouched.

- [ ] **Step 2: Run the tests and verify they fail**

Run: `nix flake check 2>&1 | tail -30`

Expected: failure. Message will include something like `attribute 'overrideAttrs' missing` from one of the new tests — because `mkTarget`'s output doesn't yet have `.overrideAttrs`.

- [ ] **Step 3: Implement `.overrideAttrs` in `mkTarget`**

In `lib/core.nix`, replace the current `mkTarget` definition (lines 7–29) with:

```nix
  mkTarget =
    attrs:
    let
      allowedKeys = [
        "context"
        "dockerfile"
        "target"
        "contexts"
        "args"
        "tags"
        "platforms"
        "passthru"
      ];
      unknownKeys = builtins.filter (k: !(builtins.elem k allowedKeys)) (builtins.attrNames attrs);
      validated =
        assert attrs ? context || throw "mkTarget: 'context' is required";
        assert
          unknownKeys == [ ]
          || throw "mkTarget: unknown key(s): ${builtins.concatStringsSep ", " unknownKeys} (allowed: ${builtins.concatStringsSep ", " allowedKeys})";
        {
          dockerfile = "Dockerfile";
        }
        // attrs;
      target = validated // {
        # Extend this target with a patch. `f` is either an attrset (shorthand,
        # ignores current values) or a function `old -> attrs` where `old` is
        # the current target. The returned attrs shallow-merge onto the current
        # target via `//`; the result is re-validated through `mkTarget` so
        # unknown keys still throw, and the result carries its own
        # `.overrideAttrs` for chaining.
        overrideAttrs =
          f:
          let
            patch = if builtins.isFunction f then f target else f;
            merged = builtins.removeAttrs (target // patch) [ "overrideAttrs" ];
          in
          mkTarget merged;
      };
    in
    target;
```

Note: `extendTarget` (the old function, lines 31–53) stays in the file for now — it's removed in Task 2.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `nix flake check 2>&1 | tail -10`

Expected: success (exit 0, no output from `nix flake check`, or the final success line from tests/default.nix).

- [ ] **Step 5: Format**

Run: `nix fmt`

Expected: no changes or only cosmetic whitespace changes. Verify with `git diff --stat`.

- [ ] **Step 6: Commit**

```bash
git add lib/core.nix tests/target.nix
git commit -m "$(cat <<'EOF'
feat: add .overrideAttrs to targets

mkTarget now attaches an .overrideAttrs method to every target. The method
accepts either an attrset (pure replacement) or a function old -> attrs
(merge with access to previous values). Returned attrs shallow-merge via //
and the result is re-validated through mkTarget, so unknown keys still
throw and the result chains.
EOF
)"
```

---

## Task 2: Remove `extendTarget` from the library

**Files:**
- Modify: `lib/core.nix` (delete the `extendTarget` definition)
- Modify: `lib/default.nix` (drop from `inherit` list)
- Modify: `lib/scope.nix` (drop from per-module `libFunctions` inherit)

- [ ] **Step 1: Remove `extendTarget` from `lib/core.nix`**

Delete the entire `extendTarget` block. After Task 1 it lives at roughly lines 48–66 (the block starts with the comment `# Extend a base target with a patch. Atomic fields...` and ends at the closing `);` of the `//` chain). Replace with nothing — the file goes straight from `mkTarget`'s closing `in target;` to the `mkContext` comment.

After this edit, the file contains (in order): `mkTarget`, `mkContext`, `checkModule`. No `extendTarget`.

- [ ] **Step 2: Remove `extendTarget` from `lib/default.nix`**

Change the inherit block from:

```nix
  inherit (core)
    mkTarget
    checkModule
    extendTarget
    mkContext
    ;
```

to:

```nix
  inherit (core)
    mkTarget
    checkModule
    mkContext
    ;
```

- [ ] **Step 3: Remove `extendTarget` from `lib/scope.nix`**

Change line 33 from:

```nix
            inherit (core) mkTarget extendTarget mkContext;
```

to:

```nix
            inherit (core) mkTarget mkContext;
```

- [ ] **Step 4: Run all tests**

Run: `nix flake check 2>&1 | tail -20`

Expected: success. Integration tests in `tests/integration.nix` exercise cross-module context references (e.g., `contexts.root = a.targets.t`), which depend on attrset equality working in `serialize.nix`'s `findIdentity`. If those tests pass, attrset equality across targets-with-`.overrideAttrs` is working correctly. If they fail, stop and investigate — do not proceed.

- [ ] **Step 5: Format**

Run: `nix fmt`

- [ ] **Step 6: Commit**

```bash
git add lib/core.nix lib/default.nix lib/scope.nix
git commit -m "$(cat <<'EOF'
feat!: remove extendTarget

extendTarget is replaced by the .overrideAttrs method added in the previous
commit. Callers that used `extendTarget base patch` now write
`base.overrideAttrs (old: patch)` (merge) or `base.overrideAttrs patch`
(replace), picking the merge semantics explicitly at each call site.

BREAKING CHANGE: extendTarget is removed. No deprecation shim.
EOF
)"
```

---

## Task 3: Update `API.md`

**Files:**
- Modify: `API.md` (replace the `extendTarget` section with an `.overrideAttrs` section)

- [ ] **Step 1: Replace the `extendTarget` section**

In `API.md`, locate the section that starts with:

```markdown
## `extendTarget base patch`
```

…and ends at the blank line before `## `mkContext prefix path``. Replace the entire section (heading plus body) with:

```markdown
## `target.overrideAttrs f`

Every target produced by `mkTarget` carries an `.overrideAttrs` method.
It accepts either a function `old -> attrs` or a plain attrset.
The returned attrs shallow-merge onto the current target via `//`, and the result is re-validated through `mkTarget` (so unknown keys still throw, `context` is still required).
The result carries its own `.overrideAttrs`, so calls chain.

No merge policy is applied to any field — each call site writes exactly the merge it wants.

```nix
# Replace args wholesale (attrset form — shorthand).
t.overrideAttrs { args = { FOO = "bar"; }; }

# Merge args — reference old values.
t.overrideAttrs (old: { args = old.args // { FOO = "bar"; }; })

# Append to tags (not expressible via any fixed merge policy).
t.overrideAttrs (old: { tags = old.tags ++ [ "extra" ]; })
```
```

Note the triple-backtick handling: the nix code block inside the section uses three backticks; the section example here uses four because it's nested in this plan. When writing to `API.md`, use three backticks around the nix block.

- [ ] **Step 2: Verify the file still renders sensibly**

Run: `cat API.md | head -40` and scan for broken markdown, orphaned references, or duplicate headings.

Expected: `mkTarget` section, then `target.overrideAttrs f` section, then `mkContext`, etc. No reference to `extendTarget` anywhere.

Double-check: `grep -n extendTarget API.md` — expected: no output.

- [ ] **Step 3: Commit**

```bash
git add API.md
git commit -m "$(cat <<'EOF'
docs: replace extendTarget reference with .overrideAttrs

Document the new override method: signature, the two call forms (function
and attrset shorthand), and one example for each of replace / merge / append.
EOF
)"
```

---

## Self-Review Checklist (completed)

**Spec coverage:**
- "Replace extendTarget with .overrideAttrs" → Tasks 1 + 2.
- "Both function and attrset forms" → Task 1 Step 1 (tests cover both), Task 1 Step 3 (impl handles both via `isFunction`).
- "Re-validate via mkTarget" → Task 1 Step 3 (body calls `mkTarget merged`).
- "Chainability" → Task 1 Step 1 (`chained` binding + test), inherent because `mkTarget` attaches `.overrideAttrs` to every result.
- "Tests: replace / merge / append / chain / validate / passthru" → Task 1 Step 1 (all six cases covered).
- "Remove from core, default, scope" → Task 2 Steps 1–3.
- "Update API.md" → Task 3.
- "No README change needed" → confirmed via `grep extendTarget README.md` (no hits).

**Placeholder scan:** No "TBD", "TODO", "similar to", or vague handwaves. Every code block is complete.

**Type / name consistency:** `.overrideAttrs` (camelCase) used consistently everywhere. `baseTarget` used consistently in test bindings. Implementation uses `builtins.removeAttrs` to match the rest of `lib/core.nix`, which prefixes all builtins (`builtins.filter`, `builtins.elem`, etc.).
