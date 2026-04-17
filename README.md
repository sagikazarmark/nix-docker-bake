# nix-docker-bake

[![GitHub Workflow Status](https://img.shields.io/github/actions/workflow/status/sagikazarmark/nix-docker-bake/ci.yaml?style=flat-square)](https://github.com/sagikazarmark/nix-docker-bake/actions/workflows/ci.yaml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/sagikazarmark/nix-docker-bake/badge?style=flat-square)](https://securityscorecards.dev/viewer/?uri=github.com/sagikazarmark/nix-docker-bake)
[![built with nix](https://img.shields.io/badge/builtwith-nix-7d81f7?style=flat-square)](https://builtwithnix.org)

Compose `docker-bake.json` files with Nix.
Describe Docker Bake targets as plain Nix functions and get shared config, selective overrides, and structural reuse without HCL interpolation or copy-paste.

## Why Nix instead of HCL

[Docker Bake](https://docs.docker.com/build/bake/) is Docker's tool for coordinating multi-image builds from a single manifest.
Its HCL format is fine for static configs but makes composition awkward:
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

## Quick start

Add the library as a flake input and build a bake file for a single module:

```nix
# flake.nix
{
  inputs.bake.url = "github:sagikazarmark/nix-docker-bake";
  inputs.bake.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { bake, ... }: {
    bakeFile = bake.lib.mkBakeFile {
      scope = bake.lib.mkScope {
        config.tag = path: "ghcr.io/me/${path}:latest";
        modules.hello = ./hello.nix;
      };
      module = "hello";
    };
  };
}
```

```nix
# hello.nix
{ lib, tag, ... }:
let
  main = lib.mkTarget {
    context = lib.mkContext ./.;
    tags = [ (tag "hello") ];
  };
in
{
  namespace = "hello";
  targets = { inherit main; };
  groups.default = [ main ];
}
```

Then:

```bash
docker buildx bake -f $(nix build --print-out-paths .#bakeFile) default
```

## Writing modules

A module is a `.nix` file that returns a function.
The function's arguments are injected from the scope (like `callPackage`):
anything in `config` is available as a named arg, and so are sibling modules (by their registry key).
The library's helpers come in under `lib`.

A realistic example with config values and a sibling dependency:

```nix
# app/bake.nix
{ lib, tag, appVersion, base, ... }:
let
  main = lib.mkTarget {
    context = lib.mkContext ./.;
    contexts.base = base.targets.main;
    args = { APP_VERSION = appVersion; };
    tags = [ (tag "app") ];
  };
  debug = lib.mkTarget {
    context = lib.mkContext ./.;
    target = "debug";
    args = { APP_VERSION = appVersion; };
    tags = [ (tag "app/debug") ];
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

Groups map directly to Docker Bake's group concept:
each key becomes a group you can invoke by name with `docker buildx bake <group>`, and its value is the list of targets built when the group is invoked.
The list elements are target attrsets (not string names); the library resolves each into its serialized ID.

### Namespace vs registry key

A module's `namespace` attribute and its key in the `modules` registry are separate concepts.
The registry key determines how sibling modules reference it via function args.
The namespace determines how its targets are identified in the serialized output (as `<namespace>_<target-name>` when referenced across modules).

Convention: match them unless you have a specific reason not to.
The library does not enforce equality, but divergence can be confusing.

```nix
scope = mkScope {
  modules = {
    app = ./services/app/bake.nix;  # registry key: app
  };
};
# Inside app/bake.nix, module returns { namespace = "app"; ... }
# Sibling modules do `{ app, ... }:` (using the key)
# Serialized output refers to its targets as `app_main`, `app_debug` etc. (using the namespace)
```

## Overrides

The scope exposes two override mechanisms.
Choose based on how far you want the change to propagate:

| You want to... | Use |
|---|---|
| Override a dep in one module, leave siblings alone | `callBake path { specificDep = ...; }` |
| Override a config value everywhere, atomically | `callBakeWithScope "name" (final: prev: { key = ...; })` |
| Override a value in some transitive deps but not others | `callBake path { ...; dep = callBake ../dep.nix { ... }; }` (selective) |

### Shallow override (`callBake`)

`callBake path overrides` resolves the module at `path` with dependencies auto-injected from the scope.
Anything you pass in `overrides` replaces the corresponding scope value for that single resolution.
Sibling modules, and the rest of the scope, are unaffected.

```nix
# Re-resolve app with a different version. Other modules in the scope
# keep their original values.
customApp = lib.callBake ./app/bake.nix {
  appVersion = "v2.0.0";
};
```

### Deep override (`callBakeWithScope`)

`callBakeWithScope name overlay` forks the entire scope with an overlay, then re-resolves the named module in the forked scope.
`name` must be a key in the scope's `modules` attrset.
Every transitive dependency re-resolves with the overlay applied.

```nix
# Every module in the forked scope that reads appVersion sees v2.0.0,
# including transitive deps.
customApp = lib.callBakeWithScope "app"
  (final: prev: { appVersion = "v2.0.0"; });
```

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
in ...
```

This pattern is verbose but explicit:
the dependency chain is visible, and the cutoff point (where overrides stop propagating) is controlled by which deps you pass.

## Module contract

A module function must return an attrset with this shape:

```nix
{
  namespace = "string";       # used for cross-module target ID namespacing
  targets   = { name = target; ... };              # attrset of target attrsets
  groups    = { name = [ target ... ]; ... };      # each value is a list of target attrsets
}
```

### Extending modules and targets with `passthru`

Wrapper libraries built on top of nix-docker-bake often need to attach data to a module or target that isn't part of the bake shape — for example, a tag-management layer that wants to surface per-target push refs to non-bake consumers.

`passthru` is the reserved attribute for this.
Both modules and targets accept an optional `passthru` attrset:

```nix
{
  namespace = "app";
  targets   = { inherit main; };
  groups    = { default = [ main ]; };

  passthru = {
    pushRefs.main = "oci://ghcr.io/me/app:a1b2c3";
  };
}
```

```nix
main = lib.mkTarget {
  context = lib.mkContext "app" ./.;
  tags    = [ (tag "app") ];
  passthru = {
    pushRef = "oci://ghcr.io/me/app:a1b2c3";
  };
};
```

The library ignores `passthru` when serializing the bake file and promises not to rely on its contents or absence.
Downstream consumers read it directly off the module or target attrset.

`passthru` is the documented extension point on both modules and targets.
Because `mkTarget` rejects unknown keys to catch typos, `passthru` is the only way to attach wrapper-library data to a target.
Other unknown keys on modules are tolerated today but may be rejected in a future release; wrapper libraries should put extension data under `passthru`.

## API reference

The full function reference lives in [API.md](API.md).

## Testing

```bash
nix flake check
```

## Limitations

- The generated JSON contains absolute Nix store paths.
  The output is always regenerated by Nix, so this is correct but means you should not commit the output file.
- `mkTarget` does not validate target attributes beyond requiring `context`.
  Invalid fields surface as errors at serialization time or inside Docker Bake itself.

## License

The project is licensed under the [MIT License](LICENSE).
