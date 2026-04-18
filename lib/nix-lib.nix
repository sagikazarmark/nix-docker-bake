# Minimal Nix helpers. No nixpkgs dependency.
rec {
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

  # Wrap an attrset-returning function so the result carries an `.override`
  # method. `.override newArgs` re-evaluates the function with the original
  # args shallow-merged with `newArgs`, and the result is itself overridable
  # so chained calls work. Mirrors nixpkgs `lib.makeOverridable` semantics
  # for the attrset case (no derivation-specific behaviour).
  makeOverridable =
    f: origArgs:
    let
      result = f origArgs;
    in
    result
    // {
      override = newArgs: makeOverridable f (origArgs // newArgs);
    };

}
