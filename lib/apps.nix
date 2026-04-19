# Convenience helpers for turning bake modules into flake outputs.
{ mkBakeFile }:
{
  /**
    Build a flake `apps.<name>` entry that regenerates the bake file on
    every invocation and execs `docker buildx bake -f <file> "$@"`.

    `pkgs` is required because we use `pkgs.writeShellScript` to produce
    an executable script. `docker` is NOT pinned in the Nix store: the
    wrapper calls whatever `docker` is on the user's PATH so their
    daemon, buildx plugins, and credentials work unchanged.

    # Type

    ```
    mkBakeApp :: { pkgs :: AttrSet, module :: Module, name :: String ? } -> App
    ```

    # Example

    ```nix
    apps.${system}.bake = bake.lib.mkBakeApp {
      inherit pkgs;
      module = scope.modules.app;
    };
    ```
  */
  mkBakeApp =
    {
      pkgs,
      module,
      name ? "bake",
    }:
    let
      file = mkBakeFile module;
      program = pkgs.writeShellScript "bake-${name}" ''
        exec docker buildx bake -f ${file} "$@"
      '';
    in
    {
      type = "app";
      program = toString program;
      meta.description = "Run `docker buildx bake` against the ${name} bake file.";
    };
}
