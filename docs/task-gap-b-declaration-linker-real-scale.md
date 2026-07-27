# Task: fix `DeclarationLinker`'s real-scale linking gap (Gap B) — the last blocker for fast `~/ios` runs

**Status: not started. This is a task specification for a dedicated future session, not a
record of completed work.** Gap A (accessor/property USR-granularity mismatch) and a separate,
serious whitespace-path-escaping bug were both found and fixed in the session that produced this
document — see `docs/priority-3-compiled-dependency-isolation.md`'s "Gap A" section and the
`XcodeBuildLogCompilerArgumentsProvider.unescaped(_:)` fix for that history. **Gap B is the one
remaining, now-dominant blocker** to a full `swift-isolation-map` run against a real, large project
(`~/ios`, 2209 files, 46010 declarations) completing in a reasonable time. This document exists to
hand Gap B to a researcher with maximum concrete detail — real numbers, real code, real captured
examples — so it can be root-caused and fixed without re-deriving what's already known.

## 1. The problem, quantified, with the confounds already removed

Two *other* problems that used to make `~/ios` runs slow were fixed this session, specifically so
Gap B's own cost could be measured in isolation, not blamed for someone else's slowness:

1. **Gap A (accessor/property USR mismatch)** — fixed. `IndexStoreQuerying.owningPropertyUSR(forUSR:)`
   now canonicalizes both sides of every call-graph edge in `DeclarationLinker.link(_:)`. Measured
   result: edge-level bulk-cache hit rate went from 4.3% to 39.2%; edge-level live-query-miss volume
   dropped from 18957 to 2301 (an 87.9% reduction).
2. **A whitespace-path-escaping bug** — fixed. `~/ios` has real, legitimate directory names
   containing spaces (`UI/News/News List`, `UI/Side/Side Menu`). Xcode's real `SwiftFileList`
   response files backslash-escape such paths (`News\ List/NewsController.swift`), but
   `XcodeBuildLogCompilerArgumentsProvider.expandFileList` was doing a naive per-line split with no
   unescaping, leaving a literal backslash character in every such path. This made every single
   live `cursorinfo` query's compiler-argument file list *permanently wrong* for any file under a
   space-containing directory — confirmed via real measurement: **238 queries, 30932 total
   `failed to stat file` occurrences, ~130 failed file loads per single query**, before the fix.
   After the fix (`XcodeBuildLogCompilerArgumentsProvider.unescaped(_:)`, mirroring
   `CompilerArgsLogParser.tokenize`'s existing backslash-handling), confirmed via a fresh real run:
   **zero** `failed to stat file` occurrences.

**With both of those fixed, the remaining cost is now cleanly attributable to Gap B alone.**
Observed live-query throughput on the fixed binary, real `~/ios` run: **~13 queries/minute**
(192 queries observed over ~15 minutes of wall-clock time, holding roughly steady). The
declaration-level trigger alone (100% Gap B, see below) has **28134** USRs needing this same live
query, each one *destined to fail* (return `.unknown`) no matter what, since none of them are real
external-dependency references at all. At the observed rate, **running all 28134 of them to
completion would take on the order of 35-40 hours** — this is not a "slow but tolerable" cost, it
is the entire reason a full `~/ios` run cannot complete in any reasonable time today, full stop.
Every other piece of this feature (bulk-cache discovery, Gap A's accessor mapping, the path-escaping
fix) is independently verified correct and fast; **Gap B alone is what's left standing between this
tool and being usable on a real, large codebase.**

## 2. What Gap B actually is, precisely

`SyntaxAnalysis.DeclarationExtractor` (Phase 1, per-file, purely syntactic) represents every
declaration reference — a type's own declaration, its superclass, each protocol it conforms to —
with a placeholder USR of the form `"syntactic:<Name>"` (e.g. `"syntactic:NotificationsListViewInput"`).
`IndexStoreIntegration/DeclarationLinker.swift`'s job (Priority 2/3, cross-file, using real
`IndexStoreDB` data) is to rewrite every one of these placeholders to the real, compiler-assigned
USR IndexStoreDB knows about — via `buildUSRRewriteMap`, which matches a declaration's own
`(file, line, column)` location against real `IndexStoreDB` symbol occurrences at that exact spot.

