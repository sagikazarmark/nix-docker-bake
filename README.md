# nix-docker-bake

[![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/sagikazarmark/nix-docker-bake/ci.yaml?style=flat-square)](https://github.com/sagikazarmark/nix-docker-bake/actions/workflows/ci.yaml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/sagikazarmark/nix-docker-bake/badge?style=flat-square)](https://securityscorecards.dev/viewer/?uri=github.com/sagikazarmark/nix-docker-bake)
[![built with nix](https://img.shields.io/badge/builtwith-nix-7d81f7?style=flat-square)](https://builtwithnix.org)

Compose `docker-bake.json` files with Nix: describe [Docker Bake](https://docs.docker.com/build/bake/) targets as plain Nix functions instead of HCL.

## Features

- 🧩 **Composable**: Modules are plain functions that reference each other via arguments, `callPackage`-style.
- 📦 **Content-addressed contexts**: Build contexts import as isolated Nix store paths; unrelated repo changes don't bust Docker's cache.
- 🎯 **Selective overrides**: Re-resolve a module with a different dep or config value without touching siblings.
- 🔧 **Chainable target overrides**: `target.overrideAttrs` layers modifications without wholesale replacement.

<details>
<summary><strong>Why Nix instead of HCL?</strong></summary>

HCL is fine for static configs but makes composition awkward:
shared config ends up duplicated across targets,
selective overrides require duplicating the targets they touch,
and reusing target definitions across projects means copy-paste.

Selective overrides are the sharp edge.
Say you want to build `app` with a newer version for development, but other images that share the same `appVersion` variable should stay pinned.
In HCL you either fork the targets or drive everything through command-line vars that hit every consumer.
With this library it's a function call:

```nix
devApp = lib.callBake ./app/bake.nix { appVersion = "v2.0.0"; };
# Other images keep their original values
```

The trade-off: you write Nix (plain functions that return attrsets; this is *not* the NixOS module system), and manifest generation happens at `nix build` time instead of at Docker's parse time.

</details>

## Installation

Add the library as a flake input:

```nix
# flake.nix
{
  inputs.bake.url = "github:sagikazarmark/nix-docker-bake";
  inputs.bake.inputs.nixpkgs.follows = "nixpkgs";
}
```

## Usage

### Modules

A module groups a set of targets under a namespace.
`lib.mkTarget` builds a target; `lib.mkContext` imports a directory as an isolated build context.

```nix
# hello.nix
{ lib, ... }:
let
  main = lib.mkTarget {
    context = lib.mkContext ./.;
    tags    = [ "ghcr.io/me/hello:latest" ];
  };
in
{
  namespace = "hello";
  targets   = { inherit main; };
}
```

See [Writing modules](#writing-modules) for the full shape and a realistic example with dependencies.

### Bake files

`mkScope` wires modules together; `mkBakeFile` serializes one into a file that `docker buildx bake` can consume.

```nix
# inside flake.nix outputs
scope = bake.lib.mkScope {
  config  = { };
  modules = { hello = ./hello.nix; };
};
bakeFile = bake.lib.mkBakeFile scope.modules.hello;
```

Expose `bakeFile` as a flake output, build it, and hand the path to `docker buildx bake`:

```bash
docker buildx bake -f "$(nix build --print-out-paths .#bakeFile)" main
```

## Writing modules

A module is a `.nix` file that returns a function.
The function's arguments are injected from the scope (like `callPackage`):
anything in `config` is available as a named arg, and so are sibling modules (by their registry key).
The library's helpers come in under `lib`.

A realistic example with config values and a sibling dependency:

```nix
# app/bake.nix
# `base` is a sibling module (registered under the key "base" in the scope);
# `appVersion` is a config value from mkScope's `config` attrset.
{ lib, appVersion, base, ... }:
let
  main = lib.mkTarget {
    context = lib.mkContext ./.;
    contexts.base = base.targets.main; # cross-module dep; wiring explained below
    args = { APP_VERSION = appVersion; };
    tags = [ "myorg/myapp" ];
  };
  debug = lib.mkTarget {
    context = lib.mkContext ./.;
    target = "debug";
    args = { APP_VERSION = appVersion; };
  };
in
{
  namespace = "app";
  targets = { inherit main debug; };
  groups = {
    default = [ main ];        # `docker buildx bake default` builds main
    all     = [ main debug ];  # `docker buildx bake all` builds both
  };
}
```

`contexts` is Docker Bake's attribute for declaring [named build contexts](https://docs.docker.com/build/bake/contexts/): extra inputs that a Dockerfile can reference via `FROM name` or `COPY --from=name`.
Passing a target attrset as a `contexts.<name>` value (as with `contexts.base = base.targets.main` above) is how cross-module target dependencies are wired.
The serializer translates the reference into a `target:<id>` entry in the bake file, which tells Docker Bake to build the upstream target first and make its output available to the downstream build.
When the referenced target lives in another module, `<id>` is namespace-prefixed (see [Namespace vs registry key](#namespace-vs-registry-key)); within the same module it's bare.

Groups map directly to Docker Bake's group concept:
each key becomes a group you can invoke by name with `docker buildx bake <group>`, and its value is the list of targets built when the group is invoked.
The list elements are target attrsets (not string names); the library resolves each into its serialized ID.
Group names in the serialized output are not namespace-prefixed (unlike cross-module target IDs; see [Namespace vs registry key](#namespace-vs-registry-key)).

### Namespace vs registry key

A module's `namespace` attribute and its key in the `modules` registry are separate concepts.
The registry key determines how sibling modules reference it via function args.
The namespace determines how its targets are identified in the serialized output: bare `<target-name>` within the same module, `<namespace>_<target-name>` when referenced across modules.

Convention: match them unless you have a specific reason not to.
The library does not enforce equality, but diverging names can be confusing.

```nix
scope = mkScope {
  modules = {
    app = ./services/app/bake.nix;  # registry key: app
  };
};
# Inside app/bake.nix, module returns { namespace = "app"; ... }
# Sibling modules do `{ app, ... }:` (using the key)
# Cross-module references use `app_main`, `app_debug` (namespace-prefixed); within the app module itself they stay bare.
```

## Overrides

The scope exposes several override mechanisms.
Choose based on how far you want the change to propagate:

| You want to... | Use |
|---|---|
| Swap a single arg on a module already in the scope | `scope.<name>.override { arg = ...; }` |
| Override a dep in one module, leave siblings alone | `lib.callBake path { dep = ...; }` |
| Replace a config value everywhere in the scope | `(lib.override { key = ...; }).modules.<name>` |
| Same, with access to prior values (overlay form) | `(lib.extend (final: prev: { key = ...; })).modules.<name>` |
| Override a value in some transitive deps but not others | `lib.callBake path { ...; dep = lib.callBake ../dep.nix { ... }; }` (selective) |

### Shallow override (`callBake`)

`callBake path overrides` resolves the module at `path` with its function arguments auto-injected from the scope.
Anything you pass in `overrides` replaces the corresponding scope value for that single resolution.
Sibling modules, and the rest of the scope, are unaffected.

```nix
# Re-resolve app with a different version. Other modules in the scope
# keep their original values.
customApp = lib.callBake ./app/bake.nix {
  appVersion = "v2.0.0";
};
```

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

The same pair is available on the scope value itself: use `scope.extend` / `scope.override` when you have a scope in hand (typically in `flake.nix`, outside any module), and the `lib.*` forms when you are inside a module.

### Selective propagation (the interesting case)

Often neither extreme is right: you want the override to flow through *some* transitive deps but not others.
This is natural with `callBake` by passing already-overridden deps as explicit arguments:

```nix
# Goal: app and its base dep should upgrade to v2.0.0. But other modules
# in the scope that also read appVersion (e.g., a sibling that uses it
# only as a metadata label) should stay pinned.
#
# Strategy: re-resolve base with the new version, then pass it explicitly
# when re-resolving app. callBake only touches the module being resolved,
# so anything not passed resolves from the base scope at the original
# value.

{ lib, ... }:
let
  base' = lib.callBake ./base/bake.nix {
    appVersion = "v2.0.0";
  };
  app' = lib.callBake ./app/bake.nix {
    appVersion = "v2.0.0";
    base = base';
  };
in app'
```

`app'` is a resolved module value: use it as a dep of another module, reference its targets via `contexts.<name>`, or return it from the enclosing module.

This pattern is verbose but explicit:
the dependency chain is visible, and the cutoff point (where overrides stop propagating) is controlled by which deps you pass.

## Module contract

A module function must return an attrset with this shape:

```nix
{
  namespace = "string";                       # required; used for cross-module target ID namespacing
  targets   = { name = target; ... };         # optional; attrset of target attrsets
  groups    = { name = [ target ... ]; ... }; # optional; each value is a list of target attrsets
  passthru  = { ... };                        # optional; opaque consumer payload (see below)
}
```

Only `namespace` is required.
`targets` and `groups` default to `{}` when absent.
If the resulting target or group set is empty, the corresponding top-level key is omitted from the serialized output.

### Extending modules and targets with `passthru`

Wrapper libraries often need to attach data that isn't part of the bake shape (e.g., per-target push refs for non-bake consumers).
Both modules and targets accept an optional `passthru` attrset, which the library ignores during serialization.

```nix
{
  namespace = "app";
  targets = {
    main = lib.mkTarget {
      context = lib.mkContext ./.;
      tags    = [ "myorg/app" ];
      passthru.pushRef = "oci://ghcr.io/me/app:a1b2c3";
    };
  };
  passthru.pushRefs.main = "oci://ghcr.io/me/app:a1b2c3";
}
```

Because `mkTarget` rejects unknown keys, `passthru` is the only way to attach wrapper data to a target.
Modules currently tolerate unknown keys but may reject them in a future release, so prefer `passthru` there too.

## API reference

The full function reference lives in [API.md](API.md).

## Testing

Unit tests and integration fixtures live under `tests/` and run as part of `nix flake check`:

```bash
nix flake check
```

## Limitations

- The generated JSON contains absolute Nix store paths, so it should not be committed; regenerate it via `nix build` on each use.
- `mkTarget` rejects unknown keys but does not type-check the values of known ones.
  Malformed values (e.g., a non-list `tags`) surface as errors at serialization time or inside Docker Bake itself.

## License

The project is licensed under the [MIT License](LICENSE).
