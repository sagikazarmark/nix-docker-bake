{ bake, ... }:
let
  inherit (bake) checkModule;

  validModule = {
    namespace = "n";
    targets = { };
    groups = { };
    vars = { };
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
          vars = { };
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
          vars = { };
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
          vars = { };
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
          vars = { };
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
          vars = { };
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
