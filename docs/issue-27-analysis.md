# Issue #27 analysis: target identity model

Analysis of [issue #27](https://github.com/sagikazarmark/nix-docker-bake/issues/27) ("accept target names alongside target values in groups and contexts"), the structural problem it points at, the design space for fixing it, and the recommended path forward.

## TL;DR

Issue #27 is right that `lib/serialize.nix`'s identity logic is structurally messy, but it misnames the root cause. The root cause is not "we used values instead of names" — it is:

> **The serializer does a reverse lookup (value → name) across evaluations.**

There are three candidate placements for the name↔value bridge:

- **Option A (the issue's proposal):** authors write names. `groups.default = [ "main" "worker" ]`.
- **Option B:** values self-identify via library-internal `_id`, assigned at module-registration time.
- **Option C (recommended):** values self-identify via a user-written `name` field on `mkTarget`, with `namespace` curried in by the per-module `lib`. Mirrors `mkDerivation` in nixpkgs.

Option C is the most nix-idiomatic of the three, structurally fixes the entire reverse-lookup class of bug, and *strengthens* the "familiar nixpkgs-style API" argument rather than weakening it. It is breaking, but the migration is mechanical (one line per `mkTarget` call). Recommendation: ship Option C, in three phases (additive → serializer collapse → module-shape cleanup), with the breaking change isolated to the third phase.

## Today's design and why it's fragile

The current `lib/serialize.nix` resolves identity in two tiers:

1. **Pointer match.** `e.target == target` — succeeds for the common single-evaluation case.
2. **Fingerprint match.** `stripFunctions e.target == stripFunctions target` — succeeds when two `mkTarget` calls produce structurally-equal targets (e.g., a target reconstructed under `.override`).

A workaround prepends the entry module's own targets to the identity map, because `_scope` is a snapshot from the original fixed-point and goes stale when `.override` re-evaluates the module.

This works (it passes the tests added in #26) but accumulated complexity:

- `_scope` back-reference threaded through `mkBakeFile`
- `stripFunctions` recursive function-erasure helper
- two-tier `findIdentity` with fallback semantics
- entry-prepend in `serialize.nix:153` to defeat `_scope` staleness
- `computeId` to fold namespace prefixing
- `buildIdentityMap` to materialize the identity table

Five composing features create the difficulty. None is wrong individually, but together they force the reverse-lookup machinery:

### Feature 1: `mkTarget` doesn't know its own name

```nix
let main = mkTarget { context = ./.; }; in { targets.main = main; }
```

`main` is constructed before the attrset key `main` exists. The value has no idea it'll later be called `main`. Nixpkgs' `mkDerivation { name = "openssl-3.0.2"; ... }` requires `name` at construction — the value carries its identity from birth.

### Feature 2: Nix attrsets don't propagate keys into values

`{ targets = { main = main; }; }` doesn't add any back-reference from `main` (the value) to `"main"` (the key). When `main` later appears in `groups.default = [ main ]`, the list element has no breadcrumb back to "I came from targets.main." This is just how Nix works.

### Feature 3: `overrideAttrs` is a closure on the target

`mkTarget` attaches `overrideAttrs` as a closure capturing the target attrset. Nix compares closures by **pointer identity**, not by body. Two closures created in separate evaluations are never `==`, even if their source is byte-identical. So `==` between target attrsets is unreliable across evaluations.

### Feature 4: `.override` re-evaluates everything fresh

`mod.override { x = ...; }` re-runs the module function. Every `mkTarget` inside runs again. Every closure is fresh. Pre-override and post-override targets have identical CONFIG but distinct CLOSURES — `!=` even though they represent "the same target." This is what bug #25 hit.

### Feature 5: Docker Bake demands names in output

If Docker Bake said "give me content hashes for target IDs," none of this would matter — the library could content-address target identity and skip name resolution entirely. But Docker Bake's authoring model is name-based, by design.

## Why nixpkgs doesn't have this problem

Nixpkgs hits a structurally similar shape (composable values, override mechanism, fresh values on re-evaluation) but escapes the difficulty cleanly because of one foundational decision:

> **Identity in nixpkgs is `outPath` — a content hash computed by Nix from the derivation's inputs.**

That single choice cascades through everything:

| | nixpkgs | this library (today) |
|---|---|---|
| Identity of a value | `outPath` (content hash) | implicit (parent attrset key) |
| Where identity lives | on the value | in the parent attrset |
| Cross-reference mechanism | pass value, read `outPath` | pass value, reverse-lookup |
| Wire format identifier | content hash | author-chosen name |
| Stable under `.override`? | yes (content-derived) | no (pointer-derived) |
| Stable under closures? | yes (closures don't matter) | no (closures break `==`) |
| Authored name = wire name? | no (`pname` ≠ `outPath`) | yes (key = bake name) |

The library is in an intermediate spot:

- It wants the value-passing ergonomics of nixpkgs.
- It needs the name-as-identifier semantics of docker-bake.
- It cannot have both without bridging logic somewhere.

A truly nixpkgs-faithful identity scheme would compute target ids by hashing inputs — but that loses human-readable bake target names, which is probably a non-starter. So the library will always have *some* bridging logic that nixpkgs doesn't need. The only design question is where the bridging lives.

Three candidate placements:

1. **In a lookup table at serialize time** (today's design — fragile because the value side uses `==` on closures across evaluations).
2. **On the value, assigned by the library at registration** (Option B).
3. **On the value, written by the user at construction** (Option C). Mirrors `mkDerivation`.
4. **In the user's hand, written as strings in groups/contexts** (Option A).

## Option A: authors write names

```nix
groups.default = [ "main" "worker" ];
contexts.base  = "base";
groups.cross   = [ "a.shared" ];   # Phase 2: qualified strings
```

**Pros**

- Matches docker-bake's wire format.
- No reverse lookup. Strings flow straight to JSON.
- Override-proof: strings survive any re-evaluation.
- Errors at serialize time are clear ("unknown target 'maine'").

**Cons**

- Cross-module references (Phase 2) introduce a string-encoded namespace that the library currently owns as code. Relitigates: separator choice, what if names contain the separator, how to error-helpfully on typos, autocomplete behavior.
- Loses the "value path through `middle.targets.main`" type-checking. Today, a typo errors at the call site (undefined attribute); under Option A it errors at serialize time.
- Doesn't naturally express the existing aggregator pattern (`tests/fixtures/integration/aggregator/bake.nix`), which composes foreign targets via value paths.

## Option B: library tags values at registration

The library tags named targets with a library-internal `_id` at module-load time. Author-facing API stays as it is today.

```nix
# inside callBake's mkModule, after checkModule:
let
  raw = core.checkModule modulePath (fn (autoArgs // overrides // extraArgs));
  tagged = raw // {
    targets = builtins.mapAttrs
      (name: t: t // { _id = { namespace = raw.namespace; inherit name; }; })
      (raw.targets or { });
  };
in tagged // { _scope = self; }
```

`serialize.nix` collapses to a one-line `resolveId` that reads `target._id`.

**Pros**

- No author-facing API change.
- Eliminates `_scope`, `stripFunctions`, fingerprint matching, entry-prepend.
- Override-proof: re-tagging happens on every module re-evaluation.

**Cons**

- Identity becomes registration-dependent, not value-intrinsic — the opposite of nixpkgs. The same value can have different `_id` in different modules.
- `_id` is library-internal metadata polluting the user-visible target shape (leading-underscore convention, not enforcement).
- Hidden coupling between `scope.nix` (produces the tag) and `serialize.nix` (consumes it). A future code path that bypasses the `mapAttrs` step silently produces uglier bake files.
- `overrideAttrs` has to strip-and-re-tag `_id` to keep `mkTarget`'s allowlist strict — added subtle behavior.
- Hand-constructed targets bypassing `callBake` don't get tagged.

## Option C: user writes `name`, library curries `namespace` (recommended)

Most nixpkgs-faithful: identity lives on the value, written by the user at construction, the same way `mkDerivation` requires `name`.

### What the author writes

```nix
{ lib, appVersion, base, ... }:
let
  main = lib.mkTarget {
    name    = "main";                    # required, on the value
    context = lib.mkContext ./.;
    contexts.base = base.targets.main;   # value, not a string
    args = { APP_VERSION = appVersion; };
  };
  debug = lib.mkTarget {
    name    = "debug";
    context = lib.mkContext ./.;
    target  = "debug";
  };
in {
  targets = { inherit main debug; };
  groups.default = [ main ];             # values; serializer reads .name
  groups.all     = [ main debug ];
}
```

Note: the module function no longer needs to return `namespace`. The registry key in `mkScope { modules.app = ...; }` becomes the namespace, full stop.

### What the library does

`core.mkTarget` requires both `name` and `namespace` in its allowlist. The per-module `lib.mkTarget` (in `scope.nix`) curries `namespace` from the registry key, the same trick already used for `mkContext`/`mkContextWith`:

```nix
moduleLib = libFunctions // {
  mkContext     = core.mkContext moduleName;
  mkContextWith = core.mkContextWith moduleName;
  mkTarget      = attrs: core.mkTarget (attrs // { namespace = moduleName; });
};
```

Result: every target the user constructs through `lib.mkTarget` is born with `{ name = "main"; namespace = "app"; ... }` — fully self-identifying.

### Serializer collapses

Reverse-lookup machinery is replaced by a one-line resolver that reads identity off the value:

```nix
resolveId = entryNamespace: target: fallback:
  let n = target.name or null; ns = target.namespace or null; in
  if n == null then fallback
  else if ns == null then throw "target '${n}' has no namespace; did it bypass lib.mkTarget?"
  else if ns == entryNamespace then n
  else "${ns}_${n}";
```

Inline targets without a `name` fall through to the synthetic `group__<n>__<i>` fallback, preserving today's UX for anonymous-in-group cases.

### Behavior under the failure modes that motivated #25/#27

| Scenario | Today | Option C |
|---|---|---|
| `.override` re-evaluation | tier-1 fix via fingerprint + entry-prepend | re-eval re-runs `mkTarget` writing the same `name`; identity byte-identical, no workaround needed |
| Two structurally-identical targets | conflated by fingerprint match | distinct values; collisions only if user gives both the same `name` (caught at serialize) |
| Inline target in a group | synthetic `group__<n>__<i>` name | same — `resolveId` falls through |
| Cross-module context | reverse-lookup against `_scope` | target's own `namespace` differs from entry's → emits `target:<ns>_<name>` directly |
| Hand-constructed target (bypassing curry) | reverse-lookup against fingerprint | loud error from `core.mkTarget`'s allowlist (`namespace` required) |

### Why Option C is more nix-idiomatic

- **`name` on the value** mirrors `mkDerivation`'s required `name` field. Identity is born with the value, not assigned later.
- **Attribute key ≠ identity** matches nixpkgs deliberately (`pkgs.openssl.name == "openssl-3.0.2"`; `pkgs.python3` aliases `pkgs.python311`). The attrset key is a lookup convenience, the `name` field is identity. Option C inherits exactly this separation.
- **Namespace as implementation detail** matches the user perspective: from the module author's point of view, namespace exists only to avoid collisions in the wire format. Currying it in via `lib.mkTarget` keeps it invisible to the author while making it intrinsic to the value.

The familiar-API argument *strengthens* under Option C: you move closer to `mkDerivation`, not further away.

### Cross-module references work without coupling

```nix
# aggregator/bake.nix
{ middle, base, ... }:
{
  targets = { };
  groups.default = [
    middle.targets.main   # carries name="main", namespace="middle"
    base.targets.main     # carries name="main", namespace="base"
  ];
}
```

The serializer for the aggregator module sees each value's intrinsic `name`+`namespace`. Different namespaces → emits `middle_main` and `base_main`. No `_scope`, no reverse lookup, no registration step.

### Failure modes the library must catch loudly

Three idioms compose into a silent-collision failure mode that real downstream codebases will hit. Each is fine in isolation; together they produce a target whose `name` doesn't match the attrset key it's registered under, which collides in the wire format.

**Idiom 1: let-binding identifier ≠ attrset key.** Authors use convenient identifiers in `let` bindings but kebab-case strings (or other punctuation-bearing names) for the public attrset key:

```nix
let
  controlPlaneDefaults = lib.mkTarget { name = "controlPlaneDefaults"; ... };
in { targets."control-plane-defaults" = controlPlaneDefaults; }
# wire name: "controlPlaneDefaults" (from .name) — but author probably meant "control-plane-defaults" (the attrset key)
```

The author's eye is on the `let` binding when writing the `mkTarget` call, so they instinctively type the let-binding identifier as `name`. The mismatch is invisible until something downstream tries to invoke the target by its expected wire name.

**Idiom 2: `//` composition silently inherits `name`.** In real codebases, plain `//` composition is at least as common as `overrideAttrs` (downstream sample: ~12 `//` overrides, 0 `overrideAttrs`). Same name-inheritance problem:

```nix
let
  controlPlane         = lib.mkTarget { name = "control-plane"; ... };
  controlPlaneDefaults = controlPlane // { contexts = {...}; tags = [...]; };
  # controlPlaneDefaults.name == "control-plane" — silently inherited
in { targets."control-plane-defaults" = controlPlaneDefaults; }
```

Two attrset keys hold values with the same `name`. Wire-format collision.

**Idiom 3: project-level wrappers over `mkTarget`.** Consumers commonly compose a library primitive with a project convention:

```nix
main = tagTarget "playgrounds/containerd" (
  base // {
    target = null;
    contexts = { root = container-utils.targets.main; };
  }
);
# main.name == base.name, then preserved through tagTarget's own //
```

Two same-named targets in one module's `targets`, or two same-named targets in one group, then becomes the natural consequence of these idioms — not a contrived example:

```nix
targets = {
  main      = lib.mkTarget { name = "main"; ... };
  mainDebug = main.overrideAttrs (old: { args.X = "1"; });   # still name="main"
};
```

This is exactly analogous to writing `{ openssl = pkgs.openssl; openssl' = pkgs.openssl.overrideAttrs (...); }` in nixpkgs — both have the same `name`. Nixpkgs tolerates the collision silently because identity is `outPath`, not `name`. Docker Bake's wire format keys on `name`, so the collision is visible.

The collisions are **user composition errors**, not library traps. The user can directly fix them by writing `name = "..."` explicitly on the `//` or `overrideAttrs` patch. But the library's job is to make the failure **loud and early**:

- An **attrset-key-matches-name check** in module registration catches idioms 1, 2, and 3 at Nix-eval time — before the user ever runs `mkBakeFile`. This is the highest-value early-detection check in the design and should land alongside the identity-model switch (Phase 2), not later.
- A **serialize-time duplicate-name check** catches the residual case where two targets in different attrset slots happen to share a `name` despite each matching its own key (rare, but possible across `//` chains that intentionally reuse a name).

Documentation should pair `overrideAttrs` and `//` examples everywhere — every "how to override a name" snippet must show both forms, because authors reach for `//` at least as often.

### What disappears under Option C

- `lib/nix-lib.nix`: `stripFunctions` (entire function)
- `lib/serialize.nix`: `buildIdentityMap`, `findIdentity`, `computeId`, `moduleIdentityEntries`, the entry-prepend at `serialize.nix:153`, the `identityEntries` parameter threading
- `lib/scope.nix`: `_scope`'s load-bearing role in `mkBakeFile` (the field can stay deprecated for one release if any external consumer reads it, but nothing in the library trusts it anymore)
- `lib/core.nix`: optionally drop the `namespace` requirement from `checkModule` (registry key becomes the source of truth)

Net: roughly 60–80 lines of subtle reverse-lookup logic deleted, replaced by ~10 lines of "read the field off the value." That ratio is what you're paying for stability.

## Comparison

| | Today | Option A (strings) | Option B (`_id` tag) | Option C (`name` on value) |
|---|---|---|---|---|
| Author-facing API change | — | breaking (groups/contexts accept strings) | none | breaking (`name` required on `mkTarget`) |
| Reverse-lookup eliminated | no | yes | yes | yes |
| Identity location | parent attrset key | string in list | library-internal `_id` on value | user-written `name` on value |
| Identity origin | author-supplied key | author-supplied string | library-assigned at registration | author-supplied at construction |
| Override-proof | partial (with workaround) | yes | yes | yes |
| Coupling to `_scope` | yes | no | no | no |
| Coupling between scope.nix and serialize.nix | medium | none | high (hidden) | none |
| Hand-constructed targets | tolerated (fingerprint match) | n/a | silently lose `_id` | loud error from allowlist |
| Cross-module refs | reverse-lookup via `_scope` | qualified strings (`"a.shared"`) | tag carries namespace | value carries namespace |
| Nixpkgs idiomatic | no | no | partially (registration-derived) | yes (mirrors `mkDerivation`) |

## Recommendation: Option C

The structurally correct fix and the most nix-idiomatic API. Identity lives on the value, written at construction, with the namespace half handled invisibly by the per-module `lib` curry. Author writes one extra field per `mkTarget` call; the library deletes ~60–80 lines of subtle reverse-lookup logic.

## Downstream validation (iximiuz-labs-content)

Walked Option C against a real consumer codebase: 13 bake modules spanning base images, playgrounds, and cross-module aggregators (`playgrounds/architect`, `playgrounds/harikube`). Findings:

**What's clean:**
- No external reads of `module.namespace` or `_scope`. D1=a (drop `namespace` from return) lands without hitting any downstream code.
- No `overrideAttrs` usage anywhere across ~13 modules. Composition is plain `//` shallow merge. The proposal's `overrideAttrs`-preservation guidance doesn't touch this codebase but **must be paired with `//` guidance everywhere** (see "failure modes" above).
- Aggregator modules trivially compatible — each cross-module reference self-identifies via its own `name`+`namespace`, which is what aggregators need and what `_scope`-based reverse-lookup currently has to reconstruct.
- Project-level wrappers (a content-addressed `tagTarget` helper) preserve `name` cleanly through `//`.

**Migration effort, single 13-module consumer:**

| | Count | Notes |
|---|---|---|
| `mkTarget` calls needing `name = "..."` | 19 across 11 modules | Mechanical |
| `base // { ... }` overrides needing explicit `name` | ~12, concentrated in `kubeadm-cluster`, `harikubeadm-cluster` | Highest-risk edits — see idioms 1–3 above |
| `namespace = "..."` removals from module returns (D1=a) | 13 | One-line deletions |

Verifiable by byte-identical `docker-bake.json` regression tests.

**Signals that informed the plan:**
- D1=a (registry key IS namespace) confirmed: zero consumers of the divergence flexibility.
- The attrset-key-matches-name check is the highest-value footgun-catcher. It should land in Phase 2 (alongside the identity-model switch), not Phase 3 — see plan below.
- Phase 1 as originally drafted is breaking, not additive: requiring `name` on `core.mkTarget` throws on any caller that hasn't migrated. Re-billed honestly below; consumer prefers the bandaid-rip to a warn-then-throw deprecation cycle.

## Implementation plan

### Decisions to commit to first

These shape the rest. Worth deciding before writing code:

**D1: Where does the namespace come from at scope construction?**
- (a) Registry key IS the namespace. `mkScope { modules.app = ./bake.nix; }` → namespace = `"app"`. Drop `namespace` from the module return value entirely.
- (b) Explicit per-module declaration. `mkScope { modules.app = { namespace = "app"; path = ./bake.nix; }; }`.

**Recommendation: (a).** Today's README already says "Convention: match them." Making it law removes a configuration knob that has no use case (namespace is an implementation detail). One source of truth.

**D2: Inline target without `name` — error or synthetic fallback?**
- Strict: `name` required by `core.mkTarget`. Inline targets must invent a name.
- Lenient: `name` optional. Unnamed inline targets fall through to today's `group__<n>__<i>` synthetic naming.

**Recommendation: lenient.** Strict is more puristic but breaks the natural "throw an inline target into a group" workflow. Synthetic fallback only kicks in for genuinely anonymous values, which is the right place for it.

### Phase 1: foundation — name/namespace on the value (breaking for callers that omit `name`)

Goal: targets self-identify. Library still uses today's reverse-lookup as the serialize-time identity source, but the new fields are present and required.

This phase **is** breaking: any `mkTarget` call without `name` will throw. The existing test suite needs updating in lockstep. Downstream consumers prefer this over a warn-then-throw deprecation cycle (cleaner cutover, no soft phase). If a soft cutover is needed for external coordination, the alternative is to warn on absent `name` here and throw in Phase 2.

1. **`lib/core.nix`: extend `mkTarget`'s allowlist with `name` and `namespace`.** Both required when constructing through `core.mkTarget` directly.
2. **`lib/scope.nix`: curry `lib.mkTarget` per module.** In the per-module `lib` (next to `mkContext`/`mkContextWith`), define `mkTarget = attrs: core.mkTarget (attrs // { namespace = moduleName; })`. Author's `lib.mkTarget { name = "main"; ... }` produces `{ name = "main"; namespace = "app"; ... }`.
3. **`overrideAttrs` and `//` composition both preserve `name` by default.** `overrideAttrs`'s existing `removeAttrs (target // patch) [ "overrideAttrs" ]` already shallow-merges correctly; verify `name`/`namespace` aren't stripped. Plain `//` composition is the user's tool and the library doesn't intercept it — but documentation and the Phase 2 attrset-key-matches-name check together ensure that silent name inheritance through `//` surfaces as a loud error (see idioms 1–3 in "Failure modes the library must catch loudly" above).
4. **Update existing tests** to add `name` to every `mkTarget` call. No behavior tests change yet — only construction-site fixtures.

### Phase 2: collapse the serializer + early-detection checks

Goal: serialize reads identity off the value. Reverse-lookup machinery deleted. The highest-value footgun-catcher (attrset-key-matches-name) lands here, alongside the identity-model switch — fails at Nix-eval time during module registration, not at `mkBakeFile` time.

5. **`lib/serialize.nix`: replace `findIdentity` + `computeId` + `buildIdentityMap` + `moduleIdentityEntries`** with a one-line `resolveId` that reads `target.name` and `target.namespace`. Keep the synthetic-name fallback for anonymous targets.
6. **Drop the `identityEntries` parameter** threaded through `walkTarget`/`walkContext`/`processGroupMember`.
7. **Drop the entry-prepend** in `serialize.nix:153` — no longer needed.
8. **`lib/scope.nix`: remove `_scope` from `mkBakeFile`'s dependency.** Keep `_scope` on the module return value for one release if any downstream consumer reads it; mark deprecated.
9. **`lib/nix-lib.nix`: delete `stripFunctions`.**
10. **Attrset-key-matches-name check at module registration** (the high-value catcher for idioms 1, 2, 3). After the module function returns, walk `module.targets` and assert each value's `name` field equals its attrset key. On mismatch, throw with the module name, the attrset key, and the value's `name`. Cheap, local, fails at eval time. Sketch:

    ```nix
    # inside callBake, after checkModule:
    builtins.mapAttrs (key: target:
      if target ? name && target.name != key then
        throw "module '${moduleName}': targets.${key} has name '${target.name}'; attrset key and name field must match"
      else target
    ) (module.targets or { });
    ```

11. **Serialize-time duplicate-name check** (residual safety, catches the rare case where two distinct attrset slots in different scopes both end up with values sharing a `name`). Walk per-group members; assert no two values share a `name`. On collision, throw with the offending name and the attrset keys it appears under.
12. **Hand-construction safety check.** If a target value reaches the serializer with no `namespace` field, throw a clear error pointing at "did this target come from the per-module `lib.mkTarget`?" Catches the "bypassed the curry" failure mode loudly.

### Phase 3: clean up the module shape (breaking)

Goal: align module return value with the new identity model. This is where D1 lands.

13. **If D1=a: remove `namespace` from the module return value.** `checkModule` no longer requires it. Module-level namespace reads route through the registry key (or via the targets themselves, since each carries its namespace).
14. **Decide on `targets` shape.** With names on values, the attrset key is purely a lookup convenience and could become a list. **Recommendation: keep the attrset shape** — `app.targets.main` is genuinely nicer than `(lib.findFirst (t: t.name == "main") app.targets)`. The attrset-key-matches-name check from Phase 2 already enforces consistency between the lookup key and the wire-format identity.
15. **Update tests.** New tests for: name uniqueness, hand-construction error, attrset-key/name mismatch, module-return without `namespace`.

### Phase 4: docs and migration

16. **Update `README.md`.** Shift "Writing modules" to use `name = "..."` everywhere. Update "Namespace vs registry key" — under D1=a it collapses to "the registry key IS the namespace; targets identify themselves with `name`."
17. **Update `API.md`.** `mkTarget` now requires `name`. Note the curried `lib.mkTarget` behavior. `mkScope`'s module shape unchanged (D1=a) or extended (D1=b). **Pair every `overrideAttrs` example with a `//` example.** Authors reach for `//` at least as often, and the silent-name-inheritance failure mode (idioms 1–3) is identical for both — guidance must cover both.
18. **Add a migration note.** Single sentence: "every `mkTarget` call needs a `name` field matching its attrset key; every `//` or `overrideAttrs` patch that creates a new target must explicitly set `name`." The mechanical change for downstream is one line per target.
19. **Bump major version.** This is breaking.

### Test additions (beyond updating existing ones)

- `mkTarget` without `name` throws with a clear error.
- `mkTarget` outside a module (no namespace from curry) throws or requires explicit namespace.
- Attrset-key-matches-name check: `targets.foo = mkTarget { name = "bar"; ... }` throws at module-registration time with a clear error.
- Idiom 2 coverage: `targets."foo" = (mkTarget { name = "foo"; ... }) // { tags = [...]; }` passes (name preserved); `targets."foo-debug" = foo // { args.X = "1"; }` throws (foo-debug attrset key vs inherited "foo" name).
- Idiom 3 coverage: project-level wrapper that does `// { ... }` over a target is correctly caught when the wrapped target is registered under a different attrset key without an explicit `name` override.
- Two targets with the same `name` in one group throws at serialize (residual duplicate-name check).
- Override-then-serialize: identity stable across `.override` and `.overrideAttrs` (existing tests cover this; verify they still pass without depending on fingerprinting).
- Hand-constructed target reaching serialize without a namespace → loud error.

### PR sequencing

If you want reviewable chunks rather than one monolith:

- **PR 1:** Phase 1 (require `name` on `mkTarget`, curry `namespace` per module, update existing tests). Reverse-lookup still in place; identity model unchanged at serialize time.
- **PR 2:** Phase 2 (collapse serializer + attrset-key-matches-name check + duplicate-name check + hand-construction check). All identity tests pass via the new path. Reverse-lookup machinery deleted. **This is the highest-value PR** — both the structural fix and the early-detection guarantee land together.
- **PR 3:** Phase 3 (module-shape cleanup, D1 lands here). Drops `namespace` from module returns.
- **PR 4:** Docs and migration note.

PRs 1+2 together constitute the major version bump. Phase 3 is the only piece a downstream consumer could deliberately defer; PRs 1 and 2 must ship together to avoid an awkward intermediate state where targets carry `name` but the serializer doesn't trust it.

### Open questions to confirm before starting

- D1 and D2 above.
- Do any current downstream consumers read `module.namespace` or `module._scope` directly? If yes, either keep them deprecated for one release or coordinate the breaking change.
- Should `core.mkTarget` (the un-curried form) be exported at all? Today it's accessible as `bake.lib.mkTarget`. Under Option C, calling it without `namespace` throws. Either keep it for advanced users (with `namespace` required) or remove from the public API and force everyone through the per-module curry.

## What about Option A in the future?

Option A (string acceptance in groups/contexts) is not precluded by Option C. Once Option C lands, a localized additive change in `walkTarget`/`processGroupMember` could accept strings as an alternative form, resolved against the entry module's targets by `name`. Worth shipping only if a real use case appears (declarative tooling generating bake modules, grouping foreign targets without scope access). Defer until then.

## References

- Issue #25 — original bug report (`.override` produces synthetic group member names)
- PR #26 — tier-1 fix (pointer match + fingerprint + entry-prepend)
- Issue #27 — proposal to accept strings in groups and contexts
- `lib/serialize.nix` — current identity-resolution code
- `lib/scope.nix` — module resolution, `callBake`, `mkBakeFile`, per-module `lib` construction
- `lib/core.nix` — `mkTarget`, `overrideAttrs`, `checkModule`
- `tests/serialize.nix` — identity test cases including override scenarios
- `tests/fixtures/integration/aggregator/bake.nix` — value-based cross-module group composition
