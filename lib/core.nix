# Target construction, context isolation, and module-shape validation.
{
  # Construct a target attrset with minimal defaults.
  # - Defaults `dockerfile` to "Dockerfile" (Docker Bake's own default)
  # - Throws if `context` is missing
  # - Does NOT default `platforms` (that's consumer-supplied per target or via module)
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
    in
    assert attrs ? context || throw "mkTarget: 'context' is required";
    assert
      unknownKeys == [ ]
      || throw "mkTarget: unknown key(s): ${builtins.concatStringsSep ", " unknownKeys} (allowed: ${builtins.concatStringsSep ", " allowedKeys})";
    {
      dockerfile = "Dockerfile";
    }
    // attrs;

  # Extend a base target with a patch. Atomic fields (context, dockerfile,
  # target, tags, platforms) are replaced when present in the patch. Attrset
  # fields (args, contexts) are merged, with patch keys winning on conflict.
  extendTarget =
    base: patch:
    base
    // patch
    // (
      if patch ? args then
        {
          args = (base.args or { }) // patch.args;
        }
      else
        { }
    )
    // (
      if patch ? contexts then
        {
          contexts = (base.contexts or { }) // patch.contexts;
        }
      else
        { }
    );

  # mkContext: import a Docker build context as an isolated store path.
  # The store-path hash depends ONLY on the directory's contents, not the
  # entire repo — preventing Docker cache busting when unrelated files
  # change. The `prefix` is prepended to the basename for uniqueness
  # (e.g., two modules with `./image` won't collide).
  #
  #   context = lib.mkContext "kubeadm" ./images/control-plane;
  #   # → /nix/store/<hash>-kubeadm-control-plane-context
  mkContext =
    prefix: srcPath:
    builtins.path {
      path = srcPath;
      name = "${prefix}-${baseNameOf (toString srcPath)}-context";
    };

  # Validate a module's return shape. Throws with a clear message identifying
  # the offending module path. Returns the module unchanged on success.
  # Shape: { namespace = string; targets = attrset; groups = attrset; }
  checkModule =
    modulePath: module:
    let
      pathStr = toString modulePath;
      prefix = "checkModule: module at '${pathStr}'";
      typeName = v: if v == null then "null" else builtins.typeOf v;
    in
    if !builtins.isAttrs module then
      throw "${prefix} did not return an attrset (got: ${typeName module})"
    else if !(module ? namespace) then
      throw "${prefix} is missing required attribute 'namespace'"
    else if !builtins.isString module.namespace then
      throw "${prefix} has non-string 'namespace' (got: ${typeName module.namespace})"
    else if module.namespace == "" then
      throw "${prefix} has empty 'namespace'"
    else if !(module ? targets) then
      throw "${prefix} is missing required attribute 'targets'"
    else if !builtins.isAttrs module.targets then
      throw "${prefix} has non-attrset 'targets' (got: ${typeName module.targets})"
    else if !(module ? groups) then
      throw "${prefix} is missing required attribute 'groups'"
    else if !builtins.isAttrs module.groups then
      throw "${prefix} has non-attrset 'groups' (got: ${typeName module.groups})"
    else if !(builtins.all builtins.isList (builtins.attrValues module.groups)) then
      throw "${prefix} has a non-list group value in 'groups'"
    else if module ? passthru && !builtins.isAttrs module.passthru then
      throw "${prefix} has non-attrset 'passthru' (got: ${typeName module.passthru})"
    else
      module;
}
