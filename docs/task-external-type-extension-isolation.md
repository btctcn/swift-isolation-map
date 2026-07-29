# Research task: extensions of an *external* MainActor type falsely report high-risk boundaries

**Status: CLOSED this session.** Implemented, tested (230/230 `swift test -c release`), and
measured against the real `Project Iris` corpus -- see section 4's Definition of Done for the real
before/after numbers, and `docs/priority-3-compiled-dependency-isolation.md`'s own decision-record
section for the full write-up. The real impact turned out **larger** than this task's own
pre-registered baseline: the fix resolves the false positives it was written for *and* un-masks a
large number of genuine, previously-invisible false negatives on the callee side of the same root
cause -- reported honestly below, not just the number that was predicted.

Found as a side observation while
spot-checking Gap B's real `Project Iris` result (`docs/priority-3-compiled-dependency-isolation.md`'s
Gap B section), not something Gap B itself set out to fix -- Gap B is about resolving
*inheritance-clause references* (a declaration's own `superclassUSR`/`conformances[].protocolUSR`).
This is a different, adjacent gap: **a project-local `extension` of an *external* type never learns
that external type's own isolation**, even when that external type is unambiguously `@MainActor` in
the real SDK. The result: every member of such an extension is classified `.nonisolated`, and any
call from it into genuinely `@MainActor`-isolated project code is reported as a **high-risk
cross-actor boundary that isn't real** -- the call is not actually risky (the extension's own
methods only ever run wherever the external type's real instances run, i.e. the main actor), the
tool just has no way to know that today.

## 1. The real, motivating example

`Project Iris/Extensions/UIViewController+Navigation.swift`:

```swift
import UIKit

extension UIViewController {
    func setCartCount(count: Int = 0) {
        if let cartButton = navigationItem.rightBarButtonItems?.first as? CartBadgeButton {
            cartButton.count = count
        } else if let cartButton = navigationItem.rightBarButtonItem as? CartBadgeButton {
            cartButton.count = count
        }
        if let cartTab = tabBarController as? ApplicationViewController {
            cartTab.updateCartCounter(count)
        }
    }
    // ...
}
```

A real, complete `Project Iris` analysis run (post-Gap-B, `docs/priority-3-compiled-dependency-isolation.md`)
flags 5 confirmed high-risk edges in this one file, all the same shape, e.g.:

```json
{
  "callerUSR": "s:So16UIViewControllerC9Ls_net_ruE12setCartCount5countySi_tF",
  "callerIsolation": "nonisolated",
  "calleeUSR": "s:9Ls_net_ru25ApplicationViewControllerC17updateCartCounteryySiF",
  "calleeIsolation": "globalActor(MainActor)",
  "risk": "high",
  "explanation": "nonisolated code reaches globalActor(MainActor)-isolated state -- no static isolation check protects this boundary"
}
```

`ApplicationViewController` (`class ApplicationViewController: UITabBarController, ...`) and
`CartBadgeButton` (`class CartBadgeButton: UIBarButtonItem`) correctly resolve to
`globalActor(MainActor)` -- neither has an explicit `@MainActor` attribute of its own; both get it
purely by inheriting from a real `@MainActor` UIKit base class, which is exactly Gap B's own
`.baseOf`-relation fix working correctly. The **caller** side is the problem: `setCartCount` is
declared inside `extension UIViewController { ... }`, and `UIViewController` itself is every bit as
much a real, unambiguous `@MainActor` UIKit type as `UITabBarController`/`UIBarButtonItem` are --
but the tool has no mechanism today that lets an extension member learn the isolation of the
*external* type it extends, so it falls through to `.nonisolated` by default. Since a `nonisolated`
caller reaching a `globalActor` callee is exactly the risk heuristic's own definition of "high risk"
(`docs/isolation-rules.md`), this produces a confirmed-high-risk finding for a boundary that isn't
actually risky at all -- the caller is not really `nonisolated`, the tool just can't prove otherwise.

## 2. The confirmed mechanism (traced end-to-end, not guessed)

Three real code paths, read directly this session, produce this result together:

1. **`Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `ExtensionDeclSyntax` handling** (two
   places: `TypeIndexBuilder`'s pass at line ~274, `DeclarationVisitor`'s pass at line ~513): for
   `extension UIViewController { ... }`, `extendedName = node.extendedType.trimmedDescription` =
   `"UIViewController"`. `emitTypeDeclarationIfNeeded(qualifiedName: "UIViewController")` (called
   from the `DeclarationVisitor` pass) emits a `DeclarationInfo` for `"UIViewController"` itself --
   but its `location` is `nil` (only ever set by `recordPrimaryDeclaration`, which never runs for an
   extension -- there is no primary declaration of `UIViewController` in this project to record),
   `isActor` is `false`, and (since this specific extension has no inheritance clause of its own)
   `conformedProtocolNames`/`superclassCandidateName` are both empty. Every member inside the
   extension gets `containingTypeUSR: SyntacticIdentity.typeUSR(named: "UIViewController")` =
   `"syntactic:UIViewController"` (a bare-name placeholder, same scheme as any inheritance-clause
   reference).
2. **`Sources/IndexStoreIntegration/DeclarationLinker.swift`'s `buildUSRRewriteMap`**: only matches
   a placeholder against a real indexed symbol when the placeholder's own `DeclarationInfo.location`
   is non-nil (`guard let location = declaration.location, ...`). Since `"UIViewController"`'s
   placeholder entry has `location == nil` (confirmed above), it's skipped entirely -- it's never
   rewritten to `UIViewController`'s real, compiler-mangled USR. It survives, unresolved, as a real
   entry in the final `linked.declarations` dictionary, keyed literally by the string
   `"syntactic:UIViewController"` (rewritten() leaves it unchanged since nothing in
   `usrRewriteMap` -- not even Gap B's own nesting-mismatch fallback, which only matches a *bare*
   reference against a *qualified* declaration key, and `"UIViewController"` has no qualified
   variant anywhere in this project -- ever produces a match for it).
3. **`Sources/IsolationCore/IsolationInferenceEngine.swift`'s `resolveInheritedIsolation`** (lines
   75-92): for `setCartCount` (a member with `containingTypeUSR = "syntactic:UIViewController"`),
   `let containingType = declarations[containingUSR]` **succeeds** -- it finds the placeholder
   entry from step 1, which really does exist as a dictionary entry, just an empty,
   uninformative one. Recursively resolving *that* placeholder's own isolation: no explicit
   attribute, no superclass, no conformances, not eligible-or-not for the module default in a way
   that matters here (this project's own rule set, confirmed via `--verbose`, is `Swift5RuleSet` --
   SE-0466's module-default-isolation feature is Swift 6 opt-in and not active here) -- resolves to
   plain `.nonisolated`. Back in the caller: `.nonisolated` is neither `.actor` nor `.globalActor`,
   so neither propagation branch fires, `resolveInheritedIsolation` returns `nil`, and
   `setCartCount` itself falls through to `resolveDefaultIsolation` -- also `.nonisolated` (same
   reason: no module default configured). This is the exact, confirmed path from "extension of an
   external type" to "member reported nonisolated."

**Important, verified scope note**: this can only ever produce a **false positive** (a boundary
reported riskier than reality), never mask a real one. `.nonisolated` is already the "assume worst
case, no static protection" state the risk heuristic checks a `globalActor` callee against; there is
no way this bug could make a genuinely risky boundary look safe instead.

**A second, related scope note**: the *exact same* mechanism affects not just genuinely-external
(SDK/Pods) types, but also any project-local type whose *primary* declaration simply isn't among
the files included in a given analysis run -- `DeclarationLinker.swift`'s own header comment already
documents this as a known limitation ("when a type has no primary declaration among the files being
linked... its type-level placeholder USR is never resolved"). A fix for the general "extension of a
type this linking pass can't see the primary declaration of" case would likely close both at once.

## 3. Fix shape -- variant 1a, empirically verified this session (superseding the original hypothesis 1)

An external review (`/Users/ab/Downloads/external-extension-isolation-research-response.md`,
studied and independently re-verified, not accepted on authority) caught a real internal
contradiction in this task's original hypothesis 1: it proposed resolving the extension's own
`extendedType` token via a *location-based* reference lookup, but the extension's location is
recorded **nowhere** in `DeclarationInfo` (confirmed in section 2 above) -- capturing it would
require a `SyntaxAnalysis` change, directly contradicting this task's own DoD 2 ("without needing
`SyntaxAnalysis` to change at all"). The review's alternative, **variant 1a**, resolves the same
fact via index *relations* instead of a location, starting from a **member's own already-real
USR** (confirmed real in this task's own captured example --
`s:So16UIViewControllerC9Ls_net_ruE12setCartCount…`) rather than from the extension's placeholder
name or position:

1. `occurrences(ofUSR: memberUSR, roles: .definition)` -> the definition occurrence's own
   `.relations` carries a `.childOf` entry pointing at the **extension's own synthetic USR** (the
   same `s:e:...`-prefixed shape Gap B's Phase I2 already found and handled for the `.baseOf`
   relation), not directly at the extended type.
2. `occurrences(relatedToUSR: extensionUSR, roles: .extendedBy)` -> the returned occurrence's own
   `symbol.usr` **is** the extended type's real, compiler-assigned USR.

**Both hops independently re-verified empirically this session, on two separate real index
stores, not trusted from the response alone:**

- **On the existing `cross-file-witness` fixture** (`extension SyncCoordinator: Refreshable { func
  refresh() {} }`): `refresh()`'s own `.definition` occurrence's `.childOf` relation points to
  `s:e:s:16CrossFileWitness15SyncCoordinatorC7refreshyyF` (the extension's synthetic USR, its own
  reported *name* is `"SyncCoordinator"`). `occurrences(relatedToUSR:` that synthetic USR
  `, roles: .extendedBy)` returns `s:16CrossFileWitness15SyncCoordinatorC` named `"SyncCoordinator"`
  -- `SyncCoordinator`'s own real, direct USR. Confirms V1 and V2 exactly as the response predicted
  (the reverse query, `occurrences(ofUSR: extensionUSR, roles: .extendedBy)`, returned nothing --
  `relatedToUSR` is the correct direction, matching Gap B's own established `.extendedBy` usage).
- **On the real, motivating `Project Iris` case itself**: `setCartCount(count:)`'s own `.definition`
  occurrence's `.childOf` relation points to
  `s:e:s:So16UIViewControllerC9Ls_net_ruE19addCustomBackButton4nameySS_tF` (the extension's own
  synthetic USR, built from the extension's *first* member, `addCustomBackButton` -- not
  `setCartCount` itself, consistent with the per-extension synthetic-USR scheme already observed
  in Gap B). `occurrences(relatedToUSR:` that synthetic USR `, roles: .extendedBy)` returns
  **`c:objc(cs)UIViewController`** -- the real clang/ObjC USR, exactly the shape
  `BulkSymbolGraphExtractor`'s UIKit bulk-cache entries are keyed by (confirming the response's V3:
  do **not** try to derive this by parsing the Swift-mangled member USR string -- the real answer
  is the clang spelling, not a Swift-mangled guess, and only the relation query gets that right).

**Fix shape, following the verified chain (supersedes the original hypothesis 1/2/3 above, which
are retained for the design-tension record but should not be implemented as originally written)**:
add `IndexStoreQuerying.extendedTypeUSR(forMemberUSR:) -> String?` (or equivalent), implemented as
the two-hop chain above, entirely index-relation-based -- zero `SyntaxAnalysis` changes, satisfying
DoD 2 as written.

**Resolution must be per-extension, not per-bare-name** (the review's own §2, worth keeping
verbatim): the placeholder `"syntactic:UIViewController"` today is a *single* shared dictionary
entry every extension of anything named `UIViewController` anywhere in the project points at.
Variant 1a naturally produces a **per-member** (hence per-extension) answer instead, since it
starts from each member's own real USR rather than the shared bare-name placeholder. On the rare
case of two same-named types from different modules both extended in-project, this per-member
resolution correctly keeps them distinct; do not collapse back to one shared bare-name answer,
which would silently reintroduce exactly the collision-blindness this approach otherwise avoids.
Same never-guess floor as `DeclarationLinker.disambiguate` on any genuine ambiguity.

**Amendment (a second review pass, `/Users/ab/Downloads/external-extension-task-amendments.md`,
verified logically against the already-confirmed V1/V2 facts above, no new index-store check
needed): the per-extension property above is only real if the grouping step is specified --
the one wrong, convenient answer (grouping members by the shared bare-name placeholder) silently
reintroduces exactly the collision this section forbids.** The original phrasing -- "resolve...
via any one such member, then rewrite `containingTypeUSR` on every member of that extension" --
left "that extension" undefined operationally. The specified, correct shape:

1. **Hop 1 runs per member.** Each member's own `.definition` occurrence's `.childOf` relation
   yields *that member's own* extension's synthetic USR -- a fast, in-memory index lookup, one per
   member.
2. **Hop 2 is memoized per distinct extension USR**, not per member:
   `occurrences(relatedToUSR: extensionUSR, roles: .extendedBy)` runs once per distinct answer hop
   1 produced, mirroring the memoization pattern Gap B's own `baseTypeUSRs`-consuming pass already
   established (query once per distinct nominal, not once per declaration).
3. **Grouping falls out of hop 1 for free**: "the members of this extension" are exactly the
   members whose hop-1 answer is the same extension USR -- no placeholder-based grouping needs to
   exist anywhere in this pass. Two same-named types extended in-project simply produce two
   different extension USRs from hop 1 and two independent hop-2 answers; the divergence-safety
   this section already required falls out of the algorithm shape, not a separate check.

Cost is unchanged (hop 1 is free; hop 2 is one query per distinct extension, not per member).

**A sibling concern raised by the same review, checked and found *not* to apply -- already
correct, no action needed**: whether an extension's *own* `@MainActor`/`nonisolated` attribute
(SE-0316's second propagation rule, distinct from this task's "what does the extension's *extended
type* contribute" question) actually propagates to its members today. Verified directly by reading
`Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `ExtensionDeclSyntax` handling (~line 513-537):
it already reads `node.modifiers` for `nonisolated` and `node.attributes` for a recognized global-
actor attribute, pushes the result onto `enclosingExtensionIsolationStack`, and every member's
`enclosingExtensionIsolation` field is populated from it -- and
`IsolationInferenceEngine.resolveIsolation` already checks `enclosingExtensionIsolation` *before*
containing-type propagation. Both polarities already have dedicated, passing tests
(`DeclarationExtractorTests.swift`: `"A global actor attribute on an extension sets
enclosingExtensionIsolation on its members, not the primary type"`, `"A nonisolated extension sets
enclosingExtensionIsolation to nonisolated on its members"`). No regression, no fix needed here --
recorded so a future session doesn't re-raise the same, already-answered question.

## 4. Definition of done

1. **Done.** Variant 1a's two-hop chain (`.childOf` -> extension USR -> `.extendedBy` ->
   extended-type USR) confirmed empirically against two real index stores (`cross-file-witness`,
   the real `Project Iris` case) *before* any production code was written (section 3 above). A committed
   fixture addition (`Tests/Fixtures/cross-file-witness/Sources/CrossFileWitness/
   ExtensionOfExternalType.swift`) covers all of V1-V4 for real, including the two new shapes this
   task's own review demanded: a real `AppKit` `NSView` extension (external, `@MainActor`), a
   nested extended type (`NestedContainer.Inner`), and a generic extended type
   (`GenericContainer`) -- all three confirmed live, via `DeclarationLinkerTests.swift`'s
   `extensionChainResolvesExternalNestedAndGenericExtendedTypes`. The end-to-end keying-consistency
   seam (backfilled entry keyed by the *same* real USR `containingTypeUSR` was rewritten to) is
   covered by a real, live test combining a real `AppKit` bulk extraction with the unmodified
   engine (`ExternalIsolationBackfillTests.swift`'s `extensionOfExternalTypeResolvesEndToEndWithRealAppKit`).
2. **Done.** An extension member whose extended type is external (or otherwise has no primary
   declaration in the linked file set) and is a known `@MainActor` (or other global actor) type
   correctly propagates that isolation -- zero `SyntaxAnalysis` changes, confirmed by the diff
   (`Sources/IndexStoreIntegration/IndexStoreClient.swift`,
   `Sources/IndexStoreIntegration/DeclarationLinker.swift`,
   `Sources/swift-isolation-map/ExternalIsolationBackfill.swift` -- nothing under `SyntaxAnalysis/`
   touched). `IsolationInferenceEngine` itself needed zero changes, confirmed by tracing it
   directly, not assumed.
3. **Done, exceeded.** The real `Project Iris` `UIViewController+Navigation.swift` case (5 findings)
   re-resolved to `globalActor(MainActor)` for the caller side and dropped out of
   `highRiskBoundaries` -- confirmed by name, in the real before/after diff, not just in the
   abstract (see item 4).
4. **Done -- real, measured, and larger than the pre-registered baseline predicted, reported
   honestly.** The pre-registered baseline (measured before any fix, from the already-captured real
   run's JSON) was **20 of 129** confirmed high-risk boundaries matching the caller-side
   false-positive shape. The real after-run diff of confirmed high-risk edges:
   - **22 resolved (removed)**: the pre-registered 20 by name (`UIViewController+Navigation.swift`'s
     5, `UICollectionViewLayoutAttributes`/`WKWebViewConfiguration`/`UITabBarController`/
     `MKMapView` extensions), plus 2 more the diff caught that the regex-based pre-measure didn't
     (an `AppDelegate` extension method in the test target; a Pods-internal `Mindbox` case) --
     confirming this fix's own scope note that it also closes the general "no primary declaration
     among linked files" case, not only the genuinely-external one.
   - **156 newly appeared, traced, not just counted**: 144 of 156 (92%, effectively all once an
     ObjC-category USR shape the diagnostic regex missed is accounted for) are the identical root
     cause, the *callee* side instead of the caller side -- a call into a project-local extension
     method of `UINavigationController`/`UIApplication`/`UIViewController`/etc.
     (`pushViewController(_:animated:)`, `topViewController(base:)`, etc.) previously reported that
     *callee* as `.nonisolated` too, so a real `nonisolated`-into-`globalActor` boundary was never
     flagged at all -- a false negative, unmasked as a direct, correct consequence of fixing the
     same mechanism on both sides of every call.
   - **Net: 129 -> 253 confirmed high-risk boundaries** (unique caller/callee pairs). A real,
     substantial, and correct increase -- every sampled case traced to a genuinely-wrong prior
     `.nonisolated` classification on a real UIKit/AppKit-derived type, not a new bug.
5. **Done.** `Tests/IndexStoreIntegrationTests/DeclarationLinkerUnitTests.swift` (5 fake-based unit
   tests: chain resolution, hop-2 memoization, per-extension-not-per-bare-name, both residual-
   limitation misses), `Tests/IndexStoreIntegrationTests/DeclarationLinkerTests.swift` (2 real
   golden-fixture tests), `Tests/swift-isolation-mapTests/ExternalIsolationBackfillTests.swift` (1
   fake-based unit test for the new containing-type need, 1 real end-to-end test with real AppKit).
6. **Done.** Full `swift test -c release`: 230/230 (220 pre-fix + 10 new).
7. **Done.** Decision record in `docs/priority-3-compiled-dependency-isolation.md`'s "Extension-of-
   an-external-type fix" section, including the residual limitation (an extension none of whose
   members ever resolved to a real USR has no hop-1 entry point -- left exactly as before, never
   worse, not separately re-measured this session -- expected near-zero post-Gap-B).

## 5. Relevant existing architecture

- `Sources/SyntaxAnalysis/DeclarationExtractor.swift` -- `ExtensionDeclSyntax` handling (both
  passes, ~line 274 and ~line 513), `emitTypeDeclarationIfNeeded`, `SyntacticIdentity.typeUSR(named:)`.
- `Sources/IndexStoreIntegration/DeclarationLinker.swift` -- `buildUSRRewriteMap` (the
  `.definition`-role-only, location-based matching this task needs a `.reference`-role sibling
  for), the header comment's own documented "no primary declaration among linked files" limitation
  (this task's fix likely closes it as a side effect), the nesting-mismatch fallback added this
  session (confirms the general shape of "a small, careful fallback for an otherwise-unresolved bare
  placeholder" this task's fix would extend).
- `Sources/IndexStoreIntegration/IndexStoreClient.swift` -- `definedSymbols(inFile:)` (the existing
  `.definition`-only filter to extend/sibling), `baseTypeUSRs(forUSR:)` (Gap B's own `.baseOf`/
  `.extendedBy` mechanism -- the most recent precedent for "add one narrow, verified-first
  IndexStoreDB query, route its result through existing machinery", and the direct precedent for
  variant 1a's own `.extendedBy` hop). `SymbolRole.childOf` (`.build/checkouts/indexstore-db/
  Sources/IndexStoreDB/SymbolRole.swift`) is the one relation role not yet used anywhere in this
  codebase before this task -- confirmed real and confirmed, empirically, to point from a member's
  own `.definition` occurrence at its *immediately enclosing* symbol (the extension's own synthetic
  USR for an extension member, the nominal type directly for a primary-body member).
- `Sources/swift-isolation-map/ExternalIsolationBackfill.swift` -- `resolveDeclarationLevelTriggers`
  (the existing bulk-cache-first, live-oracle-fallback external-superclass backfill mechanism this
  task's fix should reuse, not duplicate), `bulkSymbolGraphCache`.
- `Sources/SourceKitDIntegration/BulkSymbolGraphExtractor.swift` -- confirms the cache is keyed by
  real USR, and that `UIKit` (hence `UIViewController`) is already in `defaultModules`.
- `Sources/IsolationCore/IsolationInferenceEngine.swift` -- `resolveInheritedIsolation` (lines
  75-92, the containing-type-propagation branch this task's fix feeds into automatically once the
  USR is real -- **no change needed here**, confirmed by tracing it end-to-end this session).
- `docs/task-gap-b-declaration-linker-real-scale.md` /
  `docs/task-gap-b-implementation-plan.md` -- read for the exact verify-before-trust discipline
  and documentation shape this task should follow (both closed successfully this session using
  that discipline).

## 6. Explicitly out of scope

- Re-touching Gap A or Gap B -- both closed, correct, measured; this is a genuinely separate,
  adjacent gap found only while spot-checking Gap B's real output, not a Gap B regression.
- `IsolationInferenceEngine` itself -- confirmed, by tracing it directly, to already do the right
  thing *if* given a real, backfilled `containingTypeUSR`. This is purely a linking/backfill-layer
  gap, not an inference-rule gap.
- The Pods/Carthage-in-scope question (`docs/task-pods-in-scope-research.md`) -- unrelated,
  separately deferred.
- Any change to the risk heuristic itself (`docs/isolation-rules.md`'s "nonisolated reaching
  globalActor is high risk" rule is correct and should stay -- the fix is to stop mis-classifying
  the caller as `nonisolated` in the first place, not to weaken the heuristic).
