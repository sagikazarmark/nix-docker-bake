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
            inherit (core) mkTarget mkContext mkContextWith;

            # callBake: auto-inject function arguments from the scope, allow overrides.
            callBake =
              modulePath: overrides:
              let
                fn = import modulePath;
                autoArgs = builtins.intersectAttrs (builtins.functionArgs fn) self;
                module = fn (autoArgs // overrides);
              in
              core.checkModule modulePath module;

            # Fork the scope with an overlay and return the forked scope.
            # Consumers typically access `.modules.<name>` on the result to
            # pull in a specific module resolved under the fork. Transitive
            # callBake calls inside the resolved module see the overlay.
            extend = overlay: nixLib.fix (nixLib.extends overlay scopeFn);

          };
        in
        config
        // {
          # Library functions namespaced under lib, mirroring nixpkgs conventions.
          lib = libFunctions;

          # Return a new scope with the given overlay applied.
          extend = overlay: nixLib.fix (nixLib.extends overlay scopeFn);
        }
        // builtins.mapAttrs (
          moduleName: modulePath:
          let
            # Per-module lib: mkContext/mkContextWith are pre-applied with the
            # module name so authors write `lib.mkContext ./path` instead of
            # `lib.mkContext "kubeadm" ./path`.
            moduleLib = libFunctions // {
              mkContext = core.mkContext moduleName;
              mkContextWith = core.mkContextWith moduleName;
            };
            resolved = libFunctions.callBake modulePath { lib = moduleLib; };
          in
          # _scope is attached AFTER callBake (which runs checkModule) so
          # validation only sees consumer-authored keys. Do not reorder.
          resolved // { _scope = self; }
        ) modules
        // {
          modules = builtins.mapAttrs (name: _: self.${name}) modules;
        };
    in
    nixLib.fix scopeFn;

  # Generate a docker-bake.json file as a Nix-store path.
  # Takes a resolved module value (from scope.modules.X or scope.X).
  # The module carries a _scope back-reference so cross-module target
  # identity resolution in the serializer has what it needs.
  #
  # builtins.unsafeDiscardStringContext is needed because builtins.toFile
  # cannot reference store paths produced by builtins.path (used by mkContext).
  # The context paths are already realized at eval time and Docker reads them
  # at runtime, so Nix dependency tracking on the bake file is not needed.
  mkBakeFile =
    module:
    let
      scope =
        module._scope
          or (throw "mkBakeFile: module is missing _scope back-reference; was it produced by mkScope?");
      serialized = serialize.serialize scope module;
    in
    builtins.toFile "docker-bake.json" (
      builtins.unsafeDiscardStringContext (builtins.toJSON serialized)
    );
in
{
  inherit mkScope mkBakeFile;
}
