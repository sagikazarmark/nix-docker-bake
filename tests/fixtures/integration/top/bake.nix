# Top-tier module: depends on middle, variable-template args, multi-target groups.
{
  lib,
  tag,
  middle,
  platforms,
  ...
}:
let
  args = {
    TOP_VERSION = "\${TOP_VERSION}";
  };

  primary = lib.mkTarget {
    context = lib.mkContext ./images/primary;
    inherit platforms;
    contexts = {
      root = middle.targets.main;
    };
    inherit args;
    tags = [ (tag "top/primary") ];
  };

  secondary = lib.mkTarget {
    context = lib.mkContext ./images/secondary;
    inherit platforms;
    contexts = {
      root = middle.targets.ready;
    };
    tags = [ (tag "top/secondary") ];
  };
in
{
  namespace = "top";
  vars = args;
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
