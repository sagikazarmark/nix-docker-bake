{ bake, ... }:
let
  inherit (bake) describeScope;

  testScope = {
    modules = {
      foo = {
        targets = {
          main = {
            context = ./.;
            args = {
              KEY = "value";
            };
          };
        };
        groups = { };
      };
    };
  };
in
{
  testDescribeScopeReturnsString = {
    expr = builtins.isString (describeScope testScope);
    expected = true;
  };

  testDescribeScopeContainsModuleName = {
    expr = builtins.match ".*foo.*" (describeScope testScope) != null;
    expected = true;
  };

  testDescribeScopeHandlesEmptyScope = {
    expr = builtins.isString (describeScope {
      modules = { };
    });
    expected = true;
  };

  testDescribeScopeHandlesMissingModulesKey = {
    expr = builtins.isString (describeScope { });
    expected = true;
  };
}
