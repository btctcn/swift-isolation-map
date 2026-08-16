# A second NS_SWIFT_NAME-bridged extern-constant shape: class-marker, not typealias-wrapper

## 1. Context

Continuing from `docs/task-imported-c-struct-isolation.md`'s §5 baseline (real `Project Iris`
corpus, 38% of cross-isolation edges unresolved): the next-largest `isUnknown` cluster after raw
imported C struct fields was `UITableView`/`UIResponder`/`UIApplication`/`UISceneConnectionOptions`
-- ~200+ edge-endpoint mentions, motivating example `UITableView.automaticDimension` used inside a
`tableView(_:heightForRowAt:)` override.

## 2. Not the same fix as `ImportedStructMemberMatching` -- confirmed via a real live-toolchain probe, not assumed

The initial hypothesis (by analogy with `ImportedStructMemberMatching`) was that this is another
"plain extern C constant, categorically outside Swift's attribute system" case, safely resolvable
to `.nonisolated` with zero live query. **This was checked, not assumed**, per this project's own
discipline: a from-scratch, real-toolchain minimal reproduction (a temporary `CursorInfoProbe`
executable target, added to `Package.swift`, run once, then fully reverted) issued a real `cursorinfo`
request against `UITableView.automaticDimension` and printed every field of the real result.

**The hypothesis was wrong.** The real declaration's own `symbolGraphJSON` shows:

```
@MainActor class let automaticDimension: CGFloat
```

`UITableView.automaticDimension` genuinely *is* `@MainActor`-isolated. Unlike a raw C struct field
(never eligible to carry a Swift attribute at its own original declaration), this is a Clang
`extern const CGFloat UITableViewAutomaticDimension` re-exported into Swift via `NS_SWIFT_NAME`
onto `UITableView` as a `class let` -- and `NS_SWIFT_NAME`-bridged members, unlike raw struct
fields, are perfectly ordinary points where Apple's own headers attach `NS_SWIFT_UI_ACTOR`/
`@MainActor` (UIKit's real, current convention for main-thread-only API). The real isolation
therefore genuinely varies per symbol and must still come from a live query -- this shape needed a
*matching* fix (find the right live-query candidate once strict USR equality fails), not a
*bulk-cache-avoidance* fix.

## 3. Root cause: same family of gap as `BridgedExternConstantMatching` (docs/task-extern-constant-swift-name-usr-mismatch.md), different mangling shape

`BridgedExternConstantMatching` (already shipped, PR #82/#86) covers the case where the Swift-
exposed wrapper is a `typealias`-to-struct (`NSAttributedString.Key`, via
`NS_TYPED_EXTENSIBLE_ENUM`) -- Swift mangling marker `"a"` after the type name, and the member's own
return type is always `Self` (hardcoded `"ABvgZ"` literal suffix in that type's own grammar).

`UITableView.automaticDimension` bridges onto a **plain class**, not a typealias wrapper -- marker
`"C"`, not `"a"` -- and its return type (`CGFloat`) is *not* `Self`, so the existing type's hardcoded
`"ABvgZ"` suffix literal doesn't apply either. Confirmed this is a broad, common pattern by real
corpus sweep, not a one-off: `UIResponder.keyboardWillShowNotification`,
`UIApplication.openSettingsURLString`, `UIApplication.didBecomeActiveNotification`, and many other
notification-name/user-info-key constants all share the identical `"C"`-marker, arbitrary-return-
type, `"...vgZ"`-suffix grammar.

## 4. Fix

New `Sources/SourceKitDIntegration/BridgedExternClassConstantMatching.swift`, a sibling to
`BridgedExternConstantMatching` rather than a modification of it (the existing type's hardcoded
`"ABvgZ"`/`"a"`-marker assumptions are real, shipped, tested behavior for its own confirmed shape;
extending it to also accept `"C"` and an arbitrary return type would have required threading a new
parameter through code whose current simplicity depends on those exact assumptions holding).

Grammar:
```
s:So<N><TypeName>C<N2><MemberName><ArbitraryReturnTypeMangling>vgZ
```
Deliberately never parses the return-type mangling at all -- only the type/member names and the
literal `"vgZ"` accessor-kind suffix at the very end. Every real example observed is a `class let`
(get-only, static) -- scoped to `"vgZ"` only, not generalized to instance members or setters beyond
the evidence. The container-type-USR discriminator mirrors the sibling type's own pattern with the
marker changed: `"$sSo<N><TypeName>CmD"` (confirmed exactly against the real probe:
`"$sSo11UITableViewCmD"`).

Wired into `ExternalIsolationBackfill.query()`'s existing fallback chain, after
`BridgedExternConstantMatching` (mutually exclusive by construction -- the `"a"`/`"C"` marker check
means the two types can never both match the same real USR).

9 new unit tests (`BridgedExternClassConstantMatchingTests.swift`, mirroring
`BridgedExternConstantMatchingTests.swift`'s own structure) + 1 end-to-end test in
`ExternalIsolationBackfillTests.swift` -- deliberately asserting `.globalActor(name: "MainActor")`,
not `.nonisolated`, to keep the test suite itself honest about this shape's real, variable isolation
(unlike `ImportedStructMemberMatching`'s fixed-fact case).

## 5. Real `Project Iris` corpus, before/after

| | before | after |
|---|---|---|
| External oracle unknown | 1827 | **1804** (**-23**) |
| Cross-isolation edges (denominator) | 2423 | **2236** (**-187**) |
| Unresolved % | 38% | **32%** (**-6pp**) |

Smaller than the raw-C-struct-field fix in absolute `unknown` count, but the denominator still
shrank substantially -- most `automaticDimension`/notification-name/user-info-key call sites turn
out to be `@MainActor -> @MainActor` or otherwise safe once correctly resolved, dropping out of the
risky-edges list the same way the earlier fixes did.

## 6. Status

**FIXED AND VERIFIED**, 10 new tests, real-corpus before/after above. The temporary
`CursorInfoProbe` executable target used to capture the real live-query fields has been fully
removed from `Package.swift` and `Sources/` -- no trace left in the final diff.
