# Two more matching fixes, batched together per a process change

## 1. Context

Continuing from `docs/task-multi-target-declaration-aliasing.md`'s §5 baseline (real
`Project Iris` corpus, 21% of cross-isolation edges unresolved). Two independent, unrelated shapes
were investigated, each reproduced and fixed against a fast local repro (no Xcode project needed
for either), then verified together in a single combined corpus run -- a deliberate process change
from this investigation's own earlier pattern of one corpus run per fix, adopted because per-fix
corpus runs (10-15 minutes each on this real ~2200-file workspace) were becoming the dominant cost
as individual fixes' own real-corpus impact shrank.

## 2. Finding: subscript accessor USR vs. subscript declaration USR

`NSDictionary["key"]`/`NSMutableDictionary["key"] = value` -- a Swift-declared `subscript` on an
imported Clang class -- produced ~25 real mentions across the corpus (`NSDictionary`,
`NSMutableDictionary`), plus a related Swift-stdlib case, `s:SayxSicis` (`Array<T>.subscript(Int)`
setter, `"Sa"` being Array's own real mangling substitution).

Checked via a real, from-scratch minimal reproduction (a plain macOS Swift file + a direct
`cursorinfo` probe against the actual toolchain -- `NSDictionary` needs no iOS-specific SDK
surface): confirmed both `NSDictionary["key"]` (get) and `NSMutableDictionary["key"] = value` (set)
hover to `s:So12NSDictionaryC10FoundationEyypSgypcip`/
`s:So19NSMutableDictionaryC10FoundationEyypSgypcip` respectively -- the **declaration** form
(`"cip"` suffix), plain `@objc dynamic subscript(_:) -> Any? { get set }`, no isolation attribute.
Both `symbolgraph-extract`'s bulk output and a live hover key the subscript this way -- never by
the **accessor**-specific form (`"cig"`/`"cis"`) the call graph's own `calleeUSR` actually carries.

**Fix**: new `Sources/IsolationCore/SubscriptAccessorDeclarationMatching.swift`.
`subscriptDeclarationUSR(forAccessorUSR:)` requires the *exact* three-character `"cig"`/`"cis"`
suffix (never a bare trailing `"g"`/`"s"` alone, which every ordinary property accessor also ends
in -- the `"ci"` component specifically marks a subscript accessor), and derives the declaration
form by replacing the final letter with `"p"`. Wired into
`ExternalIsolationBackfill.collectEdgeLevelWorkItems` as a pre-filter: once rewritten, the
declaration form is looked up directly in the bulk cache (Foundation and Swift are both default
bulk modules) -- zero live query, and the real cached isolation is reused verbatim (not assumed
`.nonisolated`, since a subscript could in principle carry an attribute even though none of the
real examples here do).

## 3. Finding: Swift mangling substitution compression defeats `BridgedExternConstantMatching`'s strict grammar

`NSURLResourceKey` members (`isDirectoryKey`, `creationDateKey`, `volumeTotalCapacityKey`, ...) --
17 real mentions -- share `BridgedExternConstantMatching`'s own confirmed, shipped shape
(typealias-wrapper marker `"a"`, `"ABvgZ"`-suffixed static getter) but were never resolved by that
already-merged fix (#82/#86).

Checked via the same kind of real probe: `s:So16NSURLResourceKeya011isDirectoryB0ABvgZ` contains a
`"B0"` component -- Swift's own real mangling **substitution compression** (a back-reference to an
earlier-seen identifier fragment, almost certainly `"Key"` here) -- in place of a second plain
length-prefixed identifier. `BridgedExternConstantMatching.parse()`'s own strict two-shape grammar
has no notion of this compression at all, so it correctly returns `nil` rather than misparsing it.

**Fix**: new `Sources/SourceKitDIntegration/BridgedExternConstantContainerMatching.swift`, a
sibling to `BridgedExternConstantMatching` (not a modification -- the existing type's own strict
grammar is real, shipped, independently-tested behavior for its own confirmed shape). Following
`ObjCProtocolPropertyWitnessMatching`'s own established reasoning: deliberately never parses or
compares the member's own name at all -- only the type name (for the container-type-USR check,
identical formula to the existing type's own) plus `declLang`/USR-prefix checks. A pure coverage
*widening*, checked only after `BridgedExternConstantMatching` itself has already failed.

## 4. Real `Project Iris` corpus, before/after (both fixes together, one combined run)

| | before | after |
|---|---|---|
| External oracle unknown | 1588 | **1573** (-15 distinct USRs) |
| Cross-isolation edges (denominator) | 1922 | **1856** |
| Unresolved edges (isUnknown) | ~172 | **106** |
| Unresolved % | 21% | **5.7%** |

By far the largest *percentage* jump in the whole investigation, despite a modest-looking drop in
distinct unresolved USRs (-15) -- both `NSDictionary`/`NSMutableDictionary` subscripts and
`NSURLResourceKey` members are each referenced from dozens of real call sites across the corpus, so
resolving a handful of distinct USRs cleared a disproportionate number of individual edges. The
tool's own "anomalously high uncertainty" warning, present in every prior run's own output this
whole investigation, no longer fires at all.

Confirmed the drop is a genuine improvement, not a degraded/stale run: `highRiskBoundaries` (1471)
and `mainActorTypes` (12105) stayed consistent with recent prior runs, and the specific USRs
targeted by each fix (`NSDictionary`, `NSMutableDictionary`, `NSURLResourceKey`, `s:SayxSicis`)
are completely absent from the new run's own remaining unknown-edge bucket breakdown.

## 5. Not fixed, explicitly set aside: CocoaPods source declaration linking

Investigated but deliberately not pursued this round: `Mindbox`/`MindboxLogger`/`DeviceKit` (Pod
source, not the analyzed app's own module) each contribute real, unresolved `rawValue`/property
edges whose *declaring enum/type itself* doesn't appear to be reliably linked into
`linked.declarations` at all -- e.g. `MindboxLogger.LogLevel.rawValue`
(`s:13MindboxLogger8LogLevelO8rawValueSivg`) stays `isUnknown` even though
`SynthesizedEnumAccessorMatching` (already shipped) should cover it *if* the enum itself were
linked. Confirmed the source file genuinely is among the "2226 Swift source files" this tool scans
(756 of them are under `Pods/`), so this looks like a `DeclarationLinker`-level gap specific to
third-party pod source, not another USR-matching-shape gap like the eight fixes in this whole
investigation -- a structurally different, deeper class of investigation, set aside rather than
guessed at without first tracing the real linking failure the way every other finding here was
traced.

## 6. Status

**FIXED AND VERIFIED**, batched (per the process change in §1): 12 new unit tests
(`SubscriptAccessorDeclarationMatchingTests.swift`, `BridgedExternConstantContainerMatchingTests.swift`)
+ 4 end-to-end tests in `ExternalIsolationBackfillTests.swift`, real-corpus before/after above from
one combined run.
