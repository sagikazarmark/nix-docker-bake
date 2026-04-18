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

  # Recursively drop function-valued attributes from a value. Used to compare
  # attrsets for content equality without being thrown off by closures, which
  # Nix compares by pointer identity — two structurally-equal attrsets built
  # from distinct function calls are never `==` as long as either contains a
  # closure (e.g., `mkTarget`'s `overrideAttrs`). Functions encountered inside
  # lists (or otherwise outside an attrset key position) collapse to `null` so
  # the same erasure applies at any depth.
  stripFunctions =
    v:
    if builtins.isFunction v then
      null
    else if builtins.isAttrs v then
      builtins.mapAttrs (_: stripFunctions) (
        builtins.removeAttrs v (builtins.filter (k: builtins.isFunction v.${k}) (builtins.attrNames v))
      )
    else if builtins.isList v then
      map stripFunctions v
    else
      v;
}
