# flake-parts module: exposes an overlay that mirrors the flake's `bake.lib` surface under `pkgs.bake.lib`.
{ self, ... }:
{
  flake.overlays.default = _final: _prev: {
    bake = {
      lib = self.lib;
    };
  };
}
