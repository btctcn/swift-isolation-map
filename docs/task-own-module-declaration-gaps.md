# Three more sources of false `isUnknown` in the project's own module

## 1. Context

Continuing from `docs/task-bulk-extraction-wrong-platform.md`'s §9 baseline (real `Project Iris`
corpus, 67% of cross-isolation edges unresolved after §2/§5/§7/§8): the remaining `Ls_net_ru`
(the project's own module) bucket of `isUnknown` edges turned out to be a mix of at least three
independent, unrelated causes, none of them about external/SDK isolation at all -- every USR
involved is 100% project-local.

The motivating case throughout: a real edge

```
calleeIsolation: nonisolated   calleeUSR: s:9Ls_net_ru10AppearanceV5blackSo7UIColorCvpZ  (Appearance.black)
callerIsolation: globalActor(MainActor)   callerUSR: ...SubscriptionNotifCell(im)awakeFromNib
isUnknown: true
```

-- both sides show a real, resolved, correct isolation, yet the edge is still reported `isUnknown`.
`isUnknown` is computed purely as `unknownUSRs.contains(callerUSR) || unknownUSRs.contains(calleeUSR)`
(`AnalysisReportBuilder.swift`) -- a *separate*, coarser signal from "is this declaration's own final
isolation actually unresolved." All three findings below are ways a USR can land in `unknownUSRs`
despite `IsolationInferenceEngine.resolveIsolation` correctly resolving it via a completely
independent path.

## 2. Fixed: synthesized `RawRepresentable.rawValue`/`CaseIterable.allCases` accessors

A raw-value enum's compiler-synthesized `rawValue` getter and `allCases` static getter have no
physical declaration in source at all -- `SyntaxAnalysis.DeclarationExtractor` is syntax-only and has
no way to see them. Confirmed via a from-scratch mini reproduction
(`enum PaymentWay: String { case card, cash }`): a real call-graph edge targets
`s:15MiniAnchorRepro10PaymentWayO8rawValueSSvg`, and `resolveIsolation` returns `.unspecified` for it
(`declarations[usr] == nil`) -- a genuine, structural gap, not a resolution-tracking bug.

Both accessors are deterministic: neither can ever carry a user-written isolation attribute, so
whenever the *enclosing enum* is a real project-local declaration, the accessor's own effective
isolation is always `.nonisolated`.

**Real USR mangling grammar** (confirmed against 5+ real examples spanning both the mini repro and
`Project Iris`, both top-level and nested-in-a-struct enums):

```
s:<...nominal-context-prefix...><EnumName>O8rawValue<ReturnTypeMangling>vg   // instance getter
s:<...nominal-context-prefix...><EnumName>O8allCases<ReturnTypeMangling>vgZ  // static getter
```

`"rawValue"`/`"allCases"` are each conveniently 8 UTF-8 characters, so both use the literal
length-prefix marker (`"8rawValue"`/`"8allCases"`); the enum's own USR is exactly the substring of
`targetUSR` up to and including the marker's own leading `"O"`.

### Fix

New `Sources/IsolationCore/SynthesizedEnumAccessorMatching.swift`:
`enclosingEnumUSR(forSynthesizedAccessorUSR:)` parses this shape (plain substring search, not a full
length-prefixed parse of the nominal-context prefix like `BridgedExternConstantMatching` -- safe here
because the real safety net is the caller's own `linked.declarations` membership check, not the
string shape alone). Wired into `ExternalIsolationBackfill.collectEdgeLevelWorkItems` as a pre-filter:
when a call-graph edge's callee USR matches this shape *and* the derived enum USR is a real
`linked.declarations` key, it's backfilled to `.nonisolated` directly -- zero live oracle query, never
even queued as a work item.

5 new unit tests (`SynthesizedEnumAccessorMatchingTests.swift`) + 2 end-to-end tests in
`ExternalIsolationBackfillTests.swift` (one asserting `sourceKitD.callCount == 0` on success, one
asserting the fallback stays `.unknown` -- never fabricated -- when the enum isn't actually
project-local).

## 3. Fixed: an empty-body protocol with no same-file extension never got a `DeclarationInfo`

`SyntaxAnalysis.DeclarationExtractor.emitTypeDeclarationIfNeeded` was, before this fix, only ever
called from two places: `enterTypeScope` (class/struct/enum/actor -- protocols deliberately excluded,
since protocol requirements have no enclosing type scope to qualify against) and an
`ExtensionDeclSyntax` visit (only fires when some extension of that type exists somewhere in the
analyzed files). A plain marker/composition protocol with an empty body and *no* same-file extension
-- a common Swift idiom, real code's own

```swift
protocol CellConfigurable: ViewDataConfigurable, UITableViewCell {}
```

(`CellsConfigurable.swift:30`) -- fell through every path that would ever create its own
`DeclarationInfo`. `linked.declarations[CellConfigurableUSR]` was simply absent, even though the
protocol is 100% project-local and its own effective isolation is fully computable from data already
in hand (the exact same mechanism `ViewDataConfigurable` -- which *does* get an entry, via its own
same-file `extension` providing a default `reuseIdentifier` -- already uses successfully).

Consequence: every conforming type's reference to `CellConfigurable` looked like an *external,
oracle-needing* fact (`isGenuinelyResolvedProjectLocalDeclaration` reads
`linked.declarations[usr]?.location`, `nil` for an absent USR), needlessly triggering a declaration-
level oracle work item for something 100% locally resolvable.

### Fix

`Sources/SyntaxAnalysis/DeclarationExtractor.swift`: added
`override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind` to `DeclarationVisitor`,
calling `emitTypeDeclarationIfNeeded` the same way `ExtensionDeclSyntax`'s visit already does --
without pushing a type scope (protocol members keep their existing, deliberate "no enclosing scope"
behavior). `typeIndex[qualifiedName]` was already fully populated for protocols regardless of this fix
(`TypeIndexBuilder`'s own first-pass `visit(_ node: ProtocolDeclSyntax)` already calls
`recordPrimaryDeclaration` for every protocol unconditionally) -- this only adds the missing
second-pass emission that turns that data into a real `DeclarationInfo`.

1 new unit test (`DeclarationExtractorTests.swift`): an empty-body protocol with no extension now
gets its own entry, with a real location and its stated conformances.

**Real corpus effect** (isolated, before the duplicate-file fix in §4 below):
external oracle unknown 2498 → 2457 (-41), unresolved % 67% → 66%.

## 4. Found, not code-fixed: stray Finder-duplicate `* 2.swift` files poison `DeclarationLinker`'s type merge

The `Appearance.black`/`awakeFromNib` edge above was *still* `isUnknown: true` even after §3's fix,
despite `SubscriptionNotifCell` and `CellConfigurable` both now resolving correctly on their own.
Root-caused via targeted debug instrumentation (temporarily added to
`ExternalIsolationBackfill.collectDeclarationLevelWorkItems`/`query`, then reverted) against the real
corpus with `--oracle-workers 1` disabled for stderr visibility
(`SWIFT_ISOLATION_MAP_WORKER_STDERR=1`):

The project's own source tree contained
`Redesign/Account/Modules/Subscriptions/View/Cells/SubscriptionNotifCell 2.swift` -- a stray, stale,
uncompiled duplicate of `SubscriptionNotifCell.swift` (the literal Finder "duplicate file" `" 2"`
naming convention; confirmed by diffing the two files -- the `" 2"` copy is an older draft using a
different, since-replaced styling approach, and `compilerArguments.compilerArguments(forFile:)`
genuinely throws `argumentsNotFound` for it, confirming it's not part of any real build target).

`SyntaxAnalysis`'s `DeclarationVisitor` runs once per file, independently, so *both* files contribute
a `DeclarationInfo` for the type-level `SubscriptionNotifCell` entry (same qualified name).
`DeclarationLinker`'s merge-by-USR step combines the two same-USR entries into one, but the merged
entry's own `location` (used by `collectDeclarationLevelWorkItems`'s fallback-pass conformance-pair
claiming as the query site) ended up pointing at the stray `" 2.swift"` copy -- not because of any
explicit "prefer this file" rule, but because that file happens to sort first
(`"SubscriptionNotifCell 2.swift"` < `"SubscriptionNotifCell.swift"` lexically: a space, `0x20`,
sorts before a period, `0x2E`). The resulting live query for the type's own remaining unresolved
conformance pair (`(SubscriptionNotifCell, syntactic:UIView)`, itself a separate, known, pre-existing
placeholder-USR limitation of the conformance-pair claiming logic -- see `ExternalIsolationBackfill`'s
own top-of-file doc comment on `"syntactic:"` placeholders) always threw `argumentsNotFound`, and
`applyDeclarationLevelOutcomes`'s `.unknown` branch marks *both* the declaration itself *and* every
member whose `containingTypeUSR` matches it -- sweeping in the real, correctly-resolved `awakeFromNib`
along with everything else.

**Not fixed in code this round.** This is a real corpus data-hygiene issue (a stray, uncompiled
duplicate file the user's own project accumulated), not purely a tool defect -- the pragmatic
resolution was deleting the stray files from the corpus, not teaching `DeclarationLinker` to guess
which of two same-named files is "the real one." A full sweep of the corpus
(`find ~/ios -iname "* 2.swift"`) found **22 such files total** (not just this one class) -- all
confirmed to have a same-named sibling without the `" 2"` suffix, 14 with real content divergence
(stale drafts) and 8 byte-identical (pure duplicates). All 22 were removed from the corpus.

Left as a documented, known risk for any future corpus: `DeclarationLinker`'s same-USR merge across
files has no defense against two files legitimately declaring "the same" project-local type where one
of them isn't part of the active build target -- the merged entry's `location` can end up pointing at
whichever file loses no explicit tie-break, and a live query against that location fails unrelated to
the actual isolation question being asked. A future, more defensive fix could prefer a merge candidate
location whose file `compilerArguments` can actually resolve, but that wasn't attempted here.

## 5. Real `Project Iris` corpus, before/after (§2 and §3 together, then §4's data-hygiene cleanup)

| | baseline (post §2/§5/§7/§8) | after §2/§3 (code fixes) | after §4 (22 stray files removed) |
|---|---|---|---|
| Swift source files | 2248 | 2248 | 2226 (**-22**) |
| External oracle unknown | 2498 | 2457 (**-41**) | **2008** (**-490 total, -19.6%**) |
| Cross-isolation edges (denominator) | 4437 | 4437 | 4369 |
| Unresolved % | 67% | 66% | **65%** |

The stray-file cleanup (§4) was by far the largest single contributor (-449 of the combined -490),
confirming the duplicate-file pattern wasn't unique to `SubscriptionNotifCell` -- it was silently
poisoning `isUnknown` for members of most/all of the 22 affected types project-wide.

## 6. Status

- §2 (synthesized `rawValue`/`allCases` accessors) -- **FIXED AND VERIFIED**, 7 new tests.
- §3 (empty-body protocol with no extension) -- **FIXED AND VERIFIED**, 1 new test.
- §4 (stray duplicate files) -- **FOUND AND VERIFIED**, resolved by corpus cleanup (22 files removed
  from Project Iris), not a code change; documented above as a known `DeclarationLinker` merge risk for any
  future corpus exhibiting the same pattern.
