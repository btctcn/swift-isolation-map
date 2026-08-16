# A Core Foundation opaque-pointer property bridged from a plain Clang C function

## 1. Context

Continuing from `docs/task-objc-protocol-property-witness-isolation.md`'s §5 baseline (real
`Project Iris` corpus, 22% of cross-isolation edges unresolved): the next cluster was
`CGImageRef`/`CGContextRef` properties (`.width`, `.height`, `.bitsPerComponent`,
`.bitsPerPixel`, `.colorSpace`, ...) -- ~39 of the remaining 196 `isUnknown` edges.

## 2. Root cause

A Core Foundation opaque-pointer type is exposed to Swift as a `typealias` to its own
"toll-free-bridged" class (`typealias CGImageRef = CGImage`). Its real properties
(`CGImage.width`, `.height`, ...) aren't genuine Objective-C properties at all -- they're plain
Clang **C functions** (`CGImageGetWidth(_:)`) the Swift importer bridges into computed-property
syntax via `CF_SWIFT_NAME(getter:)`. A real call-graph edge accessing `someImage.width` (written
through the `CGImageRef` typealias spelling, the conventional CoreFoundation style this project's
own corpus and SDK headers both use) carries the Swift-mangled `s:So10CGImageRefa5widthSivg` -- but
neither `symbolgraph-extract`'s bulk output nor a live `cursorinfo` hover ever key this member that
way: both use the bridged function's own real Clang USR, `c:@F@CGImageGetWidth`.

## 3. Checked via a real, from-scratch minimal reproduction, not assumed

Reused the same temporary iOS SPM package + `CursorInfoProbe` executable target already built for
`docs/task-objc-protocol-property-witness-isolation.md` (both fully reverted again after use):
added a plain `func probeCGImageWidth(_ image: CGImage) -> Int { return image.width }` and queried
live `cursorinfo` at the real call site. Confirmed: `usr: "c:@F@CGImageGetWidth"`,
`declLang: "source.lang.objc"`, `containerTypeUSR: "$sSo10CGImageRefaD"`, `name: "width"` -- a
plain, unattributed `var width: Int { get }`, no isolation attribute of any kind.

## 4. Fix

New `Sources/SourceKitDIntegration/BridgedExternFunctionPropertyMatching.swift`. Real USR mangling
grammar, confirmed against the real probe plus several real sibling properties observed in the
corpus (`CGImage.height`/`.bitsPerComponent`, `CGContext.width`/`.height`):
```
s:So<N><TypeName>a<N2><MemberName><ArbitraryReturnTypeMangling>vg
```
The `"a"` (typealias) marker immediately after `<TypeName>` is the same marker
`BridgedExternConstantMatching` also checks, but that type's own `parse()` only ever succeeds for
its own literal `"ABvgZ"` (`Self`-returning, static-getter) suffix -- this type is checked *later*
in the fallback chain and only reached once that attempt has already failed, so there's no real
ambiguity despite sharing one marker character. Like `ImportedStructMemberMatching`/
`ImportedTopLevelConstantMatching`, the return-type mangling in between is never validated, only
the exact `"vg"` getter suffix at the very end (every real example observed is get-only).

Following `ObjCProtocolPropertyWitnessMatching`'s own established reasoning: deliberately never
compares the candidate's own name either -- the query already runs at the exact position the
original call-graph edge itself recorded, so only the declaration's own kind (genuinely Clang,
genuinely a bridged *function* -- `usr.hasPrefix("c:@F@")`, not a plain extern constant or an
Objective-C method/property) and its container (matching the concrete typealias `targetUSR` itself
names, `"$sSo<N><TypeName>aD"`) are cross-checked.

Wired into `ExternalIsolationBackfill.query()`'s existing fallback chain, as the fifth and final
matcher, after `ObjCProtocolPropertyWitnessMatching`.

11 new unit tests (`BridgedExternFunctionPropertyMatchingTests.swift`, including a dedicated test
confirming `BridgedExternConstantMatching`'s own real `"ABvgZ"`-suffixed shape is correctly
rejected by this type's own `parse()`) + 1 end-to-end test in `ExternalIsolationBackfillTests.swift`.

## 5. Real `Project Iris` corpus, before/after

| | before | after |
|---|---|---|
| External oracle unknown | 1609 | **1594** (**-15**) |
| Cross-isolation edges (denominator) | 1939 | **1916** (**-23**) |
| Unresolved % | 22% | **21%** (**-1pp**) |

## 6. Status

**FIXED AND VERIFIED**, 12 new tests, real-corpus before/after above. The temporary iOS mini-repro
package and `CursorInfoProbe` executable target used to confirm the real behavior have been fully
removed -- no trace in the final diff.

## 7. Session-wide summary (all five external-isolation matching fixes this investigation)

| Fix | PR | Shape | Unresolved % |
|---|---|---|---|
| baseline | -- | -- | 74% |
| Bulk destination + `#if` blindness + phantom setters + empty-body protocols + rawValue/allCases | #87 | mixed | 65% |
| `ImportedStructMemberMatching` | #88 | raw C struct field | 38% |
| `BridgedExternClassConstantMatching` | #89 | class-exposed extern constant | 32% |
| `ImportedTopLevelConstantMatching` | #90 | non-member extern constant | 24% |
| `ObjCProtocolPropertyWitnessMatching` | #91 | ObjC protocol property witness | 22% |
| `BridgedExternFunctionPropertyMatching` | this | CF bridged-function property | **21%** |

Unresolved cross-isolation edges dropped from 74% to 21% (a 3.5x reduction) over this session,
external oracle unknown count from 2546 to 1594 (-37%), through nine independent, each individually
verified and documented root causes -- most resolvable with zero live oracle query at all once
correctly recognized, the rest resolvable via a live query once the right USR-matching fallback was
in place.
