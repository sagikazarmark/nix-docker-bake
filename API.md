# API reference

## `mkTarget attrs`

Constructs a target attrset.
Defaults `dockerfile` to `"Dockerfile"`.
Throws if `context` is missing.
Does not default `platforms`.

### Identity field: `name`

Targets self-identify via a `name` field on the value: the target's wire-format identifier (the key under which it appears in the generated `docker-bake.json`).
Optional at construction; required when registering the target under `targets.<key>`, where it must equal `<key>`.
When a target is used inline in a group or context without being registered, an absent `name` falls through to a synthetic `group__<n>__<i>` or `<parent>__<ctx>` identifier.

`name` is identity metadata and does **not** appear in the serialized target body — only as the wire-format key.

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

### Composition and `name` inheritance

Both `overrideAttrs` and plain `//` shallow-merge inherit the source target's `name` field by default.
If you derive a new target intended to be registered under a different attrset key, you **must** set `name` explicitly on the patch — otherwise the wire-format identity collides with the source, and the registration check throws at module-load time:

```nix
# overrideAttrs form
variant = base.overrideAttrs (old: {
  name = "variant";                 # required if registering under `targets.variant`
  args = old.args // { X = "1"; };
});

# `//` form — same rule applies
derived = base // {
  name = "derived";
  tags = [ "extra" ];
};
```

The library's `targets.<key>`-must-match-`name` check (see [`mkScope`](#mkscope--config-modules-)) catches the omission with an error pointing at the offending key.

## `mkContext path`

Import a Docker build context as an isolated Nix store path.
The store-path hash depends only on the directory's contents, not the entire repo, preventing Docker cache busting when unrelated files change.

```nix
context = mkContext ./images/api;
# → /nix/store/<hash>-api-context
```

## `mkContextWith { path, filter ? null }`

Attrset-form variant of `mkContext` that additionally accepts an optional `filter` function — the same `path -> type -> bool` predicate `builtins.path` takes.
Use it to exclude files from the imported context (dev artefacts, secrets, unrelated sibling directories) before Docker sees them.
The filter participates in the content hash, so changing the filter produces a different store path.

```nix
context = mkContextWith {
  path = ./images/api;
  filter = p: t: baseNameOf p != "node_modules";
};
```

## `checkModule path module`

Validates a module's return shape.
Module shape: `{ targets?; groups?; passthru?; }` — every field optional.
Throws with a descriptive message identifying the offending module path on shape errors.
Called internally by `mkScope` after each module is resolved; exposed for consumer-side validation.

## `mkScope { config, modules }`

The main entry point.
Takes a `config` attrset and an attrset of `name -> path` module references (where path may be a Nix path or a string), builds a fixed-point scope, and validates each resolved module.
Throws if any module name conflicts with a reserved scope key (`lib`, `extend`, `override`, `modules`).

After a module is resolved, `mkScope` validates that every target's `name` field equals its attrset key in `targets`:

```nix
# OK
targets.main = lib.mkTarget { name = "main"; ... };

# Throws at module-load time
targets.main = lib.mkTarget { name = "mian"; ... };  # name typo
targets.main = base // { tags = [ "x" ]; };          # // inherits base.name = "base"
```

The check catches three common silent-collision idioms:

1. Let-binding identifier ≠ attrset key (`let x = mkTarget { name = "x"; ... }; in { targets."x-debug" = x; }` — name is "x", key is "x-debug").
2. `//` composition silently inheriting `name` from the LHS without an explicit override on the patch.
3. Project-level wrapper helpers compounding (1) or (2).

## `mkBakeFile module`

Serializes a module's target graph and writes it via `builtins.toFile`.
Returns a Nix store path directly usable with `docker buildx bake -f`.
The argument is a resolved module value (typically obtained from `scope.modules.<name>` or from `scope.<name>`).

Identity resolution reads `name` directly off each target value and compares content hashes — there is no reverse lookup, no scope back-reference, no closure-pointer comparison.
This makes `.override` and `lib.extend` re-evaluations produce byte-identical bake files when the inputs are equivalent.

```nix
bakeFile = bake.lib.mkBakeFile scope.modules.hello;
```

### Wire-id classification

The serializer emits two kinds of target entries:

- **First-level**: a target registered under `entryModule.targets.<key>`.
  Wire id is the bare `name` (equal to `<key>`; enforced by the attrset-key-matches-name check).
- **Second-level**: a target reached by walking `contexts.<name>` or a group member that is not itself a key of `entryModule.targets`.
  Wire id is `_<name>_<hash>`, where `<hash>` is the first 8 hex chars of a sha256 over the target's wire-format fields.
  The hash excludes identity metadata (`name`, `overrideAttrs`, `passthru`) and hashes `contexts` recursively.
  The leading underscore keeps second-level entries out of `docker buildx bake --list`.

Before emitting a second-level target, the serializer checks its content hash against the first-level set.
A match resolves the reference to the first-level bare name and skips emission of a duplicate entry — the dedup criterion is content hash alone, independent of origin (own module, foreign module, scope fork).
This closes the capture hazard around let-bindings that are both registered under `targets.<key>` and captured via another target's `contexts.<name>`: two values with identical content resolve to the same wire id and collapse into a single entry.

Consumers that need to force distinctness for two targets with otherwise-identical content should add a discriminating field (e.g., a noop arg or label).

## `module.override attrs`

Every resolved module in a scope (`scope.<name>`, `scope.modules.<name>`, or the result of `lib.callBake`) carries an `.override` method that re-evaluates the module with `attrs` shallow-merged onto its current arguments.
The override is local to the returned instance: the scope and sibling modules are unaffected.
Mirrors the `pkg.override` idiom from nixpkgs.
The result carries its own `.override`, so calls chain, and is directly usable with `mkBakeFile`.

Use this when you want to swap a single argument on a single module, whether the argument is declared inline in the module or pulled in from scope config.
For scope-wide changes that affect every module reading a key, reach for `scope.override` / `scope.extend` instead.

```nix
# One-off variant.
devApp = scope.app.override { appVersion = "v2.0.0"; };

# Build a compatibility matrix without forking the scope.
variants = map (v: scope.app.override { appVersion = v; }) [ "v1" "v2" "v3" ];

# Chain: each call returns a module with its own .override.
scope.app.override { appVersion = "v2.0.0"; }
  .override { extraArg = true; }
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

## `lib.callBake path overrides`

Available on the per-module `lib` injected into modules resolved by `mkScope`.
Resolves the module at `path` with its function arguments auto-injected from the scope, and applies `overrides` as a per-call replacement attrset.
Returns a resolved module value (carrying an `.override` method, just like `scope.modules.<name>`), suitable for use as a dependency of another module or directly with `mkBakeFile`.

Use this when you want to re-resolve a single module with a different argument: siblings and the rest of the scope are unaffected. For scope-wide changes, reach for `lib.extend` / `lib.override` instead. For an `.override`-style swap on a module already resolved through the scope, prefer `scope.<name>.override`.

```nix
# Inside a bake module
{ lib, ... }:
let
  devApp = lib.callBake ./app/bake.nix { appVersion = "v2.0.0"; };
in { ... }
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
