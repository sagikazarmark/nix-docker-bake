{ lib, ... }:
{
  targets = {
    app = lib.mkTarget {
      name = "app";
      context = ./.;
      tags = [ "my-app:latest" ];
    };
  };
}