**A `syntactic:`-prefixed USR that survives this process is a proven, unambiguous "the linker never
resolved this" signal** — it can never accidentally look resolved, since real USRs never contain a
literal colon-prefixed word like this. On a real `~/ios` run this session, **100% of the 28134
declaration-level oracle misses had a `syntactic:`-prefixed unresolved need** — every single one of
them, no exceptions. Real, verbatim captured examples from this session's own diagnostic run
(`declaration.usr` → `needs=` its unresolved superclass/conformance list):

```
s:9Ls_net_ru13EntityProductV10CodingKeysO11tableSizeIDyA2EmF needs=syntactic:CodingKey
c:@M@Ls_net_ru@objc(cs)PersonalGridProductCell needs=syntactic:UICollectionViewCell,syntactic:UICollectionViewDelegateFlowLayout,syntactic:UICollectionViewDelegate,syntactic:UICollectionViewDataSource
s:9Ls_net_ru22LookCollectionViewCellC...configureD0... needs=syntactic:UICollectionViewCell
s:9Ls_net_ru15MainPage2BannerC3urlSSSgvp needs=syntactic:Codable
s:9Ls_net_ru27ReviewsAndFeedbackPresenterC6router...AcA0deF6Router_p... needs=syntactic:ReviewsAndFeedbackModule
syntactic:ImageCompressionServiceImpl.compressionStep#626 needs=syntactic:ImageCompressionService
c:@M@Ls_net_ru@objc(cs)NotificationsListViewController(im)tableView:cellForRowAtIndexPath: needs=syntactic:UITableViewDataSource,syntactic:UITableViewDelegate,syntactic:NotificationsListViewInput
syntactic:OrdersListViewController.needsLoad#8261 needs=syntactic:UITableViewDataSourcePrefetching
s:10Kingfisher0A5ErrorO6domainSSvpZ needs=syntactic:CustomNSError
s:9Alamofire21DataResponsePublisherV needs=syntactic:Publisher
syntactic:ManagerAssemblyImpl.viewController#516 needs=syntactic:ManagerAssembly
s:9Ls_net_ru14AddAddressViewC14setBorderColor...ySo11UITextFieldC_tF needs=syntactic:UITextFieldDelegate
s:10Kingfisher19NetworkObserverImplC5queue...vp needs=syntactic:@unchecked Sendable,syntactic:NetworkObserver
c:@M@Ls_net_ru@objc(cs)NotificationListItemCell(py)label1 needs=syntactic:CellConfigurable
c:@M@Ls_net_ru@objc(cs)NotificationsViewController(im)tableView:numberOfRowsInSection: needs=syntactic:UITableViewDataSource,syntactic:UITableViewDelegate,syntactic:NotificationsViewInput
```

Note the mix: some unresolved needs (`UICollectionViewCell`, `UITableViewDataSource`, `Codable`,
`CustomNSError`, `Publisher`) are genuinely **external** (UIKit/Swift stdlib/Alamofire types) that
the linker was *never going to resolve* by design (see H-external below) — this is not itself a bug,
just a design gap that should route these through the bulk/live oracle correctly instead of paying
its cost pointlessly. Others (`NotificationsListViewInput`, `ManagerAssembly`, `CellConfigurable`,
`ReviewsAndFeedbackModule`, `ImageCompressionService`, `NetworkObserver`) are **this project's own
protocols** — real declarations that exist somewhere in the analyzed file set and *should* link,
but don't. This is the actual bug (H-local below).

### Why external supertypes structurally can never link today (H-external) — confirmed by reading the code, not inferred

`DeclarationLinker.buildUSRRewriteMap` (full source below) builds `usrRewriteMap` by iterating
**this project's own extracted declarations** and, for each one with a known `(file, line, column)`,
looking up the real `IndexStoreDB` symbol at that exact location:

```swift
private func buildUSRRewriteMap(for declarations: [DeclarationInfo]) -> [String: String] {
    let filesToQuery = Set(declarations.compactMap { $0.location?.file })
    var candidatesByLocation: [LocationKey: [IndexedSymbol]] = [:]
    for file in filesToQuery {
        for symbol in indexStore.definedSymbols(inFile: file) {
            candidatesByLocation[LocationKey(location: symbol.location), default: []].append(symbol)
        }
    }

    var usrRewriteMap: [String: String] = [:]
    for declaration in declarations {
        guard let location = declaration.location,
              let candidates = candidatesByLocation[LocationKey(location: location)],
              let match = Self.disambiguate(candidates: candidates, declarationName: declaration.name) else {
            continue
        }
        usrRewriteMap[declaration.usr] = match.usr
    }
    return usrRewriteMap
}
```

