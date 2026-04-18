# Target construction, context isolation, and module-shape validation.
rec {
  # Construct a target attrset with minimal defaults.
  # - Defaults `dockerfile` to "Dockerfile" (Docker Bake's own default)
  # - Throws if `context` is missing
  # - Does NOT default `platforms` (that's consumer-supplied per target or via module)
  # - Output carries an `.overrideAttrs` method (see below) for caller-driven extension
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

  # mkContext: import a Docker build context as an isolated store path.
  # The store-path hash depends ONLY on the directory's contents, not the
  # entire repo — preventing Docker cache busting when unrelated files
  # change. The `prefix` is prepended to the basename for uniqueness
  # (e.g., two modules with `./image` won't collide).
  #
  #   context = lib.mkContext "kubeadm" ./images/control-plane;
  #   # → /nix/store/<hash>-kubeadm-control-plane-context
  mkContext = prefix: srcPath: mkContextWith prefix { path = srcPath; };

  # mkContextWith: attrset-form variant of mkContext that additionally accepts
  # an optional `filter` function (as in `builtins.path`) to exclude files
  # from the imported context — useful for stripping dev artefacts, secrets,
  # or unrelated sibling directories before Docker sees them.
  #
  #   context = lib.mkContextWith "app" {
  #     path = ./images/api;
  #     filter = p: t: baseNameOf p != "node_modules";
  #   };
  mkContextWith =
    prefix:
    {
      path,
      filter ? null,
    }:
    builtins.path (
      {
        inherit path;
        name = "${prefix}-${baseNameOf (toString path)}-context";
      }
      // (if filter == null then { } else { inherit filter; })
    );

  # Validate a module's return shape. Throws with a clear message identifying
  # the offending module path. Returns the module unchanged on success.
  # Shape: { namespace = string; targets = attrset?; groups = attrset?; }
  # Both `targets` and `groups` are optional; absent means `{}`.
  checkModule =
    modulePath: module:
    let
      pathStr = toString modulePath;
      prefix = "checkModule: module at '${pathStr}'";
    in
    if !builtins.isAttrs module then
      throw "${prefix} did not return an attrset (got: ${builtins.typeOf module})"
    else if !(module ? namespace) then
      throw "${prefix} is missing required attribute 'namespace'"
    else if !builtins.isString module.namespace then
      throw "${prefix} has non-string 'namespace' (got: ${builtins.typeOf module.namespace})"
    else if module.namespace == "" then
      throw "${prefix} has empty 'namespace'"
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
