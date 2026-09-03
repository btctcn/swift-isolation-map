# MKCoordinateRegion.center's setter: typealias-wrapped struct member (issue #127)

**Status: CLOSED — fixed and real-corpus verified.** Closes
[issue #127](https://github.com/btctcn/swift-isolation-map/issues/127).

## Background

First found and left unresolved in `docs/task-remaining-matcher-batch.md` §7: a real call-graph edge
(`coordinateRegion?.center = center`, `MapViewController.swift:165`) carries
`s:So18MKCoordinateRegiona6centerSo22CLLocationCoordinate2DVvs` — demangles to
`__C.MKCoordinateRegion.center.setter : __C.CLLocationCoordinate2D`, structurally identical to
`DemangledStructMemberMatching`'s own accepted raw-struct-field shape, except the container's own
mangled marker is `"a"` (typealias) instead of `"V"` (struct). `MKCoordinateRegion` was confirmed a
real `struct` via a `symbolgraph-extract` probe, making *this specific instance* safe — but `"a"`
alone is genuinely ambiguous (it's also `BridgedExternConstantMatching`'s own confirmed
`NSAttributedString.Key.font` marker, wrapping a type with real Objective-C *class* lineage), so
widening `DemangledStructMemberMatching`'s bulk-cache gate to accept `"a"` unconditionally was
deliberately not done — filed as an issue instead of guessed at.

## Investigation: why live query alone didn't already resolve this

Before designing a fix, instrumented `ExternalIsolationBackfill.query` with a temporary,
USR-gated debug probe (reverted before this fix landed) and ran it against the real edge. The real
live `cursorinfo` response at the real call site:

```
primary.usr = c:@SA@MKCoordinateRegion@FI@center
primary.containerTypeUSR = $sSo18MKCoordinateRegionaD
primary.declarationFragments = [var, " ", center, ": ", CLLocationCoordinate2D]   -- no isolation attribute
relationships = [{"kind":"memberOf","source":"...center","target":"c:@SA@MKCoordinateRegion"}]
```

The live query **already finds the correct, real declaration** — genuinely no isolation attribute,
which `SymbolGraphIsolationParser`'s own doc comment already establishes is a *confirmed* fact for a
live-query result (unlike a bulk dump, a live query fully resolves *effective* isolation, including
anything inherited from a class hierarchy — `UINavigationController.pushViewController`'s own
`@MainActor` restatement in a live query, despite carrying no attribute of its own, is the existing,
already-documented proof of this). The actual blocker was never isolation-attribute detection: it
was **candidate selection**. `USRMatching.select`'s strict equality compares the live-returned Clang
USR (`c:@SA@MKCoordinateRegion@FI@center`) against the call graph's own Swift-mangled `targetUSR`
(`s:So18MKCoordinateRegiona...Vvs`) — they can never match — and none of the six existing fallback
matchers in `ExternalIsolationBackfill.query`'s own `??` chain are shaped for this case either, so
the whole query fell through to `.unknown` despite the compiler already having answered correctly.

**This reframes the whole problem**: no struct/class disambiguation is actually needed to fix
isolation *correctness* — a live query resolves that safely either way. The real, scoped fix is a
new *candidate-selection* matcher, the same shape as `ObjCProtocolPropertyWitnessMatching` (which
solves an analogous Swift-mangled-target-vs-Clang-form-candidate mismatch for a different real
shape).

## Fix

Added `TypealiasWrappedStructMemberMatching`
(`Sources/SourceKitDIntegration/TypealiasWrappedStructMemberMatching.swift`), mirroring
`ObjCProtocolPropertyWitnessMatching`'s own design exactly:

- Parses `targetUSR` for the `"s:So<N><TypeName>a<N2><MemberName><ReturnTypeMangling>v[g|s]"`
  shape (`"a"` marker, real property-accessor suffix `"vg"`/`"vs"` — never overlapping with
  `SubscriptAccessorDeclarationMatching`'s own `"cig"`/`"cis"` domain).
- Matches a live-query candidate by container-type-USR (`"$sSo<N><TypeName>aD"`, mirroring
  `ObjCProtocolPropertyWitnessMatching`'s own `"D"`-suffixed instance-member shape) — never by
  member name, same reasoning as that type: the query already runs at the exact position the
  original call-graph edge recorded.
- **Additionally requires the candidate's own USR to be a genuine Clang struct-field form
  (`"c:@S@"`/`"c:@SA@"`, never `"c:objc(cs)"`)** — not load-bearing for isolation correctness (the
  live-query-resolves-inheritance argument above already covers a real class candidate safely too),
  but a cheap, real, extra confirmation that this is genuinely matching a struct field rather than
  trusting the container-type-USR string alone.

Wired into `ExternalIsolationBackfill.query`'s existing fallback chain, after
`BridgedExternFunctionPropertyMatching`.

## Verification

- 12 new unit tests (`Tests/SourceKitDIntegrationTests/TypealiasWrappedStructMemberMatchingTests.swift`):
  the real `MKCoordinateRegion.center` getter/setter shapes, rejection of the `"V"`-marked form
  `DemangledStructMemberMatching` already owns, rejection of the unrelated subscript-accessor
  suffix, both real Clang struct-form prefixes (`"c:@S@"` tag-named, `"c:@SA@"` anonymous), and
  explicit rejection of a genuine Objective-C class candidate even with a matching
  container-type-USR string.
- `swift test -c release`: full suite passing (see PROJECT-HISTORY.md entry for the exact count).
- **Real-corpus A/B on Project Iris**, controlled (`git stash`, identical index store, identical
  corpus state, `--oracle-workers 8` both sides): node count unchanged (41669/41669), exactly 1 node
  diff — the real setter USR flips `unspecified` → `nonisolated`. External oracle `resolved` 3805 →
  3806 (+1), `unknown` 102 → 101 (-1), `unspecifiedIsolation` 111 → 110 (-1), `crossActorBoundaries`
  1555 → 1554 (-1, the edge no longer crosses an isolation boundary once resolved, correctly dropped
  from the report — same suppression PR #50 already established). `highRiskBoundaries` unchanged
  (1486/1486) — zero regression.
