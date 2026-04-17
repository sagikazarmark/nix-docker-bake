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

  testCheckModulePassesOnlyTargets = {
    expr = checkModule ./x {
      namespace = "n";
      targets = { };
    };
    expected = {
      namespace = "n";
      targets = { };
    };
  };

  testCheckModulePassesOnlyGroups = {
    expr = checkModule ./x {
      namespace = "n";
      groups = { };
    };
    expected = {
      namespace = "n";
      groups = { };
    };
  };

  testCheckModulePassesNamespaceOnly = {
    expr = checkModule ./x { namespace = "n"; };
    expected = {
      namespace = "n";
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
