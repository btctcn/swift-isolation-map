# Fixing `DeclarationLinker`'s bare-name `syntactic:<Name>` placeholder collision

Closes [issue #95](https://github.com/btctcn/swift-isolation-map/issues/95), filed while
investigating `docs/task-objc-enum-accessor-linking.md` §3.

## 1. The bug

A top-level type's syntactic placeholder USR (`SyntacticIdentity.typeUSR(_:)`) is just
`"syntactic:<Name>"` -- a bare name, no file or module qualification. `DeclarationLinker
.buildUSRRewriteMap` computed each declaration's own, correctly-disambiguated real USR (via
`Self.disambiguate(candidates:declarationName:)` at that declaration's own real location) and then
immediately discarded that per-declaration correctness by storing it into a single flat
`[String: String]` map keyed by the (potentially colliding) placeholder string. When two genuinely
different, unrelated real declarations across the project happened to share a bare name, both wrote
to the same key -- only the last one processed during iteration survived, and `link()`'s own
identity-rewrite step (`usr: rewritten(declaration.usr)`) then silently redirected *both*
declarations' entries to that single surviving value, merging them into one `byUSR` entry.

Real, confirmed evidence: the main app declares its own `LogLevel` enum
(`lsboutique/Models/LogLevel.swift`), completely unrelated to the `MindboxLogger` pod's own
`LogLevel` enum (`Pods/MindboxLogger/MindboxLogger/Shared/Group/LogLevel.swift`). Both are genuinely
compiled and independently indexed -- unlike the already-fixed GestureView/Swiftfin shape
(`link(_:)`'s own `rewrittenReference` doc comment), this isn't a compiled-vs-uncompiled-file
problem; both sides are real, and both disambiguate correctly and unambiguously at their own real
location. They still collided purely because of the shared bare-name key.

## 2. The fix

`buildUSRRewriteMap` now also returns `ownUSRByLocation: [LocationKey: String]` -- the same
`match.usr` the existing loop already computes for each declaration, additionally keyed by that
declaration's own location instead of only by its placeholder string. `link()`'s identity-rewrite
step prefers this per-location match for a declaration's own `usr` field, falling back to the
existing name-keyed `rewritten(_:)` only when the declaration has no location or its own location
didn't independently resolve (identical to prior behavior for every declaration not involved in a
collision -- both maps are built from the same per-declaration matches, so a non-colliding
declaration's answer is bit-for-bit identical either way).

Deliberately scoped to a declaration's *own* identity only. A cross-reference
(`containingTypeUSR`/`superclassUSR`/a conformance's `protocolUSR`, resolved via
`rewrittenReference`) has no location of its own to key by -- it's a reference to some *other*
declaration by bare name alone, and disambiguating that is a structurally different, harder problem
(already partially mitigated by the existing `filesWithIndexedSymbols`-gated GestureView/Swiftfin
fix, not touched here).

## 3. Real `Project Iris` corpus, before/after

Measured in two steps to isolate this fix's own impact from `docs/task-objc-enum-accessor-linking.md`'s
already-merged `enclosingObjCEnumUSR` matcher:

| | baseline (main, pre-#95) | this fix alone | this fix + `enclosingObjCEnumUSR` (final) |
|---|---|---|---|
| External oracle unknown | 1573 | 1513 (-60) | **1512** (-61) |
| Cross-isolation edges (denominator) | 1856 | -- | **1847** |
| Unresolved edges (isUnknown) | 106 | 101 (-5) | **97** (-9) |
| Unresolved % | 5.7% | -- | **5.3%** |

The "this fix alone" column was run on a branch based on `main` *before* `enclosingObjCEnumUSR`
existed -- it already shows a real, standalone drop (-60 unknown, -5 unresolved edges), confirming
the placeholder collision affects more than just the `LogLevel` cluster that led to finding it: any
same-named top-level declaration pair anywhere in the real corpus benefits. Direct inspection
confirmed `c:@M@MindboxLogger@E@LogLevel` (the pod's own enum) and `s:9Ls_net_ru8LogLevelO` (the
app's own, unrelated enum) now both exist as independent, correct nodes in the linked output, no
longer merged.

Combining with `enclosingObjCEnumUSR` closes the loop this investigation started: all 4 previously-
`isUnknown` edges into `MindboxLogger.LogLevel.rawValue` are gone from the final run's own
cross-isolation-edge list entirely (both endpoints now correctly `nonisolated`, no longer a
cross-isolation edge at all).

`highRiskBoundaries` (1471), `mainActorTypes` (12105), and `typesAnalyzed` (35454) are unchanged
between baseline and the final combined run -- confirms the drop is resolved uncertainty, not
hidden or newly-introduced risk.

## 4. Status

**FIXED AND VERIFIED.** New unit test
(`DeclarationLinkerUnitTests.linkKeepsTwoUnrelatedSameNamedCompiledTypesSeparate`, canned-data,
reproduces the exact `LogLevel`/Project-Iris shape), full suite passing (464/464), real-corpus
before/after above from two separate runs (fix alone, then combined with #96's already-merged fix).
