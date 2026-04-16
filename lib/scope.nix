# Scope construction and bake file generation.
{
  nixLib,
  core,
  serialize,
}:
let
  # Build a fixed-point scope function from consumer-supplied config and module paths.
  # config: opaque attrset; values flow to modules via callBake auto-injection.
  # modules: attrset of `name → path-to-bake.nix`.
  mkScope =
    {
      config,
      modules,
    }:
    let
      reservedNames = [
        "lib"
        "extend"
        "modules"
      ];
      conflicts = builtins.filter (n: builtins.elem n reservedNames) (builtins.attrNames modules);
    in
    assert
      conflicts == [ ]
      || throw "mkScope: module names conflict with reserved scope keys: ${builtins.concatStringsSep ", " conflicts}";
    let
      scopeFn =
        self:
        let
          libFunctions = {
            # Library primitives exposed for module consumption.
            inherit (core) mkTarget extendTarget mkContext;

            # callBake: auto-inject function arguments from the scope, allow overrides.
            callBake =
              modulePath: overrides:
              let
                fn = import modulePath;
                autoArgs = builtins.intersectAttrs (builtins.functionArgs fn) self;
                module = fn (autoArgs // overrides);
              in
              core.checkModule modulePath module;

            # callBakeWithScope: fork the scope with an overlay before resolving.
            # Transitive callBake calls inside the resolved module see the overlay.
            callBakeWithScope =
              modulePath: overlay:
              let
                forkedScope = nixLib.fix (nixLib.extends overlay scopeFn);
              in
              forkedScope.lib.callBake modulePath { };
          };
        in
        config
        // {
          # Library functions namespaced under lib, mirroring nixpkgs conventions.
          lib = libFunctions;

          # Return a new scope with the given overlay applied.
          # Use this to persistently extend the scope for a subtree of your code
          # rather than forking per-module via callBakeWithScope.
          extend = overlay: nixLib.fix (nixLib.extends overlay scopeFn);
        }
        // builtins.mapAttrs (
          moduleName: modulePath:
          let
            # Per-module lib: mkContext is pre-applied with the module name
            # so authors write `lib.mkContext ./path` instead of
            # `lib.mkContext "kubeadm" ./path`.
            moduleLib = libFunctions // {
              mkContext = core.mkContext moduleName;
            };
          in
          libFunctions.callBake modulePath { lib = moduleLib; }
        ) modules
        // {
          modules = builtins.mapAttrs (name: _: self.${name}) modules;
        };
    in
    nixLib.fix scopeFn;

  # Generate a docker-bake.json file as a Nix-store path.
  # scope: the fully-resolved scope (output of mkScope)
  # module: the name of the module to serialize (must be a key in scope.modules)
  #
  # builtins.unsafeDiscardStringContext is needed because builtins.toFile
  # cannot reference store paths produced by builtins.path (used by mkContext).
  # The context paths are already realized at eval time and Docker reads them
  # at runtime, so Nix dependency tracking on the bake file is not needed.
  mkBakeFile =
    { scope, module }:
    let
      available = builtins.concatStringsSep ", " (builtins.attrNames scope.modules);
      mod =
        scope.modules.${module}
          or (throw "mkBakeFile: module '${module}' not found in scope. Available modules: ${available}");
      serialized = serialize.serialize scope mod;
    in
    builtins.toFile "docker-bake.json" (
      builtins.unsafeDiscardStringContext (builtins.toJSON serialized)
    );
in
{
  inherit mkScope mkBakeFile;
}
