# End-to-end tests: real module files → mkScope → mkBakeFile → JSON → assertions.
#
# Tests exercise the full pipeline from real .nix fixture files through scope
# resolution, serialization, and mkBakeFile JSON output.
{ bake, ... }:
let
  inherit (bake) mkScope mkBakeFile;

  # ---------- scope setup ----------

  scope = mkScope {
    config = {
      defaultRoot = "docker-image://rootfs:ubuntu";
      platforms = [ "linux/amd64" ];
      tag = name: "registry.example/${name}:\${CHANNEL}";
    };
    modules = {
      base = ./fixtures/integration/base/bake.nix;
      middle = ./fixtures/integration/middle/bake.nix;
      top = ./fixtures/integration/top/bake.nix;
      aggregator = ./fixtures/integration/aggregator/bake.nix;
    };
  };

  # Full round-trip through mkBakeFile: serialize → JSON file → parse.
  parse =
    module:
    builtins.fromJSON (
      builtins.readFile (mkBakeFile {
        inherit scope module;
      })
    );

  baseSer = parse "base";
  middleSer = parse "middle";
  topSer = parse "top";
  aggregatorSer = parse "aggregator";

  # Extended scope for override tests.
  extendedScope = scope.extend (final: prev: { platforms = [ "linux/arm64" ]; });
  extBaseSer = builtins.fromJSON (
    builtins.readFile (mkBakeFile {
      scope = extendedScope;
      module = "base";
    })
  );

  # callBakeWithScope: inline modules (builtins.toFile) since they don't need mkContext.
  # These CAN go through mkBakeFile because bare paths don't trigger the toFile restriction.
  cwsAFile = builtins.toFile "cws-a.nix" ''
    { lib, val, ... }:
    {
      namespace = "a";
      targets = { t = lib.mkTarget { context = ./.; args.VAL = val; }; };
      groups = {};
      vars = {};
    }
  '';
  cwsBFile = builtins.toFile "cws-b.nix" ''
    { lib, ... }:
    let a = lib.callBakeWithScope ${cwsAFile} (final: prev: { val = "overridden"; });
    in {
      namespace = "b";
      targets = { t = lib.mkTarget { context = ./.; contexts.root = a.targets.t; }; };
      groups = {};
      vars = {};
    }
  '';
  cwsScope = mkScope {
    config = {
      val = "default";
    };
    modules = {
      a = cwsAFile;
      b = cwsBFile;
    };
  };
  cwsAParsed = builtins.fromJSON (
    builtins.readFile (mkBakeFile {
      scope = cwsScope;
      module = "a";
    })
  );
  cwsBParsed = builtins.fromJSON (
    builtins.readFile (mkBakeFile {
      scope = cwsScope;
      module = "b";
    })
  );
