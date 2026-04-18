# Target construction, context isolation, and module-shape validation.
rec {
  /**
    Construct a Docker Bake target attrset with minimal defaults.

    - Defaults `dockerfile` to `"Dockerfile"` (matches Docker Bake's own default).
    - Throws if `context` is missing.
    - Does not default `platforms`; supply per target or via module.
    - The result carries `.overrideAttrs` for caller-driven extension.

    # Type

    ```
    mkTarget :: AttrSet -> Target
    ```

    # Example

    ```nix
    mkTarget {
      context = ./.;
      dockerfile = "Dockerfile.alt";
      tags = [ "myimage:latest" ];
    }
    ```
  */
  # Construct a target attrset with minimal defaults.
  # - Defaults `dockerfile` to "Dockerfile" (Docker Bake's own default)
  # - Throws if `context` is missing
  # - Does NOT default `platforms` (that's consumer-supplied per target or via module)
  # - Output carries an `.overrideAttrs` method (see below) for caller-driven extension
  mkTarget =
    attrs:
    let
      allowedKeys = [
        "name"
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

  /**
    Import a Docker build context as an isolated Nix store path.

    The resulting store-path hash depends only on the directory's contents,
    preventing Docker cache busting when unrelated files in the repo change.

    # Type

    ```
    mkContext :: Path -> StorePath
    ```

    # Example

    ```nix
    context = bake.mkContext ./images/control-plane;
    ```
  */
  # mkContext: import a Docker build context as an isolated store path.
  # The store-path hash depends ONLY on the directory's contents, not the
  # entire repo (preventing Docker cache busting when unrelated files
  # change).
  #
  #   context = lib.mkContext ./images/control-plane;
  #   # -> /nix/store/<hash>-control-plane-context
  mkContext = srcPath: mkContextWith { path = srcPath; };

  /**
    Attrset-form variant of `mkContext`. Accepts an optional `filter` (as in
    `builtins.path`) to exclude files from the imported context: useful for
    stripping dev artefacts, secrets, or unrelated sibling directories.

    # Type

    ```
    mkContextWith :: { path :: Path, filter :: Path -> String -> Bool | null } -> StorePath
    ```

    # Example

    ```nix
    context = bake.mkContextWith {
      path = ./images/api;
      filter = p: _: baseNameOf p != "node_modules";
    };
    ```
  */
  # mkContextWith: attrset-form variant of mkContext that additionally accepts
  # an optional `filter` function (as in `builtins.path`) to exclude files
  # from the imported context (useful for stripping dev artefacts, secrets,
  # or unrelated sibling directories before Docker sees them).
  #
  #   context = lib.mkContextWith {
  #     path = ./images/api;
  #     filter = p: t: baseNameOf p != "node_modules";
  #   };
  mkContextWith =
    {
      path,
      filter ? null,
    }:
    builtins.path (
      {
        inherit path;
        name = "${baseNameOf (toString path)}-context";
      }
      // (if filter == null then { } else { inherit filter; })
    );

  /**
    Validate a module's return shape. Throws with a message identifying the
    offending module path; returns the module unchanged on success.

    The module shape is `{ targets?, groups?, passthru? }`, each optional.

    # Type

    ```
    checkModule :: Path -> Module -> Module
    ```
  */
  # Validate a module's return shape. Throws with a clear message identifying
  # the offending module path. Returns the module unchanged on success.
  # Shape: { targets = attrset?; groups = attrset?; passthru = attrset?; }
  # All fields are optional; absent means `{}` (or absent in the output).
  checkModule =
    modulePath: module:
    let
      pathStr = toString modulePath;
      prefix = "checkModule: module at '${pathStr}'";
    in
    if !builtins.isAttrs module then
      throw "${prefix} did not return an attrset (got: ${builtins.typeOf module})"
    else if module ? targets && !builtins.isAttrs module.targets then
      throw "${prefix} has non-attrset 'targets' (got: ${builtins.typeOf module.targets})"
    else if module ? groups && !builtins.isAttrs module.groups then
      throw "${prefix} has non-attrset 'groups' (got: ${builtins.typeOf module.groups})"
    else if module ? groups && !(builtins.all builtins.isList (builtins.attrValues module.groups)) then
      throw "${prefix} has a non-list group value in 'groups'"
    else if module ? passthru && !builtins.isAttrs module.passthru then
      throw "${prefix} has non-attrset 'passthru' (got: ${builtins.typeOf module.passthru})"
    else
      module;
}
