# Serialization: walk a module graph, produce a docker-bake.json-shaped attrset.
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

  # Reverse lookup: list of { target, namespace, name } entries.
  buildIdentityMap =
    scope:
    let
      modules = scope.modules or { };
      moduleNames = builtins.attrNames modules;
    in
    builtins.concatMap (
      modName:
      let
        mod = modules.${modName};
        targetNames = builtins.attrNames (mod.targets or { });
      in
      map (tName: {
        target = mod.targets.${tName};
        namespace = mod.namespace;
        name = tName;
      }) targetNames
    ) moduleNames;

  findIdentity =
    entries: target:
    let
      matches = builtins.filter (e: e.target == target) entries;
    in
    if matches == [ ] then null else builtins.head matches;

  computeId =
    entryNamespace: identity: fallback:
    if identity == null then
      fallback
    else if identity.namespace == entryNamespace then
      identity.name
    else
      "${identity.namespace}_${identity.name}";

  walkTarget =
    { entryNamespace, identityEntries }:
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
              ctxIdentity = findIdentity identityEntries ctxVal;
              ctxId = computeId entryNamespace ctxIdentity "${id}__${ctxName}";
            in
            walkTarget { inherit entryNamespace identityEntries; } innerAcc ctxId ctxVal
          else
            innerAcc;

        serializedContexts = builtins.mapAttrs (
          ctxName: ctxVal:
          if builtins.isAttrs ctxVal then
            let
              ctxIdentity = findIdentity identityEntries ctxVal;
              ctxId = computeId entryNamespace ctxIdentity "${id}__${ctxName}";
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
        # attrs (e.g., `passthru`) must not leak into the serialized output.
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

  serialize =
    scope: entryModule:
    let
      identityEntries = buildIdentityMap scope;
      entryNamespace = entryModule.namespace;
      targetNames = builtins.attrNames (entryModule.targets or { });

      initialAcc = {
        target = { };
      };

      afterTargets = builtins.foldl' (
        acc: name:
        walkTarget { inherit entryNamespace identityEntries; } acc name entryModule.targets.${name}
      ) initialAcc targetNames;

      groups = entryModule.groups or { };
      groupNames = builtins.attrNames groups;

      processGroupMember =
        acc: i: member:
        let
          identity = findIdentity identityEntries member;
          syntheticName = "group__${acc.groupName}__${toString (i + 1)}";
          id = computeId entryNamespace identity syntheticName;
          acc' = walkTarget { inherit entryNamespace identityEntries; } acc id member;
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
        in
        acc
        // {
          target = afterMembers.target;
          groupOutputs = acc.groupOutputs // {
            ${groupName} = {
              targets = afterMembers.ids;
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
