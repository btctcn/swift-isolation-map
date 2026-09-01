# Investigation: issue #122 — is `MultiTargetDeclarationAliasing`'s compression gap still open?

**Status: resolved -- the gap issue #122 describes was already closed by PR #99 (2026-08-16); only
`MultiTargetDeclarationAliasing.swift`'s own doc comment had never been updated to say so.** No
functional code change; the fix is a corrected doc comment.

## What issue #122 claimed

`MultiTargetDeclarationAliasing`'s cheap suffix comparison can miss a real sibling-target alias when
Swift's mangling substitution compression makes the module-stripped suffixes of two variants of the
same physical declaration diverge (a module name that's a textual prefix of the type name). The
issue's own text noted `DemangledSiblingMatching` (PR #99) "closed the majority of this class of gap
... for its own cases," but read `MultiTargetDeclarationAliasing` as a *distinct, still-shipping*
code path whose own compression edge case remained open, since its own doc comment (never rewritten
since PR #99 landed) still describes it as a "known, deliberately accepted limitation."

## What's actually true, confirmed by reading the real pipeline

`ExternalIsolationBackfill.collectEdgeLevelWorkItems` (`Sources/swift-isolation-map/
ExternalIsolationBackfill.swift`) runs `MultiTargetDeclarationAliasing`'s cheap suffix match first,
then collects every USR shaped like a multi-target sibling (`MultiTargetDeclarationAliasing.
moduleNameAndSuffix(ofSwiftUSR:)` non-nil) that's *still* unresolved after that pass
(`stillPendingMultiTargetUSRs`), and runs `DemangledSiblingMatching`'s real-`swift-demangle`-based
fallback on exactly that set -- immune to compression by construction, since a demangled name is the
fully-expanded human-readable form, not the raw mangled suffix. This is precisely the fallback issue
#122 asks for, already shipped: `DemangledSiblingMatching`'s own doc comment even names the exact
real Project Iris compression case (`CurrentNotifications.removeOldNotifications`, `07CurrentB0C...`
vs. `20CurrentNotificationsC...`) that motivated it. PR #99's own real-corpus verification: unresolved
edges 81 -> 46 (4.4% -> 2.5%) on Project Iris.

`git log --follow` on `MultiTargetDeclarationAliasing.swift` shows exactly one commit ever
(`22eb17a`, the file's original addition) -- confirming the doc comment genuinely was never touched
after PR #99 wired the fallback in, which is what made issue #122's re-reading plausible.

## Fix

Rewrote `MultiTargetDeclarationAliasing.swift`'s doc comment to state the real, current picture:
this type's own suffix comparison still has the same false-negative-only compression gap in
isolation, but `ExternalIsolationBackfill`'s own fallback pass already closes it via
`DemangledSiblingMatching`, referencing PR #99's real corpus numbers directly. No behavior change --
`DemangledSiblingMatching`'s fallback was already running in production for every real analysis run
since PR #99 merged.

## Verification

`swift test --filter "MultiTargetDeclarationAliasing|DemangledSiblingMatching"`: 12/12 passing
(unchanged by a doc-only edit; run to confirm the file still compiles and existing coverage for both
types is intact).