in
{
  # ---------- Scenario 1: base module — single-module full round-trip ----------

  testIntBaseHasTopLevelKeys = {
    expr = builtins.sort builtins.lessThan (builtins.attrNames baseSer);
    expected = [
      "group"
      "target"
    ];
  };

  testIntBaseTargetMainExists = {
    expr = baseSer.target ? main;
    expected = true;
  };

  testIntBaseTargetDockerfile = {
    expr = baseSer.target.main.dockerfile;
    expected = "Dockerfile";
  };

  testIntBaseTargetPlatforms = {
    expr = baseSer.target.main.platforms;
    expected = [ "linux/amd64" ];
  };

  testIntBaseStringContextPassthrough = {
    expr = baseSer.target.main.contexts.root;
    expected = "docker-image://rootfs:ubuntu";
  };

  testIntBaseContextIsStorePath = {
    expr = builtins.match "/nix/store/.*base.*context" baseSer.target.main.context != null;
    expected = true;
  };

  testIntBaseNoGroups = {
    expr = baseSer.group;
    expected = { };
  };

  testIntBaseNoInjectedChannelVariable = {
    expr = (baseSer.variable or { }) ? CHANNEL;
    expected = false;
  };

  # ---------- Scenario 2: middle module — cross-module contexts ----------

  testIntMiddleMainCrossModuleRef = {
    expr = middleSer.target.main.contexts.root;
    expected = "target:base_main";
  };

  testIntMiddlePullsInBaseMain = {
    expr = middleSer.target ? base_main;
    expected = true;
  };

  testIntMiddleBaseMainContextIsStorePath = {
    expr = builtins.match "/nix/store/.*base.*context" middleSer.target.base_main.context != null;
    expected = true;
  };

  testIntMiddleOwnBaseTargetStage = {
    expr = middleSer.target.base.target;
    expected = "base";
  };

  testIntMiddleReadyTargetStage = {
    expr = middleSer.target.ready.target;
    expected = "ready";
  };

  # null target field should be omitted from main.
  testIntMiddleMainNoTargetField = {
    expr = middleSer.target.main ? target;
    expected = false;
  };

  testIntMiddleGroupDefault = {
    expr = middleSer.group.default.targets;
    expected = [ "main" ];
  };

  testIntMiddleTags = {
    expr = middleSer.target.main.tags;
    expected = [ "registry.example/middle:\${CHANNEL}" ];
  };

  # ---------- Scenario 3: top module — deep cross-module chain ----------

  testIntTopPrimaryRefMiddle = {
    expr = topSer.target.primary.contexts.root;
    expected = "target:middle_main";
  };

  testIntTopPullsInMiddleMain = {
    expr = topSer.target ? middle_main;
    expected = true;
  };

  testIntTopTransitiveMiddleRefBase = {
    expr = topSer.target.middle_main.contexts.root;
    expected = "target:base_main";
  };

  testIntTopPullsInBaseMain = {
    expr = topSer.target ? base_main;
    expected = true;
  };

  testIntTopSecondaryRefMiddleReady = {
    expr = topSer.target.secondary.contexts.root;
    expected = "target:middle_ready";
  };

  testIntTopPullsInMiddleReady = {
    expr = topSer.target ? middle_ready;
    expected = true;
  };

  testIntTopGroupDefaultLength = {
    expr = builtins.length topSer.group.default.targets;
    expected = 2;
  };

  testIntTopVariableCollected = {
    expr = topSer.variable ? TOP_VERSION;
    expected = true;
  };

  testIntTopPrimaryTags = {
    expr = topSer.target.primary.tags;
    expected = [ "registry.example/top/primary:\${CHANNEL}" ];
  };

  # ---------- Scenario 4: aggregator — groups with foreign targets ----------

  testIntAggregatorGroupMembers = {
    expr = builtins.sort builtins.lessThan aggregatorSer.group.default.targets;
    expected = [
      "base_main"
      "middle_main"
    ];
  };

  testIntAggregatorPullsInMiddleMain = {
    expr = aggregatorSer.target ? middle_main;
    expected = true;
  };

  testIntAggregatorPullsInBaseMain = {
    expr = aggregatorSer.target ? base_main;
    expected = true;
  };

  # The aggregator has no own targets, so only foreign targets and their
  # transitive deps should appear.
  testIntAggregatorNoOwnNamespaceTargets = {
    expr = builtins.filter (n: !(builtins.match "(base|middle)_.*" n != null)) (
      builtins.attrNames aggregatorSer.target
    );
    expected = [ ];
  };

  # ---------- Scenario 5: scope.extend propagation ----------

  testIntExtendPropagatesPlatforms = {
    expr = extBaseSer.target.main.platforms;
    expected = [ "linux/arm64" ];
  };

  testIntExtendPreservesContext = {
    expr = builtins.match "/nix/store/.*base.*context" extBaseSer.target.main.context != null;
    expected = true;
  };

  # ---------- Scenario 6: callBakeWithScope through mkBakeFile ----------

  # The overridden a.t is a different attrset than scope.modules.a.targets.t,
  # so the identity lookup produces a synthetic name (t__root), not a_t.
  testIntCwsOverriddenArgInJson = {
    expr = cwsBParsed.target.t__root.args.VAL;
    expected = "overridden";
  };

  testIntCwsCrossModuleRef = {
    expr = cwsBParsed.target.t.contexts.root;
    expected = "target:t__root";
  };

  testIntCwsBaseScopeUnaffected = {
    expr = cwsAParsed.target.t.args.VAL;
    expected = "default";
  };
}
