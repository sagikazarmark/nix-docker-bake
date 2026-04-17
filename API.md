# API reference

## `mkTarget attrs`

Constructs a target attrset.
Defaults `dockerfile` to `"Dockerfile"`.
Throws if `context` is missing.
Does not default `platforms`.

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

## `mkContext prefix path`

Import a Docker build context as an isolated Nix store path.
The store-path hash depends only on the directory's contents, not the entire repo, preventing Docker cache busting when unrelated files change.
The `prefix` is prepended to the basename for uniqueness (e.g., two modules with `./image` won't collide).

```nix
context = mkContext "app" ./images/api;
# → /nix/store/<hash>-app-api-context
```

Inside a module resolved by `mkScope`, `lib.mkContext` is pre-applied with the module's registry key, so you write `lib.mkContext ./path` instead of `lib.mkContext "app" ./path`.

## `checkModule path module`

Validates a module's return shape.
Throws with a descriptive message identifying the offending module path.
Called internally by `mkScope` after each module is resolved; exposed for consumer-side validation.

## `mkScope { config, modules }`

The main entry point.
Takes a `config` attrset and an attrset of `name -> path` module references (where path may be a Nix path or a string), builds a fixed-point scope, and validates each resolved module.
Throws if any module name conflicts with a reserved scope key (`lib`, `extend`, `modules`).

## `mkBakeFile { scope, module }`

Serializes the named module's target graph and writes it via `builtins.toFile`.
Returns a Nix store path directly usable with `docker buildx bake -f`.
The `module` argument must be a key present in `scope.modules`.

## `scope.extend overlay`

Method on the scope returned by `mkScope`.
Produces a new scope with the given overlay applied.
Use this to layer persistent customizations (e.g., "a dev scope with a newer app version") instead of forking per-module via `callBakeWithScope`.
The original scope is unaffected.

```nix
devScope = scope.extend (final: prev: { appVersion = "v2.0.0"; });
# devScope.bakeFiles are equivalent to scope.bakeFiles but all transitive
# appVersion usages see v2.0.0
```

## `describeScope scope`

Returns a formatted human-readable string summarizing a bake scope's modules, targets, and key properties.
For debugging.

```nix
builtins.trace (bake.describeScope myScope) someExpr
```
