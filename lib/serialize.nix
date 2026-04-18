# Serialization: walk a module graph, produce a docker-bake.json-shaped attrset.
#
# Identity model: each target carries `name` and `namespace` on the value
# itself (set by core.mkTarget's allowlist and the per-module lib.mkTarget
# curry). The serializer reads identity directly from the value — there is
# no reverse lookup, no _scope dependency, no closure-pointer comparison.
#
# Anonymous values (e.g., inline targets in groups/contexts that omit `name`)
# fall through to a synthetic-name fallback. Values that carry a `name` but
# no `namespace` indicate a target constructed outside the per-module
# `lib.mkTarget` curry — a hand-construction failure mode that throws loudly.
let
  # Serialize a context value (path or string).
  # Paths become their absolute string form. Strings pass through.
  serializeContext =
    value:
    if builtins.isPath value then
      toString value
    else if builtins.isString value then
      value
    else
      throw "serializeContext: unsupported type (got ${builtins.typeOf value})";

  # Resolve a target value to its wire-format id.
  #
  # - Anonymous (no name): caller-supplied fallback (synthetic name).
  # - Has name but no namespace: hand-construction outside the per-module
  #   curry — throw with a clear pointer at the likely cause.
  # - Same namespace as the entry module: bare name.
  # - Different namespace: namespace-prefixed (Docker Bake's cross-module
  #   reference convention).
  resolveId =
    entryNamespace: target: fallback:
    let
      n = target.name or null;
      ns = target.namespace or null;
    in
    if n == null then
      fallback
    else if ns == null then
      throw "serialize: target '${n}' is missing a 'namespace' field; this typically means the target was constructed outside the per-module `lib.mkTarget` (which curries the namespace in). Either construct it via the per-module lib, or pass `namespace = \"<module>\"` explicitly."
    else if ns == entryNamespace then
      n
    else
      "${ns}_${n}";

  walkTarget =
    { entryNamespace }:
    acc: id: target:
    if acc.target ? ${id} then
      acc
    else
      let
        contexts = target.contexts or { };
        contextNames = builtins.attrNames contexts;

        walkContext =
          innerAcc: ctxName:
          let
            ctxVal = contexts.${ctxName};
          in
          if builtins.isAttrs ctxVal then
            let
              ctxId = resolveId entryNamespace ctxVal "${id}__${ctxName}";
            in
            walkTarget { inherit entryNamespace; } innerAcc ctxId ctxVal
          else
            innerAcc;

        serializedContexts = builtins.mapAttrs (
          ctxName: ctxVal:
          if builtins.isAttrs ctxVal then
            let
              ctxId = resolveId entryNamespace ctxVal "${id}__${ctxName}";
            in
            "target:${ctxId}"
          else
            serializeContext ctxVal
        ) contexts;

        hasArgs = target ? args && target.args != { };
        hasTags = target ? tags && target.tags != null && target.tags != [ ];
        hasTarget = target ? target && target.target != null;
        hasContexts = contexts != { };
        hasPlatforms = target ? platforms && target.platforms != null;

        # Explicit allowlist — do not splat `target //` here. Unknown target
        # attrs (e.g., `passthru`, `name`, `namespace`) must not leak into
        # the serialized output.
        serialized = {
          context = serializeContext target.context;
          dockerfile = target.dockerfile;
        }
        // (if hasPlatforms then { inherit (target) platforms; } else { })
        // (if hasTarget then { inherit (target) target; } else { })
        // (if hasContexts then { contexts = serializedContexts; } else { })
        // (if hasArgs then { inherit (target) args; } else { })
        // (if hasTags then { inherit (target) tags; } else { });

        acc' = acc // {
          target = acc.target // {
            ${id} = serialized;
          };
        };
      in
      builtins.foldl' walkContext acc' contextNames;

  # Detect duplicate wire-format names within a single group's resolved
  # member ids. Catches the rare residual case where two distinct values
  # in one group end up with the same `name` despite each matching its
  # own attrset key — typically a `//` chain that intentionally reuses a
  # name without registering both targets under that key.
  checkGroupDuplicates =
    groupName: ids:
    let
      seen =
        builtins.foldl'
          (
            s: id:
            if builtins.elem id s.dups then
              s
            else if builtins.elem id s.ids then
              s // { dups = s.dups ++ [ id ]; }
            else
              s // { ids = s.ids ++ [ id ]; }
          )
          {
            ids = [ ];
            dups = [ ];
          }
          ids;
    in
    if seen.dups == [ ] then
      ids
    else
      throw "serialize: group '${groupName}' contains duplicate target name(s): ${builtins.concatStringsSep ", " seen.dups}. Each group member must serialize to a distinct wire-format id; rename the conflicting target(s) via `overrideAttrs (old: { name = \"...\"; })` or by setting `name` on the `//` patch.";

  serialize =
    entryModule:
    let
      # The entry module's namespace. Read from the targets themselves
      # (every registered target carries its namespace) rather than from
      # the module attrset, so this works even after Phase 3 drops the
      # `module.namespace` field. Falls back to the deprecated module field
      # for the empty-targets case.
      entryNamespace =
        let
          targets = entryModule.targets or { };
          names = builtins.attrNames targets;
        in
        if names != [ ] then
          targets.${builtins.head names}.namespace or (entryModule.namespace or null)
        else
          entryModule.namespace or null;
      targetNames = builtins.attrNames (entryModule.targets or { });

      initialAcc = {
        target = { };
      };

      afterTargets = builtins.foldl' (
        acc: name:
        let
          target = entryModule.targets.${name};
          id = resolveId entryNamespace target name;
        in
        walkTarget { inherit entryNamespace; } acc id target
      ) initialAcc targetNames;

      groups = entryModule.groups or { };
      groupNames = builtins.attrNames groups;

      processGroupMember =
        acc: i: member:
        let
          syntheticName = "group__${acc.groupName}__${toString (i + 1)}";
          id = resolveId entryNamespace member syntheticName;
          acc' = walkTarget { inherit entryNamespace; } acc id member;
        in
        acc'
        // {
          ids = acc.ids ++ [ id ];
        };

      processGroup =
        acc: groupName:
        let
          members = groups.${groupName};
          innerAcc = acc // {
            inherit groupName;
            ids = [ ];
          };
          indexedMembers = builtins.genList (i: {
            inherit i;
            m = builtins.elemAt members i;
          }) (builtins.length members);
          afterMembers = builtins.foldl' (a: im: processGroupMember a im.i im.m) innerAcc indexedMembers;
          checkedIds = checkGroupDuplicates groupName afterMembers.ids;
        in
        acc
        // {
          target = afterMembers.target;
          groupOutputs = acc.groupOutputs // {
            ${groupName} = {
              targets = checkedIds;
            };
          };
        };

      afterGroups = builtins.foldl' processGroup (
        afterTargets
        // {
          groupOutputs = { };
        }
      ) groupNames;
    in
    (if afterGroups.target != { } then { target = afterGroups.target; } else { })
    // (if afterGroups.groupOutputs != { } then { group = afterGroups.groupOutputs; } else { });
in
{
  inherit serialize;
}
