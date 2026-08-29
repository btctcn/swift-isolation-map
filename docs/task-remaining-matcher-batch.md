# Four more matching fixes, plus explicit dispositions for what's left

## 1. Context

Continuing from `docs/task-demangled-sibling-matching.md`'s final combined run (unknown 1481,
unresolved edges 46, 2.5%). At the user's explicit direction to pursue every remaining `isUnknown`
cluster regardless of edge count, clustered the remaining edges and investigated each with real
evidence (`swift symbolgraph-extract` against the real corpus's own built Pod frameworks/SDKs,
`swift-demangle`), batching four confidently-fixable shapes together and explicitly documenting the
rest.

## 2. Finding: pure-Swift static member accessor vs. declaration USR

`YandexPaySDK.SDKApi.instance`/`.isInitialized` -- a plain pure-Swift singleton, no isolation
attribute of any kind (confirmed via a real `swift symbolgraph-extract` run against the corpus's own
built `YandexPaySDK.framework`) -- shares `BridgedExternClassConstantMatching`'s own "accessor form
vs. declaration form" gap, but for a pure-Swift (non-`"So"`) module: the call graph's own `calleeUSR`
is the accessor form (`"...vgZ"`), the bulk cache's own key is the declaration form (`"...vpZ"`).

**Fix**: new `Sources/IsolationCore/SwiftStaticMemberAccessorDeclarationMatching.swift`.
Deliberately requires a real, digit-length-prefixed module name (excludes `"s:So..."` on purpose --
`BridgedExternClassConstantMatching` already handles that shape via a *live* query, never zero-query,
because its own real isolation can come from class-level inheritance a bulk extraction doesn't
restate per-member; this type must never compete with or shadow that more careful path). Zero-query,
direct bulk cache lookup once rewritten.

## 3. Finding: Objective-C class instance property accessor vs. declaration USR

`UIScene.ConnectionOptions` (`UISceneConnectionOptions`) is a real, confirmed `@MainActor class`
(live `symbolgraph-extract` probe against UIKit). Its own instance properties
(`.shortcutItem`/`.userActivities`) carry the call graph's own `calleeUSR` in Swift-mangled accessor
form (`"...vg"`), but the bulk cache keys an ordinary Clang property by its selector-style form
(`"c:objc(cs)<TypeName>(py)<MemberName>"`) instead -- confirmed exactly against both real properties.

