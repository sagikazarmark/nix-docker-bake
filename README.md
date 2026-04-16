# nix-docker-bake

A pure-Nix framework for generating `docker-bake.json` files. You describe your Docker Bake targets as Nix modules, and the library produces a JSON store path you can pass directly to `docker buildx bake -f`.

## Why

Docker Bake is a solid tool for building multi-image setups, but its HCL and JSON manifest formats make composition awkward. Sharing variables across many related images, selectively overriding a single target's dependencies, or reusing target definitions across contexts requires duplication or fragile interpolation. This library replaces that with Nix primitives: modules, fixed-point scopes, and overlays. Deep, selective overrides are natural, and module reuse is structural rather than copy-paste.

## Usage

Add the library as a flake input:

```nix
{
  inputs.bake.url = "github:sagikazarmark/nix-docker-bake";
  inputs.bake.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { bake, ... }:
    let
      repository = "ghcr.io/me/images";
      scope = bake.lib.mkScope {
        config = {
          inherit repository;
          kubeVersion = "v1.34.0";
          tag = path: "${repository}/${path}:latest";
        };
        modules = {
          my-image = ./my-image/bake.nix;
        };
      };
    in {
      bakeFiles.my-image = bake.lib.mkBakeFile {
        inherit scope;
        module = "my-image";
      };
    };
}
```

Build and use the bake file:

```bash
docker buildx bake -f $(nix build --print-out-paths .#bakeFiles.my-image) my-image
```

## Writing a module

A module is a `.nix` file that returns a function. The function receives its arguments from the scope via `callPackage`-style auto-injection: anything in `config` is available as a named arg, and so are sibling modules (by their registry key name).

Modules receive the library functions under `lib` and config values / sibling modules as direct arguments. This mirrors nixpkgs conventions (`pkgs.lib.*` for helpers, `pkgs.<name>` for packages).

```nix
# my-image/bake.nix
{ lib, tag, kubeVersion, ... }:
let
  main = lib.mkTarget {
    context = lib.mkContext ./.;
    args = { KUBE_VERSION = kubeVersion; };
    tags = [ (tag "my-image") ];
  };
  debug = lib.mkTarget {
    context = lib.mkContext ./.;
    target = "debug";
    args = { KUBE_VERSION = kubeVersion; };
    tags = [ (tag "my-image/debug") ];
  };
in
{
  namespace = "my-image";
  targets = { inherit main debug; };
  groups = {
    default = [ main ];        # `docker buildx bake default` builds main
    all     = [ main debug ];  # `docker buildx bake all` builds both
  };
  vars = { KUBE_VERSION = kubeVersion; };
}
```

Groups map directly to Docker Bake's group concept: each key becomes a group you can invoke by name with `docker buildx bake <group>`, and its value is the list of targets built when the group is invoked. The list elements are target attrsets (not string names); the library resolves each into its serialized ID.

To declare a dependency on another module, name it in the function args using its registry key:

```nix
{ lib, my-other-image, ... }:
let
  main = lib.mkTarget {
    context = lib.mkContext ./.;
    contexts.base = my-other-image.targets.main;
  };
in
{
  namespace = "my-image";
  targets = { inherit main; };
  groups = { default = [ main ]; };
  vars = {};
}
```

### Namespace vs registry key

A module's `namespace` attribute and its key in the `modules` registry are separate concepts. The registry key determines how sibling modules reference it via function args. The namespace determines how its targets are identified in the serialized output (as `<namespace>_<target-name>` when referenced across modules).

Convention: match them unless you have a specific reason not to. The library does not enforce equality, but divergence can be confusing.

```nix
scope = mkScope {
  modules = {
    kubeadm = ./playgrounds/kubeadm/bake.nix;  # registry key: kubeadm
  };
};
# Inside kubeadm/bake.nix, module returns { namespace = "kubeadm"; ... }
# Sibling modules do `{ kubeadm, ... }:` (using the key)
# Serialized output refers to its targets as `kubeadm_main`, `kubeadm_defaults` etc. (using the namespace)
```

## Public API

**`mkTarget attrs`**

Constructs a target attrset. Defaults `dockerfile` to `"Dockerfile"`. Throws if `context` is missing. Does not default `platforms`.

**`extendTarget base patch`**

Extend a base target with a patch. Atomic fields (`context`, `dockerfile`, `target`, `tags`, `platforms`) are replaced when present in the patch. Attrset fields (`args`, `contexts`) are merged, with patch values winning on conflict. Use this instead of `base // patch` when you want to preserve existing `args` or `contexts` from the base.

**`mkContext prefix path`**

Import a Docker build context as an isolated Nix store path. The store-path hash depends only on the directory's contents, not the entire repo, preventing Docker cache busting when unrelated files change. The `prefix` is prepended to the basename for uniqueness (e.g., two modules with `./image` won't collide).

```nix
context = mkContext "kubeadm" ./images/control-plane;
# → /nix/store/<hash>-kubeadm-control-plane-context
```

Inside a module resolved by `mkScope`, `lib.mkContext` is pre-applied with the module's registry key, so you write `lib.mkContext ./path` instead of `lib.mkContext "kubeadm" ./path`.

**`checkModule path module`**

Validates a module's return shape. Throws with a descriptive message identifying the offending module path. Called internally by `mkScope` after each module is resolved; exposed for consumer-side validation.

**`mkScope { config, modules }`**

The main entry point. Takes a `config` attrset and an attrset of `name -> path` module references (where path may be a Nix path or a string), builds a fixed-point scope, and validates each resolved module. Throws if any module name conflicts with a reserved scope key (`lib`, `extend`, `modules`).

**`mkBakeFile { scope, module }`**

