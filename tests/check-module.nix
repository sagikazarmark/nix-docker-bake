{ bake, ... }:
let
  inherit (bake) checkModule;

  # Minimal valid module under D1=a: namespace is no longer carried on the
  # module return value (the registry key in mkScope is the canonical
  # namespace). Both `targets` and `groups` are optional.
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

  # Modules that still return a `namespace` field are tolerated for
  # transitional compatibility — the field is ignored downstream (the
  # per-module curry stamps namespace from the registry key instead).
  testCheckModuleToleratesLegacyNamespace = {
    expr = checkModule ./x (validModule // { namespace = "legacy"; });
    expected = validModule // { namespace = "legacy"; };
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
