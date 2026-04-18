{ bake, ... }:
let
  inherit (bake) mkScope mkBakeFile;

  moduleFile = builtins.toFile "bake-file-mod.nix" ''
    { lib, myConfigValue, ... }:
    {
      namespace = "test";
      targets = { main = lib.mkTarget { context = ./.; args.VAL = myConfigValue; }; };
      groups = {};
    }
  '';

  scope = mkScope {
    config = {
      myConfigValue = "hello";
    };
    modules.test = moduleFile;
  };

  bakeFilePath = mkBakeFile scope.modules.test;

  parsed = builtins.fromJSON (builtins.readFile bakeFilePath);

  # mkBakeFile must work on a module returned by .override. This exercises
  # _scope preservation through the override wrapper.
  overriddenBakeFile = mkBakeFile (scope.modules.test.override { myConfigValue = "via-override"; });
  parsedOverridden = builtins.fromJSON (builtins.readFile overriddenBakeFile);

  # _scope must also survive a chained override; mechanically the same path
  # through mkModule, but assert it so a future refactor cannot silently
  # break the chain case.
  chainedBakeFile = mkBakeFile (
    (scope.modules.test.override { myConfigValue = "first"; }).override {
      myConfigValue = "second";
    }
  );
  parsedChained = builtins.fromJSON (builtins.readFile chainedBakeFile);
in
{
  testMkBakeFileReturnsStorePath = {
    expr = builtins.match "/nix/store/.*-docker-bake.json" (toString bakeFilePath) != null;
    expected = true;
  };

  testMkBakeFileContainsExpectedTargetArgs = {
    expr = parsed.target.main.args.VAL;
    expected = "hello";
  };

  testMkBakeFileWorksOnOverriddenModule = {
    expr = parsedOverridden.target.main.args.VAL;
    expected = "via-override";
  };

  testMkBakeFileWorksOnChainedOverriddenModule = {
    expr = parsedChained.target.main.args.VAL;
    expected = "second";
  };
}