The map's **keys** are always some project declaration's own `.usr` (a placeholder like
`"syntactic:Widget"` for the type `Widget` *as declared in this project*). `relink(_:rewritten:...)`
later looks up `conformance.protocolUSR`/`declaration.superclassUSR` in this same map:

```swift
private func relink(_ conformance: ProtocolConformance, rewritten: (String) -> String, ...) -> ProtocolConformance {
    ...
    return ProtocolConformance(protocolUSR: rewritten(conformance.protocolUSR), ...)
}
// where: func rewritten(_ usr: String) -> String { usrRewriteMap[usr] ?? usr }
```

For a reference to an **external** type (`syntactic:UICollectionViewCell` — `UICollectionViewCell`
has no declaration anywhere in this project's own source), `usrRewriteMap["syntactic:UICollectionViewCell"]`
can *never* exist — nothing in the `for declaration in declarations` loop above is ever keyed by
that placeholder, because `UICollectionViewCell` itself was never one of *this project's own*
extracted declarations. `rewritten(...)` falls through its `?? usr` default and the placeholder
survives unchanged, **by construction, at any project scale, forever** — not a bug that gets worse
with size, a permanent structural gap for anything external. `ExternalIsolationBackfill`'s
declaration-level trigger currently tries to resolve these anyway (a live query at the
*conforming/subclassing declaration's own* location, hoping cursorinfo's inherited-isolation
resolution saves it) — which is correct in *intent* but, per Gap A's own established principle,
should never have needed the *slow* path for something this structurally predictable.

### Why project-local supertypes/protocols sometimes fail to link (H-local) — the actual, unexplained bug

For a reference to a project-local protocol (e.g. `syntactic:NotificationsListViewInput`, which
presumably *is* declared somewhere in the analyzed file set as `protocol NotificationsListViewInput
{ ... }`), the *protocol's own* primary declaration should itself appear in `declarations` (the full
list `buildUSRRewriteMap` iterates over) with its own `.usr == "syntactic:NotificationsListViewInput"`
and a real `.location`. If so, `usrRewriteMap["syntactic:NotificationsListViewInput"]` *should* get
populated when the loop reaches that declaration's own entry. **The fact that it doesn't, for a
real, checkable fraction of real project-local protocols on `~/ios`, is the actual open bug.**

Two structurally distinct failure points are possible, and this task's first job is figuring out
which (or both):

1. **The protocol's own declaration never reaches `buildUSRRewriteMap`'s input `declarations` array
   with a resolvable location at all** — e.g. it's declared in a file that, for some reason, isn't
   part of the `extractionResults` fed into `DeclarationLinker.link(_:)` for this run (check
   `SwiftIsolationMap.swift`'s file-enumeration — `StalenessOrchestration.swiftFiles` — for any
   real-scale exclusion/limit), or its `DeclarationInfo.location` came out `nil` from
   `SyntaxAnalysis.DeclarationExtractor` for some syntactic shape not covered by the small existing
   fixtures.
2. **The protocol's own declaration *is* present with a location, but
   `Self.disambiguate(candidates:declarationName:)` fails to find it** — this function (below) is
   the *only* other way a location match can fail to become a rewrite:

```swift
static func disambiguate(candidates: [IndexedSymbol], declarationName: String) -> IndexedSymbol? {
    if candidates.count == 1 { return candidates[0] }
    if let exact = candidates.first(where: { $0.name == declarationName }) { return exact }
    if let prefixMatch = candidates.first(where: { $0.name.hasPrefix("\(declarationName)(") }) { return prefixMatch }
    return nil
}
```

Ranked, cheapest-first suspects for *why* this returns `nil` at real scale but not on the small
existing fixtures (`Tests/Fixtures/cross-file-witness/`, `Tests/Fixtures/simple-actor/`, etc. — all
far smaller, all passing):

