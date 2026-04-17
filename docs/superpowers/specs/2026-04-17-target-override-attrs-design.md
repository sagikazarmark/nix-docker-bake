# Target `.overrideAttrs`: replace `extendTarget` with explicit override

## Summary

Replace the `extendTarget` function with an `.overrideAttrs` method attached to every target produced by `mkTarget`. The new API mirrors nixpkgs conventions, removes the implicit merge policy baked into `extendTarget`, and gives callers explicit control over how each field is combined with its previous value.

`extendTarget` is removed without a deprecation period.

## Motivation

The current `extendTarget base patch` function applies a fixed merge policy:

- atomic fields (`context`, `dockerfile`, `target`, `tags`, `platforms`, `passthru`) are replaced wholesale when the patch sets them;
- attrset fields (`args`, `contexts`) are deep-merged with patch keys winning.

This has two problems:

1. **The policy is opaque.** Callers have to remember which fields merge and which replace. The split is arbitrary from the caller's perspective — `tags` is a list and replaces, `contexts` is an attrset and merges, but there is no policy for a caller who wants to *append* to `tags` or *replace* `args` wholesale.
2. **Some cases are inexpressible.** Appending to `tags`, or selectively dropping keys from `args`, cannot be done through `extendTarget` at all. Callers who want those semantics must bypass the helper and hand-roll a `//` expression.

nixpkgs's `.overrideAttrs (old: ...)` pattern solves both: the caller writes the exact merge they want, with access to the previous value.

Familiarity is a secondary benefit: users who have written nixpkgs overlays recognise the shape immediately.

## Design

### The method

`mkTarget` attaches an `.overrideAttrs` function to every target it constructs. The function accepts either a function `old -> attrs` or a plain attrs value:

```nix
# Function form — access previous values
t.overrideAttrs (old: { tags = old.tags ++ [ "extra" ]; })

# Attrset form — ignore old, convenient for pure replacement
t.overrideAttrs { args = { FOO = "bar"; }; }
```

Both forms return a new target. The returned attrs are merged onto `old` via `//` (shallow). Nothing is deep-merged; if the caller wants `old.args // { FOO = "bar"; }`, they write it explicitly.

### Behaviour

- **Shallow merge via `//`.** The result is `old // (f old)` where `f` normalises the attrset form into `_: attrs`.
- **Validation.** The merged attrset goes back through `mkTarget`'s allowlist check, so unknown keys still throw. `context` is required in the result; an override that dropped `context` would fail.
- **Chainability.** The returned target has its own `.overrideAttrs` so `t.overrideAttrs(f).overrideAttrs(g)` works.
- **`//` compatibility.** Plain `existing // { foo = ...; }` still works and preserves `.overrideAttrs` on the result, because `//` takes the left-hand side's field when the right-hand side doesn't set it.

### Removal of `extendTarget`

`extendTarget` is removed from `lib/core.nix`, from `lib/default.nix` re-exports, and from `API.md`. No deprecation shim. The README / API.md get a replacement section documenting `.overrideAttrs` with examples for the three common modes (replace, merge, append).

Existing call sites in the repo are updated. Callers outside the repo who used `extendTarget` will get a missing-attribute error; the error surfaces immediately at evaluation time, which is the kind of breakage Nix handles well.

### Scope boundaries

- **Only targets get `.overrideAttrs`.** Modules do not. Modules are resolved through the scope via `callBake` / `callBakeWithScope`, which already handles argument overrides; adding a second mechanism on top of that is a separate design question.
- **No `.override` on targets.** nixpkgs's `.override` re-invokes a function with different args; targets are leaf attrsets, not function calls, so there is no sensible mapping.
- **Scope-level `.override`** (sugar over `callBake`) is out of scope for this change and will be considered separately.

## API after change

```nix
# lib/core.nix (sketch)
mkTarget = attrs: let
  core = /* validate + default, as today */;
  target = core // {
    overrideAttrs = f: let
      patch = if builtins.isFunction f then f target else f;
    in mkTarget (removeAttrs (target // patch) [ "overrideAttrs" ]);
  };
in target;
```

The `removeAttrs` strip before re-calling `mkTarget` keeps `overrideAttrs` from appearing in the pre-validation attrs (otherwise the allowlist would reject it). `mkTarget` re-attaches it on the way out.

## Consequences

### What's unchanged

- Reading fields: `t.context`, `t.args.FOO`, `t.tags` — identical.
- Serialization: the bake-file serializer already filters via an allowlist, so `.overrideAttrs` does not leak into output.
- `existing // { foo = ...; }`: unchanged and still preserves `.overrideAttrs` on the result.

### What changes

- `builtins.attrNames t` now includes `"overrideAttrs"`. Anything that iterates all keys without filtering will see it. The serializer already filters; no other in-tree code iterates target keys.
- `builtins.toJSON t` applied directly to a target now fails (functions aren't JSON-serializable). No in-tree code does this; `toBakeFile` goes through the allowlist first.
- Functions show as `<LAMBDA>` when a target is traced or pretty-printed. Cosmetic.
- `extendTarget` goes away; callers get an evaluation error pointing at the missing attribute.

## Testing

`tests/target.nix` is the touchpoint. All `extendTarget*` tests are rewritten against `.overrideAttrs`. New cases cover:

- Pure replacement (attrset form): `t.overrideAttrs { args = { ... }; }` replaces `args` wholesale — verifies the new explicit semantics.
- Merge via `old`: `t.overrideAttrs (old: { args = old.args // { ... }; })` reproduces the old merge behaviour — sanity check for the migration.
- Append to list: `t.overrideAttrs (old: { tags = old.tags ++ [ "extra" ]; })` — previously inexpressible.
- Chaining: `t.overrideAttrs(f).overrideAttrs(g)` applies in order.
- Validation survives override: unknown key in the patch throws.
- Required field survives override: dropping `context` throws.
- `passthru` round-trip: setting and reading `passthru` across an override.
- `//` still works: `t // { target = "ready"; }` produces a target whose `.overrideAttrs` still functions.

Existing non-override tests (`testMkTargetDefaultsDockerfile` etc.) are untouched.

## Documentation

- `API.md`: remove the `extendTarget` section; add an `.overrideAttrs` section with the signature, the two call forms, and a short example for each of replace / merge / append.
- `README.md`: no top-level mention of `extendTarget` today, so no README change is required beyond any stray example (none currently).

## Out of scope

- Scope / module `.override` sugar over `callBake` / `callBakeWithScope`.
- Any special treatment of `passthru`. Under the new model it has no dedicated merge rule; the override's returned attrs shallow-merge like any other field. If the caller wants to extend `passthru`, they write `old: { passthru = old.passthru // { ... }; }` explicitly.
- Deep merge helpers. Callers who want deep merge write it themselves via `lib.recursiveUpdate` or explicit attribute access.
