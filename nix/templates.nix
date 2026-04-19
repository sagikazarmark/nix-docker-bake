# flake-parts module: expose a starter template.
{ ... }:
{
  flake.templates.default = {
    path = ../templates/default;
    description = "A minimal docker-bake project using nix-docker-bake";
  };
}
