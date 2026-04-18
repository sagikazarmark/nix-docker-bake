# Serialization: walk a module graph, produce a docker-bake.json-shaped attrset.
#
# Identity model: each target carries `name` and `namespace` on the value
# itself (set by core.mkTarget's allowlist and the per-module lib.mkTarget
# curry). Wire ids are resolved via a two-level classification:
#
#   - First-level target: a key of entryModule.targets. Wire id is `name`
#     (PR #30 guarantees `namespace == entryNamespace` for these via
#     registration-time stamping).
#   - Second-level target: any target reached via walking contexts.<name>
#     or groups.<name> and not itself a key of entryModule.targets. Wire
#     id is `_<namespace>_<name>_<hash>`, where `hash` is an 8-hex-char
#     content hash computed over the target's wire-format fields,
#     excluding identity metadata (`name`, `namespace`, `overrideAttrs`,
#     `passthru`). Sub-contexts hash recursively.
#
# Dedup: when emitting a second-level target, its content hash is compared
# against an index of first-level content hashes. A match resolves the
# reference to the first-level target's bare name rather than materializing
# a second entry. This closes the capture hazard where a let-binding is
# both registered under targets.<key> (post-stamp) and captured via another
# target's contexts.<name> (pre-stamp) — the two values differ only on
# `namespace`, so their content hashes match and dedup collapses them.
#
# Anonymous values (e.g., inline targets in groups/contexts that omit
# `name`) fall through to a synthetic-name fallback. Values that carry a
# `name` but no `namespace` indicate a target constructed outside the
# per-module `lib.mkTarget` curry — a hand-construction failure mode that
# throws loudly.
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

  # Stable stringification of a context value for hash input.
  # Leaf contexts (paths, strings) use their wire form; attrset contexts
  # (references to other targets) recurse via contentHash so the hash is
  # purely content-addressed and independent of wire-id resolution.
  hashContext =
    value: if builtins.isAttrs value then "hash:${contentHash value}" else serializeContext value;

  # Content hash of a target — 8 hex chars (32 bits) of sha256 over a
  # deterministic JSON stringification of the wire-format fields.
  #
  # Included: context, dockerfile, target, args, tags, platforms, contexts
  # (mirrors the `serialized` attrset in walkTarget below).
  # Excluded: name, namespace, overrideAttrs, passthru.
  #
  # Field-presence predicates mirror walkTarget's `hasX` checks so two
  # targets that serialize to byte-identical wire output also produce
  # the same hash (e.g., `tags = []` and missing `tags` are equivalent,
  # as they are in the wire output).
  #
  # Nix attrsets serialize with sorted keys via builtins.toJSON, so the
  # stringification is stable across evaluations.
  contentHash =
    target:
    let
      contexts = target.contexts or { };
      hashedContexts = builtins.mapAttrs (_: hashContext) contexts;

      hasArgs = target ? args && target.args != { };
      hasTags = target ? tags && target.tags != null && target.tags != [ ];
      hasTarget = target ? target && target.target != null;
      hasContexts = contexts != { };
      hasPlatforms = target ? platforms && target.platforms != null;

      hashInput = {
        context = serializeContext target.context;
        dockerfile = target.dockerfile;
      }
      // (if hasPlatforms then { inherit (target) platforms; } else { })
      // (if hasTarget then { inherit (target) target; } else { })
      // (if hasContexts then { contexts = hashedContexts; } else { })
      // (if hasArgs then { inherit (target) args; } else { })
      // (if hasTags then { inherit (target) tags; } else { });
    in
    builtins.substring 0 8 (builtins.hashString "sha256" (builtins.toJSON hashInput));

  # Resolve a target value to its wire-format id.
  #
  # - Anonymous (no name): caller-supplied fallback (synthetic name).
  # - Has name but no namespace: hand-construction outside the per-module
  #   curry — throw with a clear pointer at the likely cause.
  # - Name matches a first-level key AND content hash matches that
  #   target: dedup to that key. This is the common case (same-module
  #   same-name identity) and is checked first so two first-level
  #   targets with coincidentally equal content hashes still resolve
  #   each to its own key.
  # - Content hash matches some first-level target: dedup to that
  #   target's bare key. Uniform regardless of origin (own module,
  #   foreign, scope fork) — same content = same id.
  # - Otherwise second-level: `_<namespace>_<name>_<hash>`. The leading
  #   underscore hides these from `docker buildx bake --list`.
  #
  # `firstLevelNameToHash` and `firstLevelHashIndex` are precomputed
  # once per serialize call so the name-match check is an O(1) attrset
  # lookup rather than a repeated contentHash recursion.
  resolveId =
    firstLevelNameToHash: firstLevelHashIndex: target: fallback:
    let
      n = target.name or null;
      ns = target.namespace or null;
    in
    if n == null then
      fallback
    else if ns == null then
      throw "serialize: target '${n}' is missing a 'namespace' field; this typically means the target was constructed outside the per-module `lib.mkTarget` (which curries the namespace in). Either construct it via the per-module lib, or pass `namespace = \"<module>\"` explicitly."
    else
      let
        h = contentHash target;
      in
      if firstLevelNameToHash.${n} or null == h then
        n
      else if firstLevelHashIndex ? ${h} then
        firstLevelHashIndex.${h}
      else
        "_${ns}_${n}_${h}";

  walkTarget =
    { firstLevelNameToHash, firstLevelHashIndex }:
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
              ctxId = resolveId firstLevelNameToHash firstLevelHashIndex ctxVal "${id}__${ctxName}";
            in
            walkTarget {
              inherit firstLevelNameToHash firstLevelHashIndex;
            } innerAcc ctxId ctxVal
          else
            innerAcc;

        serializedContexts = builtins.mapAttrs (
          ctxName: ctxVal:
          if builtins.isAttrs ctxVal then
            let
              ctxId = resolveId firstLevelNameToHash firstLevelHashIndex ctxVal "${id}__${ctxName}";
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
  # in one group end up with the same wire id — typically two values that
  # content-hash-match each other but are meant to be distinct, or a
  # hash-collision edge case.
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
      firstLevelTargets = entryModule.targets or { };
      targetNames = builtins.attrNames firstLevelTargets;

      # key → content hash. Computed once per serialize call; used by
      # resolveId's name-match fast path without recomputing hashes on
      # every reference.
      firstLevelNameToHash = builtins.mapAttrs (_: contentHash) firstLevelTargets;

      # content hash → first-level key. Used to dedup second-level
      # targets that content-hash-match a first-level target. A target's
      # content hash is a deterministic function of its wire-format
      # fields, so a second-level value that differs from its first-level
      # counterpart only on identity metadata (namespace in particular:
      # the PR #30 pre-stamp vs post-stamp case) collapses cleanly here.
      #
      # Two first-level targets can coincidentally share a content hash
      # (e.g., identical build config under different names). listToAttrs
      # is last-wins; since targetNames comes from attrNames it is
      # alphabetically sorted, so the later key wins deterministically.
      # resolveId's name-match check runs first regardless, so each
      # first-level target still resolves to its own key.
      firstLevelHashIndex = builtins.listToAttrs (
        builtins.map (key: {
          name = firstLevelNameToHash.${key};
          value = key;
        }) targetNames
      );

      # Pre-flight: every first-level target must carry a namespace.
      # resolveId enforces this when a value is referenced (via
      # contexts or groups), but a first-level target that is not
      # referenced anywhere else would otherwise slip through. Done
      # via a list that forces evaluation on each entry.
      _assertFirstLevelNamespaces = builtins.map (
        key:
        let
          t = firstLevelTargets.${key};
        in
        if t ? name && !(t ? namespace) then
          throw "serialize: target '${t.name}' is missing a 'namespace' field; this typically means the target was constructed outside the per-module `lib.mkTarget` (which curries the namespace in). Either construct it via the per-module lib, or pass `namespace = \"<module>\"` explicitly."
        else
          null
      ) targetNames;

      initialAcc = {
        target = { };
      };

      # First-level targets walk under their attrset keys directly.
      # checkTargetNames (scope.nix) guarantees key == target.name, so
      # this is equivalent to resolving via resolveId but sidesteps the
      # hash-index lookup for the top-level pass.
      afterTargets = builtins.foldl' (
        acc: name:
        let
          target = firstLevelTargets.${name};
        in
        walkTarget {
          inherit firstLevelNameToHash firstLevelHashIndex;
        } acc name target
      ) initialAcc targetNames;

      groups = entryModule.groups or { };
      groupNames = builtins.attrNames groups;

      processGroupMember =
        acc: i: member:
        let
          syntheticName = "group__${acc.groupName}__${toString (i + 1)}";
          id = resolveId firstLevelNameToHash firstLevelHashIndex member syntheticName;
          acc' = walkTarget {
            inherit firstLevelNameToHash firstLevelHashIndex;
          } acc id member;
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
    builtins.deepSeq _assertFirstLevelNamespaces (
      (if afterGroups.target != { } then { target = afterGroups.target; } else { })
      // (if afterGroups.groupOutputs != { } then { group = afterGroups.groupOutputs; } else { })
    );
in
{
  inherit serialize contentHash;
}
