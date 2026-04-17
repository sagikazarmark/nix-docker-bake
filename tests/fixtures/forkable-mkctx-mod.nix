# Test module used to verify that lib.extend specializes both
# lib.mkContext and lib.mkContextWith the same way the default resolution path
# does. Consumes `val` from scope so an overlay can observe the overridden
# value propagating through.
{ lib, val, ... }:
let
  ctx = lib.mkContext ./.;
  ctxWith = lib.mkContextWith { path = ./.; };
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
  _ctxWithStr = toString ctxWith;
}
