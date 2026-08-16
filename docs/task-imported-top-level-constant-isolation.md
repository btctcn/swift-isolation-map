# Plain top-level imported Clang constants (no containing type at all)

## 1. Context

Continuing from `docs/task-bridged-extern-class-constant-isolation.md`'s §5 baseline (real
`Project Iris` corpus, 32% of cross-isolation edges unresolved): bucketing the remaining
`isUnknown` edges by USR shape turned up a large family of plain, non-member Clang `extern const`
globals imported directly into Swift's module namespace -- `NSCocoaErrorDomain`,
`NSPersistentStoreForceDestroyOption`, CoreText's `kNumberCaseType`/`kUpperCaseNumbersSelector`/
etc. (heavily used by the `SwiftRichString` dependency's own font-feature code), CoreTelephony's
`CTRadioAccessTechnology*` family, Contacts' `CNContactPhoneNumbersKey`, and more -- spanning
several unrelated modules (`Foundation`, `CoreText`, `CoreTelephony`, `Contacts`).

## 2. Root cause

Structurally similar to `ImportedStructMemberMatching`'s own gap (raw struct fields absent from
`symbolgraph-extract`'s output) and `BridgedExternClassConstantMatching`'s own gap (Swift-mangled
USR vs. real Clang USR key mismatch) -- but distinct from both: a plain, non-member global constant
has **no containing type at all**, so there is no type USR to key a bulk-cache dictionary entry by
in the first place. The bulk cache is keyed by the symbol's own real Clang USR
(`c:@NSCocoaErrorDomain`), never the Swift-mangled global (`s:So18NSCocoaErrorDomainSSvg`) the call
graph's own `calleeUSR` carries.

## 3. Checked, not assumed

Per this project's own discipline (directly reinforced by `BridgedExternClassConstantMatching`'s
own investigation, where an initial "by analogy, always nonisolated" guess turned out wrong): a real
live-toolchain probe (temporary executable target, fully reverted) against both `NSCocoaErrorDomain`
and CoreText's `kNumberCaseType` confirmed their real `declarationFragments` carry **no attribute of
any kind** -- plain `let NSCocoaErrorDomain: String` / `var kNumberCaseType: Int { get }`. Unlike a
class's own static/instance member (which genuinely can carry `@MainActor`, per the
`automaticDimension` case), a bare top-level global constant is never a point Apple's headers attach
an actor annotation to -- there's no "actor" for a plain value to be affiliated with in the first
place, a structural (not just empirical) distinction from the class-member case.

## 4. Fix

New `Sources/IsolationCore/ImportedTopLevelConstantMatching.swift`. Real USR mangling grammar,
confirmed against dozens of real, independent examples across four unrelated modules:
```
s:So<N><Name><ReturnTypeMangling>vg   // read-only or var getter
s:So<N><Name><ReturnTypeMangling>vs   // var setter
```
Deliberately never parses the return-type mangling -- only the exact `"vg"`/`"vs"` suffix, since the
real type varies freely (`String`, `Int`, `Int64`, ...).

**The critical discriminator, found during this fix's own design, not after shipping a bug**: real
Swift mangling is unambiguous by construction -- a nominal-type member's context always inserts a
marker character (`V`/`C`/`O`/`a`/`P`) immediately after the container type's own length-prefixed
name, before the member's own length-prefixed name. A plain top-level global has no such context, so
checking for the *absence* of a marker immediately after the first identifier -- not merely "ends in
vg/vs," which every member accessor also does -- is what's actually load-bearing here. Confirmed
against a real false-positive risk caught while designing this fix, not by a later review: a real,
genuine class instance property, `UISceneConnectionOptions.shortcutItem`
(`s:So24UISceneConnectionOptionsC12shortcutItemSo021UIApplicationShortcutE0CSgvg`), also ends in
`"vg"` -- a naive "just check the suffix" matcher would have wrongly treated it as an always-
nonisolated top-level constant, when in fact an ordinary class instance property's own isolation is
never something this project can assume without a live query. The `"C"` immediately following
`"UISceneConnectionOptions"` correctly identifies it as a class member and this type's own
`isTopLevelImportedConstant` correctly returns `false` for it.

Wired into `ExternalIsolationBackfill.collectEdgeLevelWorkItems` as a third pre-filter, after
`ImportedStructMemberMatching` -- zero live query on success, matching that type's own pattern (this
shape's isolation, unlike `BridgedExternClassConstantMatching`'s, is a fixed structural fact, not
something a live query result could vary).

5 new unit tests (`ImportedTopLevelConstantMatchingTests.swift`, including a dedicated regression
test for the `UISceneConnectionOptions.shortcutItem` false-positive risk and a rejection test
against every member-shaped sibling's own real USR) + 1 end-to-end test in
`ExternalIsolationBackfillTests.swift` asserting `sourceKitD.callCount == 0`.

## 5. Real `Project Iris` corpus, before/after

| | before | after |
|---|---|---|
| External oracle unknown | 1804 | **1630** (**-174**) |
| Cross-isolation edges (denominator) | 2236 | **1994** (**-242**) |
| Unresolved % | 32% | **24%** (**-8pp**) |

## 6. Status

**FIXED AND VERIFIED**, 6 new tests, real-corpus before/after above. The temporary probe executable
target used to confirm the "no attribute" hypothesis has been fully removed -- no trace in the final
diff.
