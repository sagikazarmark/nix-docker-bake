# Test module used to verify that callBakeWithScope specializes lib.mkContext
# the same way the default resolution path does. Consumes `val` from scope
# so an overlay can observe the overridden value propagating through.
{ lib, val, ... }:
let
  ctx = lib.mkContext ./.;
in
{
  namespace = "forkable";
  targets = {
    t = lib.mkTarget {
      context = ctx;
      args.VAL = val;
    };
  };
  groups = { };
  _ctxStr = toString ctx;
}
