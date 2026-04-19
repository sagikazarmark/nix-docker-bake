{ bake, ... }:
let
  inherit (bake) mkScope mkBakeApp;

  # Mock pkgs: real pkgs.writeShellScript produces an executable store
  # path via a derivation. For pure-eval tests we mock it with
  # builtins.toFile, which returns the same shape (a store-path string)
  # and lets us read the generated script content without invoking a
  # builder. The mock drops the exec bit, but mkBakeApp's correctness
  # does not depend on it; the template smoke test in Task 4 exercises
  # the real writeShellScript path end-to-end.
  mockPkgs = {
    writeShellScript = name: text: builtins.toFile name text;
  };

  moduleFile = builtins.toFile "apps-mod.nix" ''
    { lib, ... }:
    {
      targets.main = lib.mkTarget { name = "main"; context = ./.; };
      groups = {};
    }
  '';

  scope = mkScope {
    moduleArgs = { };
    modules.demo = moduleFile;
  };

  app = mkBakeApp {
    pkgs = mockPkgs;
    module = scope.modules.demo;
    name = "demo";
  };

  appDefaultName = mkBakeApp {
    pkgs = mockPkgs;
    module = scope.modules.demo;
  };

  programText = builtins.readFile app.program;
in
{
  testMkBakeAppTypeIsApp = {
    expr = app.type;
    expected = "app";
  };

  testMkBakeAppProgramIsStorePath = {
    expr = builtins.match "/nix/store/[a-z0-9]+-bake-demo" app.program != null;
    expected = true;
  };

  testMkBakeAppProgramExecsDockerBuildx = {
    expr =
      builtins.match ".*exec docker buildx bake -f /nix/store/[^ ]+ \"\\\$@\".*" programText != null;
    expected = true;
  };

  testMkBakeAppHasMetaDescription = {
    expr = builtins.isString app.meta.description;
    expected = true;
  };

  testMkBakeAppDefaultsNameToBake = {
    expr = builtins.match "/nix/store/[a-z0-9]+-bake-bake" appDefaultName.program != null;
    expected = true;
  };
}
