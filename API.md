# Bake Library API

> Generated. Do not edit by hand; edit the nixdoc comments in `lib/*.nix` and run `nix build .#api-docs`.

# Target construction and module validation. {#sec-functions-library-core}


## `lib.core.mkTarget` {#function-library-lib.core.mkTarget}

Construct a Docker Bake target attrset with minimal defaults.

- Defaults `dockerfile` to `"Dockerfile"` (matches Docker Bake's own default).
- Throws if `context` is missing.
- Does not default `platforms`; supply per target or via module.
- The result carries `.overrideAttrs` for caller-driven extension.

### Type

```
mkTarget :: AttrSet -> Target
```

### Example

```nix
mkTarget {
  context = ./.;
  dockerfile = "Dockerfile.alt";
  tags = [ "myimage:latest" ];
}
```

## `lib.core.mkContext` {#function-library-lib.core.mkContext}

Import a Docker build context as an isolated Nix store path.

The resulting store-path hash depends only on the directory's contents,
preventing Docker cache busting when unrelated files in the repo change.

### Type

```
mkContext :: Path -> StorePath
```

### Example

```nix
context = bake.mkContext ./images/control-plane;
```

## `lib.core.mkContextWith` {#function-library-lib.core.mkContextWith}

Attrset-form variant of `mkContext`. Accepts an optional `filter` (as in
`builtins.path`) to exclude files from the imported context: useful for
stripping dev artefacts, secrets, or unrelated sibling directories.

### Type

```
mkContextWith :: { path :: Path, filter :: Path -> String -> Bool | null } -> StorePath
```

### Example

```nix
context = bake.mkContextWith {
  path = ./images/api;
  filter = p: _: baseNameOf p != "node_modules";
};
```

## `lib.core.checkModule` {#function-library-lib.core.checkModule}

Validate a module's return shape. Throws with a message identifying the
offending module path; returns the module unchanged on success.

The module shape is `{ targets?, groups?, passthru? }`, each optional.

### Type

```
checkModule :: Path -> Module -> Module
```



# Scope aggregation and bake file generation. {#sec-functions-library-scope}


## `lib.scope.mkScope` {#function-library-lib.scope.mkScope}

Build a fixed-point scope from consumer-supplied `config` and a set of
`modules` (attrset of `name -> path`). Module functions are resolved via
auto-injection (`builtins.functionArgs`) against the resolved scope.

The returned scope exposes `lib` (library primitives), `extend` / `override`
(fork helpers), `modules.<name>` (resolved modules), and any attributes
propagated from `config`.

### Type

```
mkScope :: { config :: AttrSet, modules :: AttrSet } -> Scope
```

## `lib.scope.mkBakeFile` {#function-library-lib.scope.mkBakeFile}

Generate a `docker-bake.json` file as a Nix-store path from a resolved
module value (typically `scope.modules.<name>` or `scope.<name>`).

Identity resolution is content-addressed: registry key at the first level,
content hash at the second.

### Type

```
mkBakeFile :: Module -> StorePath
```



# Debugging helpers. {#sec-functions-library-describe}


## `lib.describe.describeScope` {#function-library-lib.describe.describeScope}

Return a human-readable string summarizing a scope's modules, their
targets, and key properties (context path, args count, groups).

Intended for debugging; do not parse the output.

### Type

```
describeScope :: Scope -> String
```

### Example

```
scope (2 modules):
  base: 1 target
    main  [context=./.  args=0]
  api: 2 targets, groups default
    base  [context=./images/api  args=2]
    main  [context=./images/api  args=2]
```



# Convenience app wrappers. {#sec-functions-library-apps}


## `lib.apps.mkBakeApp` {#function-library-lib.apps.mkBakeApp}

Build a flake `apps.<name>` entry that regenerates the bake file on
every invocation and execs `docker buildx bake -f <file> "$@"`.

`pkgs` is required because we use `pkgs.writeShellScript` to produce
an executable script. `docker` is NOT pinned in the Nix store: the
wrapper calls whatever `docker` is on the user's PATH so their
daemon, buildx plugins, and credentials work unchanged.

### Type

```
mkBakeApp :: { pkgs :: AttrSet, module :: Module, name :: String ? } -> App
```

### Example

```nix
apps.${system}.bake = bake.lib.mkBakeApp {
  inherit pkgs;
  module = scope.modules.app;
};
```


