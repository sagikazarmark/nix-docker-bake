# Test module that uses the scope-injected lib.mkContext and lib.mkContextWith
# (both pre-applied with the module's registry key). Used by ../scope.nix tests.
{ lib, ... }:
let
  ctx = lib.mkContext ./.;
  ctxWith = lib.mkContextWith { path = ./.; };
in
{
  namespace = "ctxmod";
  targets = {
    main = lib.mkTarget { context = ctx; };
  };
  groups = { };
  _ctxStr = toString ctx;
  _ctxWithStr = toString ctxWith;
}
