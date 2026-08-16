# Resolving `MultiTargetDeclarationAliasing`'s own documented compression-divergence limitation

## 1. Context

`MultiTargetDeclarationAliasing.swift`'s own doc comment explicitly called this out as "a known,
deliberately accepted limitation, not a correctness risk": two sibling-target variants of the same
physical declaration can have their real, module-stripped mangled *suffixes* diverge, because Swift's
own mangling substitution compression is sensitive to what identifiers already appeared earlier in
the *same* mangled string -- which the differing module name is part of. Real-corpus data (12 edges
after `docs/task-sc-constant-and-hashable-accessor-matching.md`'s fixes) showed this affects more
than the one originally-known case, so it was worth resolving properly rather than leaving accepted.

## 2. Why not re-derive the compression algorithm

Re-implementing Swift's own real substitution-compression algorithm inside this project carries a
real, meaningful risk: a subtly wrong reimplementation could silently produce a **false-positive**
alias (two genuinely different declarations wrongly treated as the same), directly against this
project's own "never guess" discipline. Confirmed via `swift-demangle` (part of the same toolchain
already relied on elsewhere in this project) against Project Iris's own real USRs:
`CurrentNotifications.removeOldNotifications`, compiled under three separate targets, mangles as
`07CurrentB0C...` under one module (compressed) and `20CurrentNotificationsC...` under the other two
(uncompressed) -- but all three demangle to the identical
`<Module>.CurrentNotifications.(removeOldNotifications in _<hash>)() -> ()` shape once the module name
is stripped. A private/fileprivate member additionally carries a `(name in _<hash>)` discriminator
annotation -- confirmed to differ across all three targets even for the identical physical
declaration (a real, per-compiled-unit-varying hash, never meaningfully comparable across targets) --
stripped the same way.

## 3. Fix

New `Sources/SourceKitDIntegration/DemangledSiblingMatching.swift`:
`moduleAgnosticSignatures(forSwiftUSRs:processRunning:)` batches real `swift-demangle` invocations
(chunked to stay under any real `ARG_MAX`, one output line per input argument, confirmed positional
and order-preserving including for unrecognized input) and returns each USR's module-name-stripped,
discriminator-stripped signature. `bareMemberName(fromSignature:)` extracts just the last identifier
component, used only to cheaply narrow (via each candidate declaration's own already-extracted
`DeclarationInfo.name` -- zero demangling cost) which already-linked declarations are worth demangling
as alias candidates in the first place, never as the actual comparison.

Wired into `ExternalIsolationBackfill.collectEdgeLevelWorkItems` as a second pass, after the existing
per-edge loop: collects every still-unresolved, multi-target-shaped USR the plain suffix comparison
missed, batch-demangles them plus their narrowed candidate pool, and aliases on an **exact**
module-agnostic-signature match -- exactly one candidate must share a signature, same "never guess"
rule as `disambiguate`/`MultiTargetDeclarationAliasing` itself (guards against the same kind of
bare-name collision `docs/task-syntactic-placeholder-name-collision.md` fixed).

## 4. Real `Project Iris` corpus, before/after

| | before | after |
|---|---|---|
| External oracle unknown | 1500 | **1481** (-19) |
| Cross-isolation edges (denominator) | 1831 | **1807** |
| Unresolved edges (isUnknown) | 81 | **46** (-35) |
| Unresolved % | 4.4% | **2.5%** |

`highRiskBoundaries` (1471) unchanged. By far the largest edge-count drop of any single fix this
session, despite touching a comparatively small number of distinct USRs -- each resolved
declaration is referenced from many real call sites across the `Notifications`/`ContentExtension`
targets.

## 5. Not fixed, explicitly set aside: synthesized multi-target declarations with no location anywhere

8 of the remaining unresolved USRs are still `_Release`-module-qualified (`MBPushNotifications`'s own
default `init()`, `NotificaitonMetadata`'s own synthesized case-payload accessor, a couple of
properties). Checked directly against the linked node data: **none** of the 2-3 module variants of
these specific declarations have a real `location` anywhere -- unlike the compression-divergence case
above, there is no "winning sibling" to alias from at all. This is the same, already-documented,
already-accepted structural limitation as `docs/task-implicit-synthesized-declarations.md` (issue
#55): a compiler-synthesized declaration (default init, synthesized accessor) has no `SwiftSyntax`
node in source text, so `DeclarationExtractor` never sees it in the first place, for *any* of the
targets that compile it -- not a new finding, and not attempted here for the same reason #55 gives.

## 6. Status

**FIXED AND VERIFIED**: 7 new unit tests (`DemangledSiblingMatchingTests.swift`) + 1 end-to-end test
in `ExternalIsolationBackfillTests.swift` (using real Project Iris USRs and real `swift-demangle`
output), full suite (476/476) passing, real-corpus before/after above.
