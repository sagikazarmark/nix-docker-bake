# Scope construction and bake file generation.
{
  nixLib,
  core,
  serialize,
}:
let
  /**
    Build a fixed-point scope from consumer-supplied `config` and a set of
    `modules` (attrset of `name -> path`). Module functions are resolved via
    auto-injection (`builtins.functionArgs`) against the resolved scope.

    The returned scope exposes `lib` (library primitives), `extend` / `override`
    (fork helpers), `modules.<name>` (resolved modules), and any attributes
    propagated from `config`.

    # Type

    ```
    mkScope :: { config :: AttrSet, modules :: AttrSet } -> Scope
    ```
  */
  # Build a fixed-point scope function from consumer-supplied config and module paths.
  # config: opaque attrset; values flow to modules via callModule auto-injection.
  # modules: attrset of `name -> path-to-bake.nix`.
  mkScope =
    {
      config,
      modules,
    }:
    let
      reservedNames = [
        "lib"
        "extend"
        "override"
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
          # Fork the scope with an overlay and return the forked scope.
          # Consumers typically access `.modules.<name>` on the result to
          # pull in a specific module resolved under the fork. Transitive
          # callModule calls inside the resolved module see the overlay.
          extend = overlay: nixLib.fix (nixLib.extends overlay scopeFn);

          # Plain-attrs sugar over extend. Use this when you just want to
          # replace config values; reach for extend when you need the
          # (final: prev: ...) form (e.g., self-referential rewrites).
          override = attrs: extend (_: _: attrs);

          # Validate that every registered target's `name` field matches
          # its attrset key. Catches the three silent-collision idioms:
          #   (1) let-binding identifier ≠ attrset key
          #   (2) `//` composition silently inheriting `name` from LHS
          #   (3) project-level wrapper helpers compounding (1) or (2)
          # Fires at module-registration time, before mkBakeFile ever
          # runs (fail-fast on a typo). Uses `builtins.all` (strict on
          # its elements) to force each per-target validation eagerly,
          # so the throw fires when the module is registered, not when
          # someone later accesses `module.targets.<key>`.
          checkTargetNames =
            modName: targets:
            let
              validate =
                key:
                let
                  target = targets.${key};
                in
                if !(target ? name) then
                  throw "module '${modName}': targets.${key} is missing the required 'name' field. Add `name = \"${key}\"` to the mkTarget call."
                else if target.name != key then
                  throw "module '${modName}': targets.${key} has name '${target.name}' but is registered under key '${key}'. The `name` field and the attrset key must match (did you derive this target via `//` or `overrideAttrs` and forget to set `name = \"${key}\"` on the patch?)"
                else
                  true;
              allValid = builtins.all validate (builtins.attrNames targets);
            in
            assert allValid;
            targets;

          libFunctions = {
            # Library primitives exposed for module consumption.
            inherit (core) mkTarget mkContext mkContextWith;

            # callModule: auto-inject function arguments from the scope, allow overrides.
            # The returned module carries `.override`: a per-instance argument
            # swap that re-runs the module function with new args, leaving the
            # scope and sibling modules untouched. Mirrors nixpkgs `pkg.override`.
            callModule =
              modulePath: overrides:
              let
                fn = import modulePath;
                autoArgs = builtins.intersectAttrs (builtins.functionArgs fn) self;
                pathLabel = baseNameOf (toString modulePath);
                mkModule =
                  extraArgs:
                  let
                    raw = core.checkModule modulePath (fn (autoArgs // overrides // extraArgs));
                  in
                  if raw ? targets then raw // { targets = checkTargetNames pathLabel raw.targets; } else raw;
              in
              nixLib.makeOverridable mkModule { };

            inherit extend override;
          };
        in
        config
        // {
          # Library functions namespaced under lib, mirroring nixpkgs conventions.
          lib = libFunctions;

          inherit extend override;
        }
        // builtins.mapAttrs (_: modulePath: libFunctions.callModule modulePath { }) modules
        // {
          modules = builtins.mapAttrs (name: _: self.${name}) modules;
        };
    in
    nixLib.fix scopeFn;

  /**
    Generate a `docker-bake.json` file as a Nix-store path from a resolved
    module value (typically `scope.modules.<name>` or `scope.<name>`).

    Identity resolution is content-addressed: registry key at the first level,
    content hash at the second.

    # Type

    ```
    mkBakeFile :: Module -> StorePath
    ```
  */
  # Generate a docker-bake.json file as a Nix-store path.
  # Takes a resolved module value (from scope.modules.X or scope.X).
  # Identity resolution happens entirely off the target values themselves:
  # registry key at first level, content hash at second level.
  #
  # builtins.unsafeDiscardStringContext is needed because builtins.toFile
  # cannot reference store paths produced by builtins.path (used by mkContext).
  # The context paths are already realized at eval time and Docker reads them
  # at runtime, so Nix dependency tracking on the bake file is not needed.
  mkBakeFile =
    module:
    let
      serialized = serialize.serialize module;
    in
    builtins.toFile "docker-bake.json" (
      builtins.unsafeDiscardStringContext (builtins.toJSON serialized)
    );
in
{
  inherit mkScope mkBakeFile;
}
