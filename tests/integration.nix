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
  parse = moduleName: builtins.fromJSON (builtins.readFile (mkBakeFile scope.modules.${moduleName}));

  baseSer = parse "base";
  middleSer = parse "middle";
  topSer = parse "top";
  aggregatorSer = parse "aggregator";

  # Extended scope for override tests.
  extendedScope = scope.extend (final: prev: { platforms = [ "linux/arm64" ]; });
  extBaseSer = builtins.fromJSON (builtins.readFile (mkBakeFile extendedScope.modules.base));

  # lib.extend: inline modules (builtins.toFile) since they don't need mkContext.
  # These CAN go through mkBakeFile because bare paths don't trigger the toFile restriction.
  cwsAFile = builtins.toFile "cws-a.nix" ''
    { lib, val, ... }:
    {
      targets = { t = lib.mkTarget { name = "t"; context = ./.; args.VAL = val; }; };
      groups = {};
    }
  '';
  cwsBFile = builtins.toFile "cws-b.nix" ''
    { lib, ... }:
    let a = (lib.extend (final: prev: { val = "overridden"; })).modules.a;
    in {
      targets = { t = lib.mkTarget { name = "t"; context = ./.; contexts.root = a.targets.t; }; };
      groups = {};
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
  cwsAParsed = builtins.fromJSON (builtins.readFile (mkBakeFile cwsScope.modules.a));
  cwsBParsed = builtins.fromJSON (builtins.readFile (mkBakeFile cwsScope.modules.b));
in
{
  # ---------- Scenario 1: base module — single-module full round-trip ----------

  testIntBaseHasTopLevelKeys = {
    expr = builtins.sort builtins.lessThan (builtins.attrNames baseSer);
    expected = [
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
    expr = baseSer ? group;
    expected = false;
  };

  # ---------- Scenario 2: middle module — cross-module contexts ----------

  # Cross-module context references are second-level wire ids:
  # `_<namespace>_<name>_<hash>` with a leading underscore to hide from
  # `docker buildx bake --list`.
  testIntMiddleMainCrossModuleRef = {
    expr = builtins.match "target:_base_main_[0-9a-f]+" middleSer.target.main.contexts.root != null;
    expected = true;
  };

  testIntMiddlePullsInBaseMain = {
    expr = builtins.any (n: builtins.match "_base_main_.*" n != null) (
      builtins.attrNames middleSer.target
    );
    expected = true;
  };

  testIntMiddleBaseMainContextIsStorePath =
    let
      baseMainKey = builtins.head (
        builtins.filter (n: builtins.match "_base_main_.*" n != null) (builtins.attrNames middleSer.target)
      );
    in
    {
      expr = builtins.match "/nix/store/.*base.*context" middleSer.target.${baseMainKey}.context != null;
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
    expr = builtins.match "target:_middle_main_[0-9a-f]+" topSer.target.primary.contexts.root != null;
    expected = true;
  };

  testIntTopPullsInMiddleMain = {
    expr = builtins.any (n: builtins.match "_middle_main_.*" n != null) (
      builtins.attrNames topSer.target
    );
    expected = true;
  };

  # Transitive: the pulled-in middle_main target carries middle's
  # cross-module reference into base, which is also second-level.
  testIntTopTransitiveMiddleRefBase =
    let
      middleMainKey = builtins.head (
        builtins.filter (n: builtins.match "_middle_main_.*" n != null) (builtins.attrNames topSer.target)
      );
    in
    {
      expr =
        builtins.match "target:_base_main_[0-9a-f]+" topSer.target.${middleMainKey}.contexts.root != null;
      expected = true;
    };

  testIntTopPullsInBaseMain = {
    expr = builtins.any (n: builtins.match "_base_main_.*" n != null) (
      builtins.attrNames topSer.target
    );
    expected = true;
  };

  testIntTopSecondaryRefMiddleReady = {
    expr =
      builtins.match "target:_middle_ready_[0-9a-f]+" topSer.target.secondary.contexts.root != null;
    expected = true;
  };

  testIntTopPullsInMiddleReady = {
    expr = builtins.any (n: builtins.match "_middle_ready_.*" n != null) (
      builtins.attrNames topSer.target
    );
    expected = true;
  };

  testIntTopGroupDefaultLength = {
    expr = builtins.length topSer.group.default.targets;
    expected = 2;
  };

  testIntTopPrimaryTags = {
    expr = topSer.target.primary.tags;
    expected = [ "registry.example/top/primary:\${CHANNEL}" ];
  };

  # ---------- Scenario 4: aggregator — groups with foreign targets ----------

  # Aggregator has no first-level targets. All group members are foreign
  # (second-level) and serialize to hash-suffixed wire ids.
  testIntAggregatorGroupMembers = {
    expr = builtins.sort builtins.lessThan (
      builtins.map (
        id:
        let
          m = builtins.match "(_base_main|_middle_main)_[0-9a-f]+" id;
        in
        if m == null then id else builtins.head m
      ) aggregatorSer.group.default.targets
    );
    expected = [
      "_base_main"
      "_middle_main"
    ];
  };

  testIntAggregatorPullsInMiddleMain = {
    expr = builtins.any (n: builtins.match "_middle_main_.*" n != null) (
      builtins.attrNames aggregatorSer.target
    );
    expected = true;
  };

  testIntAggregatorPullsInBaseMain = {
    expr = builtins.any (n: builtins.match "_base_main_.*" n != null) (
      builtins.attrNames aggregatorSer.target
    );
    expected = true;
  };

  # The aggregator has no own targets, so only foreign second-level
  # targets (and their transitive deps) should appear, all with the
  # `_<ns>_<name>_<hash>` shape.
  testIntAggregatorNoOwnNamespaceTargets = {
    expr = builtins.filter (n: builtins.match "_(base|middle)_.*" n == null) (
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

  # ---------- Scenario 6: lib.extend through mkBakeFile ----------

  # The overridden a.t is a structurally distinct attrset than the original
  # scope.modules.a.targets.t (lib.extend re-evaluates the module fresh).
  # Both carry the same `name`+`namespace`, but the foreign reference goes
  # through the second-level content-addressed wire id.
  testIntCwsOverriddenArgInJson =
    let
      atKey = builtins.head (
        builtins.filter (n: builtins.match "_a_t_.*" n != null) (builtins.attrNames cwsBParsed.target)
      );
    in
    {
      expr = cwsBParsed.target.${atKey}.args.VAL;
      expected = "overridden";
    };

  testIntCwsCrossModuleRef = {
    expr = builtins.match "target:_a_t_[0-9a-f]+" cwsBParsed.target.t.contexts.root != null;
    expected = true;
  };

  testIntCwsBaseScopeUnaffected = {
    expr = cwsAParsed.target.t.args.VAL;
    expected = "default";
  };
}
