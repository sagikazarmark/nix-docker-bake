# Top-tier module: depends on middle, variable-template args, multi-target groups.
{
  lib,
  tag,
  middle,
  platforms,
  ...
}:
let
  primary = lib.mkTarget {
    name = "primary";
    context = lib.mkContext ./images/primary;
    inherit platforms;
    contexts = {
      root = middle.targets.main;
    };
    args = {
      TOP_VERSION = "\${TOP_VERSION}";
    };
    tags = [ (tag "top/primary") ];
  };

  secondary = lib.mkTarget {
    name = "secondary";
    context = lib.mkContext ./images/secondary;
    inherit platforms;
    contexts = {
      root = middle.targets.ready;
    };
    tags = [ (tag "top/secondary") ];
  };
in
{
  targets = {
    inherit primary secondary;
  };
  groups = {
    default = [
      primary
      secondary
    ];
  };
}
