# A concrete class's own Clang selector for a property it only witnesses via protocol conformance

## 1. Context

Continuing from `docs/task-imported-top-level-constant-isolation.md`'s §5 baseline (real
`Project Iris` corpus, 24% of cross-isolation edges unresolved): the next cluster was
`UITextField`'s own selector-based accessors -- `setKeyboardType:`, `setAutocorrectionType:`,
`setSecureTextEntry:`, `hasText`, `isSecureTextEntry`, and more -- none of them Swift-mangled at
all, already plain Clang selector USRs (`c:objc(cs)UITextField(im)setKeyboardType:`) the way
`RawIndexStoreClient`'s existing `@CM@`-qualifier stripping handles for a *different*, already-
covered shape.

## 2. Root cause

`UITextField` doesn't declare `keyboardType`/`autocorrectionType`/`secureTextEntry`/`hasText`
itself -- it only **witnesses** them via conformance to Objective-C protocols
(`UITextInputTraits`, `UIKeyInput`). Both `symbolgraph-extract`'s own bulk output and a live
`cursorinfo` hover at the exact call site key such a member by its **protocol-declared** USR
(`c:objc(pl)UITextInputTraits(py)keyboardType`) -- never by the concrete witnessing class's own
selector-qualified form (`c:objc(cs)UITextField(im)setKeyboardType:`) the call graph's own
`calleeUSR` actually carries.

## 3. Checked via a real, from-scratch minimal reproduction, not assumed

Per this session's established discipline: built a real iOS SPM package (`xcodebuild -scheme
...-Package -destination 'generic/platform=iOS Simulator'`, since a plain `swift build` can't
target iOS UIKit directly) with a `UITextField` subclass exercising `keyboardType`/
`autocorrectionType`/`secureTextEntry`/`hasText` in both getter and setter form, confirmed the
exact same `isUnknown` shape reproduces, then queried live `cursorinfo` directly (temporary
`CursorInfoProbe` executable target, fully reverted) at each real call site.

**A genuine, load-bearing finding from this probe, not assumed by analogy**: the naive "derive the
property name by stripping `set`/lowercasing" transformation
(`BridgedExternClassConstantMatching`'s own working pattern for a *different* shape) does **not**
reliably reproduce the real Swift-visible property name here. `setSecureTextEntry:`'s own selector
strips to `"secureTextEntry"`, but the real live-hovered candidate's own `key.name` at that exact
setter call site is `"isSecureTextEntry"` (the `is`-prefixed boolean-getter convention, which
Objective-C's own setter selector never doubles). This asymmetry is real, confirmed directly, not a
hypothetical edge case: it's the exact shape of `UITextField.isSecureTextEntry` itself.

## 4. Fix

New `Sources/SourceKitDIntegration/ObjCProtocolPropertyWitnessMatching.swift`. Deliberately never
parses or compares the member's own name at all, for the reason above -- the live query already
runs at the exact position the original call-graph edge itself recorded, which sourcekitd and the
index-store's own occurrence necessarily agree describes the *same* declaration; only the
declaration's own kind (genuinely Clang, genuinely a protocol property) and its container
(matching the concrete type `targetUSR` itself names) are cross-checked:

```
targetUSR shape:  c:objc(cs)<TypeName>(im)<AnySelector>   -- only <TypeName> is ever parsed
match criterion:  candidate.declLang == "source.lang.objc"
                   && candidate.usr.hasPrefix("c:objc(pl)")
                   && candidate.usr.contains("(py)")
                   && candidate.containerTypeUSR == "$sSo<N><TypeName>CD"
```

The container-type-USR shape (`"$sSo11UITextFieldCD"`, confirmed against the real probe) is a
different suffix (`"D"`, a nominal type descriptor for an *instance* member) from
`BridgedExternClassConstantMatching`'s own `"CmD"` (a *static* member's metatype accessor),
consistent with every real example here being an instance property.

Wired into `ExternalIsolationBackfill.query()`'s existing fallback chain, after
`BridgedExternClassConstantMatching`. Deliberately excludes project-local Clang-Module-qualified
selectors (`c:@CM@<Module>@objc(cs)...`/`c:@M@<Module>@objc(cs)...`) -- `RawIndexStoreClient`'s own
separate, already-existing domain, never double-handled here.

13 new unit tests (`ObjCProtocolPropertyWitnessMatchingTests.swift`), including a dedicated
regression test for the `isSecureTextEntry` asymmetric-boolean-setter case and a rejection test for
a genuine class-owned (non-protocol) property, which must stay outside this type's own domain +
1 end-to-end test in `ExternalIsolationBackfillTests.swift`.

## 5. Real `Project Iris` corpus, before/after

| | before | after |
|---|---|---|
| External oracle unknown | 1630 | **1609** (**-21**) |
| Cross-isolation edges (denominator) | 1994 | **1939** (**-55**) |
| Unresolved % | 24% | **22%** (**-2pp**) |

Confirmed directly against the real corpus's own `nodes` list: every `UITextField(im)...` selector
this fix targets (`setKeyboardType:`, `setSecureTextEntry:`, `hasText`, `isSecureTextEntry`, and
more) now resolves to `globalActor(MainActor)`, matching UIKit's real, documented convention for
`UITextInputTraits`/`UIKeyInput`.

## 6. Status

**FIXED AND VERIFIED**, 14 new tests, real-corpus before/after above. The temporary iOS mini-repro
package and `CursorInfoProbe` executable target used to confirm the real behavior have been fully
removed -- no trace in the final diff.
