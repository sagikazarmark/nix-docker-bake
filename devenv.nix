{ ... }:

{
  languages = {
    nix = {
      enable = true;
    };
  };

  treefmt = {
    enable = true;
    config.programs = {
      nixfmt.enable = true;
    };
  };
}
