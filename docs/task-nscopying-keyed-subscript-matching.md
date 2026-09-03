# NSDictionary/NSMutableDictionary["key" as NSCopying] subscript accessor resolution

**Status: CLOSED — fixed and real-corpus verified.** Closes
[issue #126](https://github.com/btctcn/swift-isolation-map/issues/126).

## Background

First found and left unresolved in `docs/task-remaining-matcher-batch.md` §7: a call-graph edge for
`dictionary[key]`/`dictionary[key] = value` (real source, `Pods/Signals/Signals/ios/
UIControl+Signals.swift:110,114`, `dictionary: NSMutableDictionary`, `key: String`) carries a
subscript accessor USR parameterized by `NSCopying`
(`s:So19NSMutableDictionaryCyypSgSo9NSCopying_pcig`/`...pcis`), not the generic `Any`-keyed form
`SubscriptAccessorDeclarationMatching` (issue #94) already resolves. That investigation searched
Foundation's own `symbolgraph-extract` output (both `public` and `internal` access levels) for any
subscript declaration parameterized by `NSCopying` and found none — filed as issue #126 rather than
guessed at.

## Why the overload exists

`NSDictionary`/`NSMutableDictionary` expose Cocoa's keyed-subscripting convention directly from
their own Objective-C methods: `objectForKeyedSubscript:` (declared on `NSDictionary`, so both
classes get a getter) and `setObject:forKeyedSubscript:` (declared on `NSMutableDictionary` only,
adding a setter there). ClangImporter synthesizes this pair into a Swift `subscript(key: NSCopying)
-> Any? { get [set] }`, distinct from the Swift overlay's own separate, generic `subscript(key: Any)
-> Any? { get set }` extension (issue #94's own subject) — overload resolution at a real call site
picks whichever is more specific for the key's static type, so both shapes occur in real code.

## Root cause, found by re-extracting Foundation's symbolgraph directly

Issue #126's own search looked for text mentioning `NSCopying` and came up empty. Re-running the
identical extraction (`xcrun swift symbolgraph-extract -module-name Foundation -sdk <iOS Simulator
SDK> -target arm64-apple-ios17.0-simulator -minimum-access-level public`) and instead searching
*structurally* (every symbol whose `pathComponents` start with `NSMutableDictionary`, not just ones
whose `declarationFragments` happen to spell "NSCopying") found what the text search missed: **the
getter's underlying Clang method genuinely is present** — twice, in fact:

```
kind: swift.subscript, pathComponents: [NSDictionary, subscript(_:)],
  identifier.precise: c:objc(cs)NSDictionary(im)objectForKeyedSubscript:
  declarationFragments end "{ get }"
kind: swift.subscript, pathComponents: [NSMutableDictionary, subscript(_:)],
  identifier.precise: c:objc(cs)NSDictionary(im)objectForKeyedSubscript:   -- same USR as above
  declarationFragments end "{ get set }"
```

`symbolgraph-extract` never independently serializes this ClangImporter-synthesized overload as a
Swift-mangled `"cip"`-suffixed declaration (which is why issue #94's own `Subscript
AccessorDeclarationMatching.subscriptDeclarationUSR` rewrite — `"...cig"/"...cis"` → `"...cip"` —
computes a USR that's never actually in the bulk cache for this shape, and its own `bulkCache[...]`
lookup silently misses). Instead it keys the *whole* get(+set) pair by the getter's own Clang method
USR, emitted once per container (`NSDictionary` get-only, `NSMutableDictionary` get+set).
`setObject:forKeyedSubscript:`'s own selector never appears anywhere in the extracted output as an
independent symbol — there is no way to resolve the setter any more precisely than "the same
subscript the getter belongs to," which is sufficient here: isolation is a property of the
subscript/its container (both classes are always `.nonisolated`), not of get vs. set individually.

**Confirmed real, not guessed**: a from-scratch minimal repro (`NSDictionary`/`NSMutableDictionary`
read/write with an explicit `as NSCopying` cast, compiled with `-index-store-path` to a fresh local
index store) produced exactly the three predicted real accessor USRs in the real, on-disk index
store: `s:So12NSDictionaryCyypSgSo9NSCopying_pcig` (`NSDictionary` getter),
`s:So19NSMutableDictionaryCyypSgSo9NSCopying_pcig` (`NSMutableDictionary` getter, matching the
original real corpus finding), and `s:So19NSMutableDictionaryCyypSgSo9NSCopying_pcis`
(`NSMutableDictionary` setter, also matching the original finding).

## Fix

Added `BridgedKeyedSubscriptMatching` (`Sources/IsolationCore/BridgedKeyedSubscriptMatching.swift`):
recognizes the exact `NSCopying`-parameterized, `Any?`-returning subscript-accessor suffix
(`"SgSo9NSCopying_pcig"`/`"...pcis"`) on one of the two real, confirmed containers
(`So12NSDictionaryC`/`So19NSMutableDictionaryC`), and maps both accessor forms to the one fixed
Clang USR `c:objc(cs)NSDictionary(im)objectForKeyedSubscript:` for a plain bulk-cache lookup — zero
live query needed, same "accessor form has no direct bulk-cache entry, needs a matcher to bridge to
the form that does" shape as every other matcher in `ExternalIsolationBackfill.
collectEdgeLevelWorkItems`. Wired in immediately after `SubscriptAccessorDeclarationMatching`'s own
check (which already fires for `"...cig"/"...cis"` in general but silently misses this specific
shape, falling through without `continue`).

Deliberately narrow, not generalized past what's confirmed: only the two real containers match: a
hypothetical third class exposing the same Cocoa keyed-subscripting convention would not be
recognized without its own confirmed real-corpus occurrence, matching this project's own "verify
before generalizing" discipline (`isCustomConditionSet` before issue #121,
`MultiTargetDeclarationAliasing`'s compression gap before issue #122).

## Verification

- 4 new unit tests (`Tests/IsolationCoreTests/BridgedKeyedSubscriptMatchingTests.swift`): the three
  confirmed real shapes resolve correctly, the `Any`-keyed form (issue #94's own subject) is
  correctly rejected so the two matchers never both claim the same USR, an unrelated container is
  rejected, and ordinary/unrelated USRs are rejected.
- `swift test -c release`: 604/604 passing (twice repeated to rule out this session's own
  independently-tracked oracle-query non-determinism, [issue #142](https://github.com/btctcn/swift-isolation-map/issues/142) — one run of three did show
  2 unrelated flaky failures in real end-to-end sourcekitd-backed tests, not reproduced on either
  repeat).
- **Real-corpus A/B on Project Iris**, controlled (`git stash`, identical index store, identical
  corpus state, `--oracle-workers 8` both sides): node count unchanged (41669/41669), exactly 2 node
  diffs — both target USRs flip `unspecified` → `nonisolated`, nothing else changes. External oracle
  `unknown` 104 → 102 (-2), `resolved` 3803 → 3805 (+2), `unspecifiedIsolation` 113 → 111 (-2),
  `crossActorBoundaries` 1557 → 1555 (-2, the two edges no longer cross an isolation boundary once
  both sides are confirmed `nonisolated`, correctly dropped from the report — same suppression PR
  #50 already established for confirmed-nonisolated pairs). `highRiskBoundaries` unchanged
  (1486/1486) — zero regression.
