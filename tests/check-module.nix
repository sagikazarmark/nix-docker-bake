{ bake, ... }:
let
  inherit (bake) checkModule;

  validModule = {
    namespace = "n";
    targets = { };
    groups = { };
  };
in
{
  testCheckModulePassesValid = {
    expr = checkModule ./x validModule;
    expected = validModule;
  };

  testCheckModuleThrowsMissingNamespace = {
    expr =
      (builtins.tryEval (
        checkModule ./x {
          targets = { };
          groups = { };
        }
      )).success;
    expected = false;
  };

  testCheckModuleThrowsNonStringNamespace = {
    expr =
      (builtins.tryEval (
        checkModule ./x {
          namespace = 42;
          targets = { };
          groups = { };
        }
      )).success;
    expected = false;
  };

  testCheckModuleThrowsEmptyNamespace = {
    expr =
      (builtins.tryEval (
        checkModule ./x {
          namespace = "";
          targets = { };
          groups = { };
        }
      )).success;
    expected = false;
  };

  testCheckModuleThrowsNonAttrsetTargets = {
    expr =
      (builtins.tryEval (
        checkModule ./x {
          namespace = "n";
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
          namespace = "n";
          targets = { };
          groups = {
            default = { };
          };
        }
      )).success;
    expected = false;
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
