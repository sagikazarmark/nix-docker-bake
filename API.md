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

# Chain: each call returns a target with its own .overrideAttrs.
# Outer parens are required — Nix's `.` binds tighter than application.
(t.overrideAttrs (old: { args = old.args // { X = "1"; }; }))
  .overrideAttrs (old: { tags = old.tags ++ [ "latest" ]; })
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

## `mkContextWith prefix { path, filter ? null }`

Attrset-form variant of `mkContext` that additionally accepts an optional `filter` function — the same `path -> type -> bool` predicate `builtins.path` takes.
Use it to exclude files from the imported context (dev artefacts, secrets, unrelated sibling directories) before Docker sees them.
The store-path name is derived the same way as `mkContext` (`${prefix}-${baseNameOf path}-context`); the filter participates in the content hash, so changing the filter produces a different store path.

```nix
context = mkContextWith "app" {
  path = ./images/api;
  filter = p: t: baseNameOf p != "node_modules";
};
```

Inside a module resolved by `mkScope`, `lib.mkContextWith` is pre-applied with the module's registry key in the same way as `lib.mkContext`.

## `checkModule path module`

Validates a module's return shape.
Throws with a descriptive message identifying the offending module path.
Called internally by `mkScope` after each module is resolved; exposed for consumer-side validation.

## `mkScope { config, modules }`

The main entry point.
Takes a `config` attrset and an attrset of `name -> path` module references (where path may be a Nix path or a string), builds a fixed-point scope, and validates each resolved module.
Throws if any module name conflicts with a reserved scope key (`lib`, `extend`, `override`, `modules`).

## `mkBakeFile module`

Serializes a module's target graph and writes it via `builtins.toFile`.
Returns a Nix store path directly usable with `docker buildx bake -f`.
The argument is a resolved module value (typically obtained from `scope.modules.<name>` or from `scope.<name>`).
The module carries a hidden back-reference to its originating scope, which the serializer uses to resolve cross-module target identities.

```nix
bakeFile = bake.lib.mkBakeFile scope.modules.hello;
```

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

## `describeScope scope`

Returns a formatted human-readable string summarizing a bake scope's modules, targets, and key properties.
For debugging.

```nix
builtins.trace (bake.describeScope myScope) someExpr
```
