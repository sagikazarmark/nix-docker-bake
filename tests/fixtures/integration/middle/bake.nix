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
    name = "base";
    context = lib.mkContext ./image;
    target = "base";
    inherit platforms;
    contexts = {
      root = "docker-image://rootfs:base";
    };
    inherit args;
  };

  # `//` composition silently inherits `name` from the LHS, so every derived
  # target must explicitly set its own name to match its registration key —
  # otherwise wire-format identity collides with `baseTarget`.
  ready = baseTarget // {
    name = "ready";
    target = "ready";
  };

  main = baseTarget // {
    name = "main";
    target = null;
    contexts = {
      root = base.targets.main;
    };
    tags = [ (tag "middle") ];
  };
in
{
  targets = {
    inherit main;
    base = baseTarget;
    inherit ready;
  };
  groups = {
    default = [ main ];
  };
}
