# flake-parts module: exposes the bake library at the flake level.
{ ... }:
{
  flake.lib = import ../lib { };
}