**Fix**: new `Sources/IsolationCore/ObjCInstancePropertyAccessorMatching.swift`. A class-instance
sibling to `BridgedExternClassConstantMatching`'s own static case; deliberately never parses the
return-type mangling, only the `"vg"`/`"vs"` suffix (never `"vgZ"`/`"vsZ"`, which is
`SwiftStaticMemberAccessorDeclarationMatching`'s own case). Zero-query, direct bulk cache lookup.

## 4. Finding: raw C struct field with a compound/underscore-identifier name

`_firebase_appquality_sessions_SessionInfo.firebase_installation_id` (a nanopb-generated C struct
field, snake_case name -- common across any protobuf-generated C struct, not a one-off) shares
`ImportedStructMemberMatching`'s own shape (a raw imported struct field), but its own name uses
Swift's real compound/underscore-identifier mangling scheme, which that type's simple length-prefixed
parser correctly declines to guess at rather than misparse.

**Fix**: new `Sources/SourceKitDIntegration/DemangledStructMemberMatching.swift`. Rather than
hand-derive Swift's real compound-identifier grammar (real risk of a subtly wrong parse), defers to
the real demangler and checks the demangled text's own shape: a raw struct field demangles to
`"__C.<TypeName>.<memberName>.getter/setter : <ReturnType>"`, while a genuine Swift-authored
*extension* member is always prefixed `"(extension in <Module>):"` by `swift-demangle` itself --
confirmed via a controlled comparison (`CGSize.width` vs. `CGSize.isEmpty`). Still requires the
mangled USR's own container-kind marker to be `"V"` (struct), reusing
`ImportedStructMemberMatching`'s own type-name-plus-marker parse for that part -- a raw C **class**
member can genuinely carry a real isolation attribute (`BridgedExternClassConstantMatching`'s own
confirmed `UITableView.automaticDimension` case, *also* `"__C."`-prefixed with no `"(extension in "`),
so `"__C."` alone is never a safe discriminator by itself.

## 5. Finding: `CFRunLoopMode.defaultMode`'s Optional-returning compressed shape

Same typealias-wrapper, compressed-name shape `BridgedExternConstantContainerMatching` (issue #94)
already covers (`URLResourceKey`'s own `"B0"`-style substitution compression), but with an
**Optional-wrapped** return type instead of a bare `Self` -- confirmed via `swift-demangle`:
`"static __C.CFRunLoopMode.defaultMode.getter : __C.CFRunLoopMode?"`. The real suffix is
`"ABSgvgZ"` (`"Sg"` = Optional, inserted between the `Self` marker and the accessor-kind suffix), not
`"ABvgZ"`.

**Fix**: new `Sources/SourceKitDIntegration/BridgedExternConstantOptionalContainerMatching.swift`, a
narrow sibling with the identical container/candidate-matching logic, differing only in the suffix
literal it requires. Kept separate rather than widening the existing, already-shipped, independently-
tested type -- consistent with this whole investigation's established precedent.

## 6. Real `Project Iris` corpus, before/after (all four fixes together, one combined run)

| | before | after |
|---|---|---|
| External oracle unknown | 1481 | **1472** (-9) |
| Cross-isolation edges (denominator) | 1807 | **1790** |
| Unresolved edges (isUnknown) | 46 | **28** (-18) |
| Unresolved % | 2.5% | **1.6%** |

`highRiskBoundaries` 1471 → 1472 (+1) -- a real, previously-hidden risk boundary surfaced by
resolving `UISceneConnectionOptions.shortcutItem`'s own genuine `@MainActor` isolation, not noise.

## 7. Investigated and explicitly not fixed

Per the user's explicit direction to give every remaining cluster due diligence regardless of size,
each of the following was investigated with real evidence; none was force-fixed without a safe,
confident mechanism.

**Mindbox `AsyncOperation.setExecuting:`/`setFinished:`** (2 edges): `AsyncOperation`'s own
`isExecuting`/`isFinished` are `override`s of `Operation`'s real `@objc dynamic` properties. The
*Swift-mangled* setter form (`s:7Mindbox14AsyncOperationC11isExecutingSbvs`) is already correctly
linked (real location, `.nonisolated`) -- but the call graph *also* carries a separate,
module-qualified **Clang selector** form for the same assignment (`isExecuting = true` in `start()`),
never linked. `ObjCProtocolPropertyWitnessMatching`'s own "never compare names" design doesn't
directly transfer: that type is specifically scoped to *protocol witnesses* (`c:objc(cs)...`, no
module qualifier) and a *live* query is what supplies its real candidate; here the target is already
`c:@M@Mindbox@objc(cs)...`-qualified (project/pod-source, a different namespace
`ObjCProtocolPropertyWitnessMatching`'s own `parse()` deliberately excludes), and there's no
established, low-risk mechanism to reliably resolve *why* both a Swift and a Clang form of the same
assignment appear as separate call-graph edges, nor to safely disambiguate `setExecuting:` from
`setFinished:` without name comparison (the same `is`-prefix boolean-naming asymmetry
`ObjCProtocolPropertyWitnessMatching`'s own doc comment already warns about). Real root cause not
fully isolated -- set aside rather than guessed at, same standard as
`docs/task-indexstore-declaration-completeness.md`'s own "5 minimal-reproduction attempts failed, no
upstream report filed" precedent.

**`NSMutableDictionary["key" as NSCopying]`** (2 edges): `dictionary[key]` where `key: String` (real
source, `Pods/Signals/Signals/ios/UIControl+Signals.swift`) produces a call-graph USR parameterized by
`NSCopying` (`s:So19NSMutableDictionaryCyypSgSo9NSCopying_pcig`/`cis`), not the generic `Any`-keyed
form `SubscriptAccessorDeclarationMatching` (issue #94) already resolves. Searched Foundation's own
`symbolgraph-extract` output (both `public` and `internal` access levels) for any subscript
declaration parameterized by `NSCopying` on `NSDictionary`/`NSMutableDictionary` -- none found. The
real declaration this overload resolves to could not be located in any inspectable symbolgraph;
forcing a fix without finding the real declaration would be exactly the kind of guess this project's
discipline exists to prevent.

**`MKCoordinateRegion.center`'s setter** (1 edge): demangles to
`"__C.MKCoordinateRegion.center.setter : __C.CLLocationCoordinate2D"` -- structurally identical to
`DemangledStructMemberMatching`'s own accepted shape -- but the container's own mangled marker is
`"a"` (typealias), not `"V"` (struct). `MKCoordinateRegion` is confirmed a real `struct` via the same
`symbolgraph-extract` probe, making this specific case safe -- but `"a"` can also wrap a **class**
(the same marker `BridgedExternConstantMatching`'s own genuinely-variable-isolation case uses), and
`DemangledStructMemberMatching` cannot currently tell "typealias wrapping a struct" from "typealias
wrapping a class" without an additional check. Widening the container-kind gate to accept `"a"`
unconditionally risks exactly the false-positive class this project's discipline is built to avoid;
deferred rather than done on a single confirmed-safe instance.

**8 `_Release`-module-qualified USRs** (default `init()`, a synthesized case-payload accessor, a
couple of properties): already documented, already-accepted issue #55 shape
(`docs/task-implicit-synthesized-declarations.md`) -- a compiler-synthesized declaration has no
`SwiftSyntax` node in source text for *any* of the targets that compile it, not a new finding.

## 8. Status

**FIXED AND VERIFIED**, four matchers batched together: 4 new unit-test suites + 3 new end-to-end
tests in `ExternalIsolationBackfillTests.swift`, full suite (500/500) passing, real-corpus
before/after above. Four additional clusters investigated with real evidence and explicitly left
unresolved, reasoning documented above rather than guessed at.

**Reconfirmed against a fresh real Project Iris run, 2026-08-29** (after PR #101-119, none of which
touched these matchers):
- Mindbox `AsyncOperation.setExecuting:`/`setFinished:` -- **not reproducible today.** Zero edges
  referencing `AsyncOperation` appear anywhere in a fresh full run's output, even though the class
  itself is still present in the corpus (`Pods/Mindbox/Mindbox/GuaranteedDeliveryManager/
  GuaranteedDeliveryManager.swift:156`, now additionally annotated `@unchecked Sendable`, which it
  wasn't at the time of the original finding). Most likely the Mindbox pod version installed in the
  corpus has since changed the exact call shape that produced the original 2 edges -- not something
  this project fixed. Not re-opened as an issue since there's nothing current to point at.
- `NSMutableDictionary["key" as NSCopying]` -- **still open**, reconfirmed byte-for-byte
  (`UIControl+Signals.swift:110,114`). Filed as
  [issue #126](https://github.com/btctcn/swift-isolation-map/issues/126).
- `MKCoordinateRegion.center`'s setter -- **still open**, reconfirmed
  (`MapViewController.swift:165`). Filed as
  [issue #127](https://github.com/btctcn/swift-isolation-map/issues/127).
- 8 `_Release`-module-qualified USRs (issue #55 shape) -- **still present as a category** (18 such
  edges in the fresh run, not 8 -- expected drift, this is a corpus-size-dependent count, not a
  fixed constant). No new issue; already covered by issue #55's own accepted-limitation scope.
