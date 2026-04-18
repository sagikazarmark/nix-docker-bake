# Test module consuming `val` from scope so an overlay can observe the
# overridden value propagating through a scope fork.
{ lib, val, ... }:
{
  targets = {
    t = lib.mkTarget {
      name = "t";
      context = lib.mkContext ./.;
      args.VAL = val;
    };
  };
  groups = { };
}