- **Path-form mismatches in the `LocationKey` comparison** (`file`/`line`/`column` equality) —
  `~/ios` sits at `/Users/ab/ios`, itself behind no symlink as far as confirmed, but *any* symlink,
  `realpath` normalization difference, or even case-sensitivity quirk between what
  `SyntaxAnalysis.DeclarationExtractor` records as a file's path (from wherever
  `StalenessOrchestration.swiftFiles` enumerated it) versus what `IndexStoreDB.symbolOccurrences
  (inFilePath:)` returns for the *same* file, would silently make every candidate at that location
  invisible to `candidatesByLocation`'s lookup — a `LocationKey` that never matches produces exactly
  this symptom (falls through to the `guard let candidates = ... else { continue }` in
  `buildUSRRewriteMap`, which looks identical from the outside to `disambiguate` itself failing).
  **Check this first** — cheapest to verify (log both path strings for one real, reproducible failing
  case and diff them byte-for-byte).
- **`candidatesByLocation` built from `definedSymbols(inFile:)`, which only keeps `.definition`-role
  occurrences** (`IndexStoreClient.definedSymbols`) — if a large/complex file's protocol declaration
  is, for some real-scale-only reason, reported by `IndexStoreDB` with a *different* role at that
  exact position (unlikely, but the existing small fixtures never had reason to test this), the
  location would never make it into `candidatesByLocation` in the first place.
  reason
- **A genuine multiple-candidate collision `disambiguate` can't resolve** — e.g. a protocol
  requirement/witness name collision at the *same* (line, column) as the protocol's own primary
  declaration for some real syntactic shape the existing fixtures don't exercise (the existing
  fixtures already found and handled one such collision class — property/getter/setter sharing a
  location, and protocol-requirement-vs-witness name collisions disambiguated by containing type in
  `DeclarationLinkerTests.swift` — there may be a *third*, real-scale-only shape not yet seen).