Serializes the named module's target graph and writes it via `builtins.toFile`. Returns a Nix store path directly usable with `docker buildx bake -f`. The `module` argument must be a key present in `scope.modules`.

**`scope.extend overlay`**

Method on the scope returned by `mkScope`. Produces a new scope with the given overlay applied. Use this to layer persistent customizations (e.g., "a dev scope with a newer Kubernetes version") instead of forking per-module via `callBakeWithScope`. The original scope is unaffected.

```nix
devScope = scope.extend (final: prev: { kubeVersion = "v1.35.0"; });
# devScope.bakeFiles are equivalent to scope.bakeFiles but all transitive
# kubeVersion usages see v1.35.0
```

**`fix`, `extends`**

Nix fixed-point and overlay primitives. Exposed for advanced use when constructing custom scopes or overlays outside of `mkScope`.

**`describeScope scope`**

Returns a formatted human-readable string summarizing a bake scope's modules, targets, and key properties. For debugging.

```nix
builtins.trace (bake.describeScope myScope) someExpr
```

## Overrides

The scope exposes two override mechanisms. Choose based on how far you want the change to propagate:

| You want to... | Use |
|---|---|
| Override a dep in one module, leave siblings alone | `callBake path { specificDep = ...; }` |
| Override a config value everywhere, atomically | `callBakeWithScope path (final: prev: { key = ...; })` |
| Override a value in some transitive deps but not others | `callBake path { ...; dep = callBake ../dep.nix { ... }; }` (selective) |

### Shallow override (`callBake`)

`callBake path overrides` resolves the module at `path` with dependencies auto-injected from the scope. Anything you pass in `overrides` replaces the corresponding scope value for that single resolution. Sibling modules, and the rest of the scope, are unaffected.

```nix
# Re-resolve kubeadm with a different version. cri, containerd, kube-dev-machine
# all keep their original scope values.
customKubeadm = lib.callBake ../kubeadm/bake.nix {
  kubeVersion = "v1.35.0";
};
```

### Deep override (`callBakeWithScope`)

`callBakeWithScope path overlay` forks the entire scope with an overlay, then resolves the module in the forked scope. Every transitive dependency re-resolves with the overlay applied.

```nix
# Every module in the forked scope that reads kubeVersion sees v1.35.0 —
# including transitive deps.
customKubeadm = lib.callBakeWithScope ../kubeadm/bake.nix
  (final: prev: { kubeVersion = "v1.35.0"; });
```

### Selective propagation (the interesting case)

Often neither extreme is right: you want the override to flow through *some* transitive deps but not others. This is natural with `callBake` by passing already-overridden deps as explicit arguments:

```nix
# Goal: kubeadm and its dev-machine chain (kube-common, kube-dev-machine)
# should use v1.35.0. But cri/containerd/crio should keep v1.34.0 because
# they use kubeVersion for a different purpose (crictl version).
#
# Strategy: re-resolve kube-common and kube-dev-machine with the new version,
# then pass them explicitly when re-resolving kubeadm. cri is NOT passed,
# so it resolves from the base scope and keeps v1.34.0.

{ lib, ... }:
let
  kubeCommon' = lib.callBake ../../.bake/images/kube-common/bake.nix {
    kubeVersion = "v1.35.0";
  };
  kubeDevMachine' = lib.callBake ../../.bake/images/kube-dev-machine/bake.nix {
    kube-common = kubeCommon';
  };
  kubeadm' = lib.callBake ../kubeadm/bake.nix {
    kubeVersion = "v1.35.0";
    kube-common = kubeCommon';
    kube-dev-machine = kubeDevMachine';
    # cri is NOT overridden — kubeadm will resolve it from the base scope,
    # where it still has kubeVersion = "v1.34.0"
  };
in ...
```

This pattern is verbose but explicit: the dependency chain is visible, and the cutoff point (where overrides stop propagating) is controlled by which deps you pass.

## Module contract

A module function must return an attrset with this shape:

```nix
{
  namespace = "string";       # used for cross-module target ID namespacing
  targets   = { name = target; ... };              # attrset of target attrsets
  groups    = { name = [ target ... ]; ... };      # each value is a list of target attrsets
  vars      = { NAME = "value"; ... };             # opaque; not consumed by the library
}
```

`vars` is not interpreted by the library. Use it to expose module-level metadata, such as which versions a module was built against, for introspection by consumers.

## Testing

```bash
nix flake check
```

The test suite contains 94 assertions: 59 unit tests and 35 integration tests.

Unit tests cover `mkTarget` (defaults, field preservation, no platform default), `mkContext` (store path format, prefix in name, determinism, path isolation), `checkModule` (happy path, missing fields, wrong types, empty namespace), `serialize` (standalone targets, inline target contexts, cross-module identity, groups, variable collection), `mkScope` (config injection, module registry, string paths, `mkContext` auto-injection), `callBakeWithScope` propagation, `mkBakeFile` (store path format, round-trip JSON parse), `extendTarget` (args merging, contexts merging, atomic field replacement), `scope.extend` (persistent overlay, original scope unaffected), and `describeScope` (returns string, contains module name, handles empty and missing modules).

Integration tests exercise the full pipeline from real `.nix` fixture files through `mkScope` and serialization, covering a multi-module three-tier scope (base, middle, top, aggregator), cross-module context identity (`target:namespace_name`), transitive dependency walks, group serialization with foreign targets, variable collection, `scope.extend` propagation, and `callBakeWithScope` override verification.

## Limitations

- The generated JSON contains absolute Nix store paths. The output is always regenerated by Nix, so this is correct but means you should not commit the output file.
- `mkTarget` does not validate target attributes beyond requiring `context`. Invalid fields surface as errors at serialization time or inside Docker Bake itself.
