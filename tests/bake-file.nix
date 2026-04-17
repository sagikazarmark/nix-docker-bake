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

  bakeFilePath = mkBakeFile {
    inherit scope;
    module = "test";
  };

  parsed = builtins.fromJSON (builtins.readFile bakeFilePath);
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
}
