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
  # `_<name>_<hash>` with a leading underscore to hide from
  # `docker buildx bake --list`.
  testIntMiddleMainCrossModuleRef = {
    expr = builtins.match "target:_main_[0-9a-f]{8}" middleSer.target.main.contexts.root != null;
    expected = true;
  };

  testIntMiddlePullsInBaseMain = {
    expr = builtins.any (n: builtins.match "_main_[0-9a-f]{8}" n != null) (
      builtins.attrNames middleSer.target
    );
    expected = true;
  };

  testIntMiddleBaseMainContextIsStorePath =
    let
      baseMainKey = builtins.head (
        builtins.filter (n: builtins.match "_main_[0-9a-f]{8}" n != null) (
          builtins.attrNames middleSer.target
        )
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
    expr = builtins.match "target:_main_[0-9a-f]{8}" topSer.target.primary.contexts.root != null;
    expected = true;
  };

  # Middle's main and base's main share the name "main" but differ in
  # content (middle.main wraps base.main via contexts.root), so they
  # emit as two distinct `_main_<hash>` entries.
  testIntTopHasTwoDistinctMainEntries = {
    expr =
      builtins.length (
        builtins.filter (n: builtins.match "_main_[0-9a-f]{8}" n != null) (builtins.attrNames topSer.target)
      ) == 2;
    expected = true;
  };

  # Transitive: the primary target references middle.main; middle.main
  # in turn references base.main. The second-level entry for middle.main
  # is the one whose `contexts.root` points at another second-level
  # `_main_<hash>` (base.main). The other `_main_<hash>` entry is
  # base.main itself, which has `contexts.root = "docker-image://..."`
  # (a string, not a target reference).
  testIntTopTransitiveMiddleRefBase =
    let
      mainKeys = builtins.filter (n: builtins.match "_main_[0-9a-f]{8}" n != null) (
        builtins.attrNames topSer.target
      );
      middleMainKey = builtins.head (
        builtins.filter (
          k:
          let
            ctx = topSer.target.${k}.contexts.root or "";
          in
          builtins.match "target:_main_[0-9a-f]{8}" ctx != null
        ) mainKeys
      );
    in
    {
      expr =
        builtins.match "target:_main_[0-9a-f]{8}" topSer.target.${middleMainKey}.contexts.root != null;
      expected = true;
    };

  testIntTopSecondaryRefMiddleReady = {
    expr = builtins.match "target:_ready_[0-9a-f]{8}" topSer.target.secondary.contexts.root != null;
    expected = true;
  };

  testIntTopPullsInMiddleReady = {
    expr = builtins.any (n: builtins.match "_ready_[0-9a-f]{8}" n != null) (
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
  # (second-level) and serialize to `_<name>_<hash>` wire ids.
  # Both base.main and middle.main carry name "main" but have distinct
  # content, so both group members match `_main_<hash>`.
  testIntAggregatorGroupMembers = {
    expr = builtins.all (
      id: builtins.match "_main_[0-9a-f]{8}" id != null
    ) aggregatorSer.group.default.targets;
    expected = true;
  };

  testIntAggregatorGroupHasTwoMembers = {
    expr = builtins.length aggregatorSer.group.default.targets;
    expected = 2;
  };

  testIntAggregatorGroupMembersAreDistinct = {
    expr =
      let
        ids = aggregatorSer.group.default.targets;
      in
      builtins.elemAt ids 0 != builtins.elemAt ids 1;
    expected = true;
  };

  # Two distinct `_main_<hash>` entries appear in targets (one for
  # base.main, one for middle.main).
  testIntAggregatorEmitsTwoMainEntries = {
    expr =
      builtins.length (
        builtins.filter (n: builtins.match "_main_[0-9a-f]{8}" n != null) (
          builtins.attrNames aggregatorSer.target
        )
      ) == 2;
    expected = true;
  };

  # The aggregator has no own targets, so only second-level entries
  # (and their transitive deps) should appear, all with the
  # `_<name>_<hash>` shape.
  testIntAggregatorOnlySecondLevelTargets = {
    expr = builtins.all (n: builtins.match "_[a-zA-Z0-9_]+_[0-9a-f]{8}" n != null) (
      builtins.attrNames aggregatorSer.target
    );
    expected = true;
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
  # Both carry the same `name`, but the foreign reference goes through
  # the second-level content-addressed wire id.
  testIntCwsOverriddenArgInJson =
    let
      atKey = builtins.head (
        builtins.filter (n: builtins.match "_t_[0-9a-f]{8}" n != null) (
          builtins.attrNames cwsBParsed.target
        )
      );
    in
    {
      expr = cwsBParsed.target.${atKey}.args.VAL;
      expected = "overridden";
    };

  testIntCwsCrossModuleRef = {
    expr = builtins.match "target:_t_[0-9a-f]{8}" cwsBParsed.target.t.contexts.root != null;
    expected = true;
  };

  testIntCwsBaseScopeUnaffected = {
    expr = cwsAParsed.target.t.args.VAL;
    expected = "default";
  };
}