**Trace exactly one real case end-to-end before guessing further** — pick
`NotificationsListViewInput` (a real, findable protocol somewhere in `~/ios`'s own source) and walk
it through `buildUSRRewriteMap` step by step (a temporary debug print of
`candidatesByLocation[LocationKey(location: theProtocolDeclaration.location!)]` right where the
lookup happens would show immediately whether the map has *zero* candidates at that location, or
some candidates that `disambiguate` then rejects) — this project's own established discipline
throughout every phase of this feature has been "verify the real, specific failure, don't guess a
general fix," and this is exactly that kind of case.

## 2.5 A follow-up research response's claims, independently verified against real source/code before trusting them

A researcher response to an earlier draft of this document (four claims, each checked against this
project's own real source or a real project file, not accepted on authority — matching this
project's standing discipline):

**Verified real: `occurrences(relatedToUSR:roles:)` + `.baseOf`.** Confirmed directly in the
checked-out `swiftlang/indexstore-db` source (`Sources/IndexStoreDB/IndexStoreDB.swift`,
`Sources/IndexStoreDB/SymbolRole.swift`): `public func occurrences(relatedToUSR usr: String, roles:
SymbolRole) -> [SymbolOccurrence]` and `SymbolRole.baseOf` both really exist, mirroring exactly the
`.accessorOf`/`occurrences(ofUSR:roles:)` pattern Gap A's own fix already established and trusts.
**This changes the fix shape for both halves of Gap B**: instead of relying on
`buildUSRRewriteMap`'s location-based matching for inheritance-clause needs at all, a declaration
whose own USR is already real (which the captured corpus shows is the common case — the left column
above is overwhelmingly real USRs already) can ask the index directly, once, "what does this
declaration's own inheritance clause point at" — `occurrences(relatedToUSR: declUSR, roles: .baseOf)`
— and get back the real, compiler-assigned USR for every supertype/conformed protocol, external or
project-local alike, with no location arithmetic and no name-based guessing. **As with `.accessorOf`,
the exact *direction* of this relation (does it live on the occurrence of the base type, pointing at
the derived type, or the reverse?) is not settled by the wrapper source alone — verify empirically,
the same way Gap A's direction was verified, before writing code that assumes a direction.**

**Verified real, but does not explain the specific traced `NotificationsListViewInput` case**:
`SyntaxAnalysis/DeclarationExtractor.swift`'s `SyntacticIdentity` enum (confirmed by reading it
directly) has **two different placeholder-construction schemes** — `typeUSR(_ path: [String])`
(`"syntactic:\(path.joined(separator: "."))"`, used for a *declaration's own* USR, e.g. line
`usr: SyntacticIdentity.typeUSR(qualifiedName.components(separatedBy: "."))`) versus `typeUSR(named:)`
(`"syntactic:\(name)"`, bare, used for every inheritance-clause *reference*: `superclassUSR`,
`protocolUSR`, `containingTypeUSR`). For a **nested** declaration (e.g. a protocol declared inside a
namespace `enum`, a common VIPER shape), its own key is qualified (`"syntactic:SomeModule.Foo"`)
while a same-module reference using the short name (`: Foo`) produces the bare, unqualified
placeholder (`"syntactic:Foo"`) — two different dictionary keys for the same real declaration, a
confirmed, reproducible bug class for *nested* project-local supertypes/protocols. **However**:
checked the real source for the specific traced example (`grep -rn "protocol
NotificationsListViewInput" ~/ios`) — it is declared at the **top level**
(`lsboutique/Redesign/Account/Modules/NotificationsList/View/NotificationsListViewController.swift`),
not nested, so for *this specific* protocol `qualifiedName` and the bare name are identical strings
and this mismatch cannot be what's failing for it. The nesting bug is real and worth fixing
regardless (it will affect *some* real project-local protocols, just not this particular traced
one) — but the single-case end-to-end trace this document's DoD #2 calls for is still required to
find out what actually fails for `NotificationsListViewInput` specifically; don't stop at the nesting
explanation and assume it's the whole story.

**Verified real: the malformed `syntactic:@unchecked Sendable` placeholder.**
`DeclarationExtractor.applyInheritance` (confirmed by reading it directly) builds each
inheritance-clause entry's name via `inheritance.inheritedTypes.map { $0.type.trimmedDescription }`
— `.trimmedDescription` on a SwiftSyntax `TypeSyntax` renders the *entire* written type expression,
attributes included, so a real source conformance clause entry like `@unchecked Sendable` (valid
Swift, an attributed type in an inheritance clause) produces the literal, unparseable placeholder
name `"@unchecked Sendable"` verbatim. A two-line fix (strip a leading `@attribute` token, or unwrap
`AttributedTypeSyntax` to its base type before taking `.trimmedDescription`) makes this placeholder
at least well-formed enough to be recognized and skipped cheaply, rather than always falling through
to a doomed live query.

**Verified real: the 28134 count is inflated by per-member duplication of the same unresolved
need.** `DeclarationExtractor`'s per-member declaration builder (confirmed by reading it directly)
attaches `conformances: currentBodyConformedProtocolNames.map { ... }` to **every member's own**
`DeclarationInfo` — meaning a type with, say, 20 methods and 3 unresolved protocol conformances
produces 20 separate `DeclarationInfo` entries each carrying its *own copy* of the *same* 3
unresolved `ProtocolConformance` values. `ExternalIsolationBackfill.resolveDeclarationLevelTriggers`
iterates every declaration independently, so the *same* (type, unresolved-protocol) pair gets
re-examined (and, before any fix, re-queried against the live oracle) once per member — this is
exactly why real corpus examples show the unresolved need attached to *method*-level declarations
(`NotificationsListViewController(im)tableView:cellForRowAtIndexPath:
needs=syntactic:...NotificationsListViewInput`) rather than only the type itself. **The true number
of distinct (nominal type, unresolved need) pairs is very likely far below 28134** — plausibly by an
order of magnitude on a VIPER-style codebase with many small methods per type. Deduplicating by that
pair before attempting any resolution (index query or live oracle) is a small, high-leverage change
independent of everything else in this document, and DoD #3's metric should be reframed around
distinct pairs, not raw trigger counts, once this is understood.

**A related, pre-existing, deliberate scope decision worth revisiting explicitly**: confirmed
(`Sources/swift-isolation-map/StalenessOrchestration.swift`'s own doc comment, predating this
session) that `Pods`/`Carthage` directories are **deliberately not excluded** from file enumeration
— "third-party dependency source genuinely can affect real compiled behavior and this is a
safe-by-default (over-inclusive) design." This means `~/ios`'s 46010 declarations and some fraction
of the unresolved-need corpus (`s:10Kingfisher...`, `s:9Alamofire...` declaration USRs are visibly
present in the real captured examples above) come from analyzing **CocoaPods' own source checkouts
as if they were this project's code** — a real, user-facing scope question (analyze vendored
dependency sources: yes/no/flag?), not a bug, and not this task's call to make unilaterally. Worth
deciding explicitly and re-running the diagnostic both ways to quantify the difference before
finalizing Gap B's fix.

## 3. Definition of done

