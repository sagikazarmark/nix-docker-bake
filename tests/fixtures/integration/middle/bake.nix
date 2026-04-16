# Mid-tier module: depends on base, multiple target variants, cross-module context.
{
  lib,
  tag,
  base,
  platforms,
  ...
}:
let
  args = {
    MIDDLE_VERSION = "1.0";
  };

  baseTarget = lib.mkTarget {
    context = lib.mkContext ./image;
    target = "base";
    inherit platforms;
    contexts = {
      root = "docker-image://rootfs:base";
    };
    inherit args;
  };

  ready = baseTarget // {
    target = "ready";
  };

  main = baseTarget // {
    target = null;
    contexts = {
      root = base.targets.main;
    };
    tags = [ (tag "middle") ];
  };
in
{
  namespace = "middle";
  vars = args;
  targets = {
    inherit main;
    base = baseTarget;
    inherit ready;
  };
  groups = {
    default = [ main ];
  };
}
