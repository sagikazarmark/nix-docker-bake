# Minimal Nix helpers. No nixpkgs dependency.
{
  # Fixed-point combinator. Used to build self-referencing attrsets.
  fix =
    f:
    let
      x = f x;
    in
    x;

  # Overlay application. Given an overlay and a base function, produces
  # a new function that can be passed to `fix` to apply the overlay.
  # overlay: (self: super: attrset)
  # base: (self: attrset)
  # returns: (self: attrset)
  extends =
    overlay: base: self:
    let
      super = base self;
    in
    super // overlay self super;
}
