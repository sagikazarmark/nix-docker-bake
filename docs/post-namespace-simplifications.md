# Post-namespace simplification candidates

Findings from a review of the library after `namespace` was dropped from target and module identity (commit b666a8b). All five landed in a single cleanup pass; this document is kept as a change-note summarizing what was removed and why.

## 1. Dropped the `mkContext` / `mkContextWith` prefix — **shipped**

**Before:** The `prefix` argument was prepended to the store-path *name* of the imported context. Inside `mkScope`, each module received a per-module `lib.mkContext` / `lib.mkContextWith` with the registry key pre-applied, so authors wrote `lib.mkContext ./.` and the module name became part of the store-path name.

**Why it no longer earned its keep:** Contexts are content-addressed via `builtins.path`. Two `./image` directories with different contents already produce different store hashes — the prefix was purely a human-readable label, not a collision-avoidance mechanism. Under the post-namespace identity model, target identity is determined by registry key (first-level) or content hash (second-level), so the store-path name never participates in identity.

**What simplified:**

- `mkContext` is now `path -> storePath` (one argument); `mkContextWith` is `attrs -> storePath`.
- The per-module `moduleLib` specialization in `scope.nix` collapsed. Since `lib` is now uniform across modules, `callBake`'s auto-injection picks it up from the scope directly; the module-resolution body is a one-line `mapAttrs` over `callBake`.
- Public API asymmetry resolved: one entry point, same signature inside and outside modules.

**Tests removed:** `testScopeMkContextAutoPrefix`, `testScopeMkContextWithAutoPrefix`, `testScopeMkContextWithMatchesMkContext`, `testLibExtendMkContextIsStorePath`, `testLibExtendMkContextWithIsStorePath`, `testMkContextNameContainsPrefix`, `testMkContextWithNameContainsPrefix`. The unused `tests/fixtures/mkctx-mod.nix` fixture was deleted; the `forkable-mkctx-mod.nix` fixture stripped its `_ctxStr` / `_ctxWithStr` witnesses.

**API impact:** Breaking. `bake.lib.mkContext "prefix" ./.` → `bake.lib.mkContext ./.`.

## 2. Removed the `_scope` back-ref on resolved modules — **shipped**

**Before:** Every resolved module carried `_scope = self`, creating an intentional cycle between scope and modules. The in-tree comment admitted it was kept "for backward compatibility (some consumers may read it); the serializer no longer depends on it."

**What simplified:**

- `callBake`'s `mkModule` no longer wraps the checked module in a `_scope` back-ref.
- Scope↔module cycle is gone — the data model is easier to reason about.
- Removed `testMkScopeModuleCarriesScopeBackref` and `testModuleOverridePreservesScope`.
- Updated `API.md` language around `.override` / `lib.callBake` results.

**API impact:** Breaking only if an out-of-tree wrapper read `module._scope`. No such consumer is known in-tree.

## 3. Replaced `if allValid then targets else throw "unreachable"` — **shipped**

`scope.nix` `checkTargetNames` now uses `assert allValid; targets`. `builtins.all` still fires the per-target throws on validation failure; `assert` forces the boolean. The "unreachable" branch is gone.

## 4. Collapsed `indexedMembers` in `processGroup` — **shipped**

`serialize.nix` no longer pre-builds an `{ i, m }` pair list via `genList`. `processGroupMember` now derives the synthetic-name index from `builtins.length acc.ids`, and the fold consumes `members` directly. Six lines shorter.

## 5. Archived `docs/issue-27-analysis.md` as an ADR — **shipped**

Moved to `docs/decisions/0001-drop-namespace.md` with a "Status: shipped" header preserving it as historical design context.

---

## Considered and rejected

- **`nix-lib.nix` reimplementing `fix` / `extends` / `makeOverridable`.** Deliberate design choice ("No nixpkgs dependency"). Keep.
- **Reserved-name check in `scope.nix` (`lib`, `extend`, `override`, `modules`).** Still load-bearing — these names collide with scope-level keys. Keep.
- **`checkGroupDuplicates` two-list accumulator.** Slightly awkward but correct. A foldl'-with-attrset-counts form is marginally more idiomatic but not worth the churn.
- **`core.nix` `overrideAttrs` removing `overrideAttrs` before re-calling `mkTarget`.** Necessary because `mkTarget`'s allowlist rejects unknown keys; the method itself is not in the allowlist. Keep.
