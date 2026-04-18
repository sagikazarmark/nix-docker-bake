{ bake, ... }:
let
  inherit (bake) checkModule;

  # Minimal valid module: both `targets` and `groups` are optional.
  validModule = {
    targets = { };
    groups = { };
  };
in
{
  testCheckModulePassesValid = {
    expr = checkModule ./x validModule;
    expected = validModule;
  };

  testCheckModulePassesEmptyAttrset = {
    expr = checkModule ./x { };
    expected = { };
  };

  testCheckModuleThrowsNonAttrsetTargets = {
    expr =
      (builtins.tryEval (
        checkModule ./x {
          targets = [ ];
          groups = { };
        }
      )).success;
    expected = false;
  };

  testCheckModuleThrowsNonListGroupValue = {
    expr =
      (builtins.tryEval (
        checkModule ./x {
          targets = { };
          groups = {
            default = { };
          };
        }
      )).success;
    expected = false;
  };

  testCheckModulePassesOnlyTargets = {
    expr = checkModule ./x {
      targets = { };
    };
    expected = {
      targets = { };
    };
  };

  testCheckModulePassesOnlyGroups = {
    expr = checkModule ./x {
      groups = { };
    };
    expected = {
      groups = { };
    };
  };

  testCheckModuleAcceptsAttrsetPassthru = {
    expr = checkModule ./x (
      validModule
      // {
        passthru = {
          foo = "bar";
        };
      }
    );
    expected = validModule // {
      passthru = {
        foo = "bar";
      };
    };
  };

  testCheckModuleThrowsNonAttrsetPassthru = {
    expr =
      (builtins.tryEval (checkModule ./x (validModule // { passthru = "not-an-attrset"; }))).success;
    expected = false;
  };
}