1. **H-external addressed, via the verified `.baseOf` relation query, not clause-location capture**:
   for any declaration whose own USR is already real, one `occurrences(relatedToUSR: declUSR, roles:
   .baseOf)` call (direction verified empirically first, exactly as Gap A's `.accessorOf` direction
   was) returns the real, compiler-assigned USR of every supertype/conformed protocol its
   inheritance clause references — external and project-local alike, no `SyntaxAnalysis` changes,
   no name-based pre-check, no "hover and hope" indirection. Resolved external USRs then route
   through the existing bulk-first oracle machinery unchanged. This satisfies H-external without
   touching `DeclarationExtractor` at all — simpler than this document's original plan.
2. **H-local's symptom resolved by the same query** (a project-local protocol's real USR comes back
   from the index directly, decoupled from whatever placeholder/location mechanics failed) — but
   **root-cause and fix `buildUSRRewriteMap`/`disambiguate`'s own failure too**, not just paper over
   it with the relation query: trace the specific `NotificationsListViewInput` failure end-to-end
   (confirmed *not* explained by the nesting-placeholder mismatch below — that's a real, separate bug
   affecting other cases) and fix whatever it reveals. Knowing the true cause matters for every other
   consumer of placeholder-USR identity, not just this one number.
3. **Two additional, independently-verified real bugs fixed alongside the above** (both confirmed by
   reading the code directly, not hypothetical):
   - The nested-declaration placeholder mismatch (`typeUSR(path:)` qualified vs. `typeUSR(named:)`
     bare — `SyntaxAnalysis/DeclarationExtractor.swift`'s `SyntacticIdentity`) — affects any
     project-local protocol/superclass declared nested inside another type/namespace.
   - The malformed attribute-carrying placeholder (`"syntactic:@unchecked Sendable"` from
     `applyInheritance`'s `.trimmedDescription` capturing attributes verbatim) — strip
     attribute/modifier prefixes before forming a clause placeholder.
4. **Per-member conformance duplication deduplicated**: the same (nominal type, unresolved need)
   pair currently gets attempted once per member (confirmed: `DeclarationExtractor` attaches a full
   copy of the type's conformances to every member's own `DeclarationInfo`) — resolve/query by
   distinct pair, not per-declaration, before any oracle involvement. Reframes DoD #5's metric
   around distinct pairs.
5. **The Pods-in-scope question decided and documented explicitly** (`StalenessOrchestration
   .swiftFiles`'s existing, pre-session, deliberate "don't skip Pods/Carthage" choice) — a real
   scope decision affecting both the 46010 declaration count and some fraction of the unresolved-need
   corpus (`Kingfisher`/`Alamofire` declaration USRs are visibly present in it); not this task's call
   to make unilaterally, but must be made and recorded, with the diagnostic re-run both ways to
   quantify the difference.
6. **Real, measured result**: re-run the same diagnostic-instrumentation technique used to find Gap
   A and this document's own numbers (temporarily re-add hit/miss logging + short-circuit at
   `ExternalIsolationBackfill`'s two trigger loops, gated by `SWIFT_ISOLATION_MAP_DEBUG_ORACLE`,
   revert after use) against `~/ios` — the `syntactic:`-prefixed miss fraction of declaration-level
   misses should drop from 100% to near zero, and (per item 4) report the *distinct-pair* residue,
   not the raw trigger count, as the primary metric.
7. **A real, complete, non-diagnostic-shortcut `~/ios` run finishes in a reasonable time** — this is
   the actual, final acceptance bar the whole compiled-dependency-isolation effort has been chasing
   across three sequential task documents now. Report the real wall-clock number, honestly, whatever
   it turns out to be.
8. Full `swift test -c release` suite green throughout (207 tests as of this writing).
9. A decision record in this project's `docs/priority-3-*.md` convention with the real before/after
   numbers.

## 4. Relevant existing architecture

- `Sources/IndexStoreIntegration/DeclarationLinker.swift` — the entire bug lives here;
  `buildUSRRewriteMap`, `disambiguate`, `relink` (all quoted above) are the exact functions to
  trace.
- `Sources/IndexStoreIntegration/IndexStoreClient.swift` — `definedSymbols(inFile:)` (only
  `.definition`-role occurrences, a possible H-local suspect), `owningPropertyUSR(forUSR:)` (Gap
  A's own fix, already correct, for context on the established `db.occurrences(ofUSR:roles:)`
  query pattern any new lookup should mirror).
- `Sources/swift-isolation-map/ExternalIsolationBackfill.swift` — `resolveDeclarationLevelTriggers`,
  where every `syntactic:`-prefixed miss currently pays the full live-query cost before landing in
  `unknown`; the same file's `resolveEdgeLevelTriggers` shows the established short-circuit
  diagnostic shape (env-var-gated, logs hit/miss, reverted after use) to reuse for this task's own
  before/after measurement.
- `Sources/SyntaxAnalysis/DeclarationExtractor.swift` — where `syntactic:` placeholders originate.
  `SyntacticIdentity.typeUSR(_:)` vs. `typeUSR(named:)` (the nesting-mismatch bug),
  `applyInheritance`'s `$0.type.trimmedDescription` (the malformed-attribute-placeholder bug), and
  the per-member declaration builder's `conformances: currentBodyConformedProtocolNames.map { ... }`
  (the per-member duplication inflating the 28134 count) are all here, all confirmed by direct
  reading this session.
- `Sources/IsolationCore/DeclarationInfo.swift` — `ProtocolConformance`'s shape, if item 4's
  deduplication needs a stable identity for "(nominal type, unresolved need) pair" beyond what's
  already there.
- `Tests/IndexStoreIntegrationTests/DeclarationLinkerUnitTests.swift` /
  `DeclarationLinkerTests.swift` — existing coverage, all passing, none of which reproduces the
  real-scale failure; the golden-fixture test's own doc comment already documents the
  property/getter/setter location-collision precedent worth reading before assuming a new collision
  shape.
- `docs/task-compiled-dependency-isolation-usr-granularity.md` — Gap A's now-closed sibling task;
  read for the H-external/H-local naming convention this document continues, and for the general
  "verify against real source/data before trusting a hypothesis" discipline established there.

## 5. Explicitly out of scope

- Re-touching Gap A (`owningPropertyUSR`, the `DeclarationLinker` accessor-canonicalization) — done,
  correct, measured.
- Re-touching the whitespace-path-escaping fix (`XcodeBuildLogCompilerArgumentsProvider
  .unescaped(_:)`) — done, correct, measured (zero `failed to stat file` occurrences post-fix).
- Any change to `IsolationInferenceEngine`, the risk heuristic, or the report schema.
- The bulk-cache/module-discovery machinery (`BulkSymbolGraphExtractor`,
  `BulkExtractionEnvironmentProviding`, `FrameworkModuleDiscovery`) — all correct and tested;
  H-external's fix should *route through* this existing machinery, never duplicate or bypass it.

## 6. Closure — Gap B closed (Phases I1-I5, `docs/task-gap-b-implementation-plan.md`)

All nine Definition-of-Done items addressed:

1-3. Closed via `IndexStoreClient.baseTypeUSRs(forUSR:)` (the verified `.baseOf`-relation query,
   including the extension-declared-conformance extra hop found during implementation) plus
   `DeclarationExtractor`'s widened placeholder normalization (4 shapes, not just the attribute
   case) plus the nesting-mismatch fallback in `DeclarationLinker`'s shared `rewritten(_:)`.
4. Closed via `ExternalIsolationBackfill`'s per-(nominal, protocol)-pair cache-and-apply dedup.
5. Decided: left as-is (Pods/Carthage stay in scope), written up as its own separate, non-blocking
   research note per explicit user instruction — `docs/task-pods-in-scope-research.md`.
6. **Real, measured**: declaration-level triggers 28134 (100% `syntactic:`) → **3388 raw triggers /
   3262 distinct pairs (88% fewer triggers), 802/3388 ≈ 23.7% still `syntactic:`-prefixed** — the
   residue fully explained by Phase I4's finding (protocols never get their own `DeclarationInfo`,
   so the "already known locally" short-circuit can't apply to them even once their USR resolves
   correctly).
7. Real, complete run result: see `docs/priority-3-compiled-dependency-isolation.md`'s Gap B
   section for the honest wall-clock number.
8. `swift test -c release`: 220/220 passing throughout.
9. Decision record: `docs/priority-3-compiled-dependency-isolation.md`.

Bonus finding, not in the original DoD: Phase I4's trace surfaced a third, deeper failure mode
(protocols never extracted as their own `DeclarationInfo`) that none of the prior research/review
passes anticipated — found only by tracing the real, specific case end-to-end against a real index
store, per this project's own standing discipline.
