# Human-readable scope introspection (for debugging).
{
  /**
    Return a human-readable string summarizing a scope's modules, their
    targets, and key properties (context path, args count, groups).

    Intended for debugging; do not parse the output.

    # Type

    ```
    describeScope :: Scope -> String
    ```

    # Example

    ```
    scope (2 modules):
      base: 1 target
        main  [context=./.  args=0]
      api: 2 targets, groups default
        base  [context=./images/api  args=2]
        main  [context=./images/api  args=2]
    ```
  */
  describeScope =
    scope:
    let
      modules = scope.modules or { };
      moduleNames = builtins.attrNames modules;

      describeTarget =
        tname: target:
        let
          contextStr = toString (target.context or "?");
          argCount = builtins.length (builtins.attrNames (target.args or { }));
        in
        "    ${tname}  [context=${contextStr}  args=${toString argCount}]";

      describeModule =
        mname:
        let
          mod = modules.${mname};
          tnames = builtins.attrNames (mod.targets or { });
          groupNames = builtins.attrNames (mod.groups or { });
          groupsLabel =
            if groupNames == [ ] then "" else ", groups " + builtins.concatStringsSep ", " groupNames;
          targetLines = map (t: describeTarget t mod.targets.${t}) tnames;
        in
        [
          "  ${mname}: ${toString (builtins.length tnames)} target${
              if builtins.length tnames == 1 then "" else "s"
            }${groupsLabel}"
        ]
        ++ targetLines;

      header = "scope (${toString (builtins.length moduleNames)} modules):";
      body = builtins.concatLists (map describeModule moduleNames);
    in
    builtins.concatStringsSep "\n" ([ header ] ++ body);
}
