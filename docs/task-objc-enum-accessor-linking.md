# `@objc` enum synthesized-accessor matching, plus a deeper root cause found underneath it

Follow-up: [issue #95](https://github.com/btctcn/swift-isolation-map/issues/95) tracks the deeper
root cause (§3 below) as a separate, not-yet-scoped task.

## 1. Context

Continuing from `docs/task-subscript-and-compressed-constant-matching.md`'s §5, which explicitly
set aside the `Mindbox`/`MindboxLogger`/`DeviceKit` CocoaPods cluster as "a `DeclarationLinker`-level
gap ... a structurally different, deeper class of investigation" rather than guess at it. This task
picks that investigation back up.

## 2. Finding: a top-level `@objc` enum links under its Clang USR, not its Swift-mangled USR

Checked via a real, from-scratch minimal reproduction (`MiniObjCEnum`, a plain macOS SPM package):

```swift
@objc
public enum LogLevel: Int, CaseIterable {
    case debug = 0
    case info = 1
}
```

`linked.declarations`'s own entry for this enum is keyed by its **Clang-style USR**
(`c:@M@MiniObjCEnum@E@LogLevel`), confirmed exactly -- not the Swift-mangled form
(`s:12MiniObjCEnum8LogLevelO`) that `SynthesizedEnumAccessorMatching.enclosingEnumUSR` derives.
`DeclarationLinker`'s own disambiguation picks the Clang-style candidate over the Swift-mangled one
when both exist as real index-store candidates at the enum's declaration site -- a real,
`@objc`-specific asymmetry, distinct from every plain (non-`@objc`) enum shape the existing
`enclosingEnumUSR` already covers.

**Fix**: `SynthesizedEnumAccessorMatching.enclosingObjCEnumUSR(forSynthesizedAccessorUSR:)`, a
sibling to the existing `enclosingEnumUSR` (not a modification -- the existing function's own
grammar is real, shipped, independently-tested behavior for its own confirmed shape). Still parses
the accessor's own Swift-mangled USR (module + type name + accessor shape, reusing the existing
`accessorShapes` table), but emits the Clang USR form (`c:@M@<Module>@E@<EnumName>`) instead.
Deliberately scoped to a **top-level** enum only (module immediately followed by one bare type name,
no nested-context prefix) -- a nested `@objc` enum's own Clang USR form has not been verified against
real evidence, so no claim is made about it (`rejectsNestedEnumShape` locks this in).

Verified against the real corpus's own USR too:
`enclosingObjCEnumUSR("s:13MindboxLogger8LogLevelO8rawValueSivg") == "c:@M@MindboxLogger@E@LogLevel"`.

## 3. The deeper root cause: bare-name `syntactic:<Name>` placeholder collisions in `usrRewriteMap`

The fix above is correct and verified in isolation, but produced **zero measurable change** against
the real `Project Iris` corpus (unknown stayed 1573→1573, unresolved edges stayed 106→106). Direct
inspection of the corpus JSON confirmed `c:@M@MindboxLogger@E@LogLevel` never appears as a linked
node at all -- so the hypothesis was correct as a general fact, but didn't explain the real corpus's
own symptom.

Instrumented `DeclarationLinker.buildUSRRewriteMap` with a temporary, env-var-gated debug print
(`SWIFT_ISOLATION_MAP_DEBUG_LINK=LogLevel`, reverted before this commit) and re-ran against the real
corpus. Result -- three distinct `DeclarationInfo` entries, all sharing the identical bare-name
placeholder USR `"syntactic:LogLevel"`:

```
[link-debug] name=LogLevel usr=syntactic:LogLevel location=.../Pods/MindboxLogger/MindboxLogger/Shared/Group/LogLevel.swift:23:13 candidates=["c:@M@MindboxLogger@E@LogLevel(LogLevel)"]
[link-debug] name=LogLevel usr=syntactic:LogLevel location=nil candidates=[]
[link-debug] name=LogLevel usr=syntactic:LogLevel location=.../lsboutique/Models/LogLevel.swift:12:13 candidates=["s:9Ls_net_ru8LogLevelO(LogLevel)"]
```

The real app itself declares its own, completely unrelated `LogLevel` enum
(`lsboutique/Models/LogLevel.swift`), which collides with the `MindboxLogger` pod's own `LogLevel`
purely by sharing a bare name. `SyntacticIdentity`'s placeholder USR for a top-level type is just
`"syntactic:<Name>"`, with no file or module qualification. `buildUSRRewriteMap` builds
`usrRewriteMap` as a single flat `[String: String]` keyed by this placeholder, so `disambiguate`
succeeding independently and correctly for *each* of the three entries at *its own* declaration site
doesn't matter -- the last write to `usrRewriteMap["syntactic:LogLevel"]` during iteration wins for
*all three*, including the pod's own `LogLevel` type declaration itself. This silently redirects the
pod's own enum (and everything under it, like the `rawValue` accessor this task started from) to
whichever of the three candidates happened to be processed last -- never actually producing a
`linked.declarations` entry under `c:@M@MindboxLogger@E@LogLevel` at all, which is exactly why §2's
fix measured zero real-corpus impact despite being correct.

This is `DeclarationLinker`'s own pre-existing, already-documented limitation (referenced in
`ExternalIsolationBackfill.swift`'s own top-of-file doc comment and the `resolveSyntacticPlaceholderNeeds`
sequential-fallback mechanism) -- not a new discovery of the mechanism itself, but this is the first
time it's been traced to a specific, real, reproducible corpus symptom.

## 4. Status and next step

**Shipped this task**: `enclosingObjCEnumUSR`, tested (4 new unit tests + 1 end-to-end test, 463/463
suite passing). Real capability, verified correct for its own confirmed shape (a top-level `@objc`
enum with no name collision) -- kept because it is correct, even though it does not resolve
`MindboxLogger.LogLevel` specifically.

**Not shipped, deliberately set aside for a follow-up task**: a real fix for the placeholder
collision itself. Unlike every other fix in this investigation (an additive, narrow matcher plugged
into `ExternalIsolationBackfill`'s own pre-filter/fallback chains), resolving this requires qualifying
`SyntacticIdentity`'s own placeholder USR scheme (e.g. by file or module) -- a change to
`DeclarationLinker`'s own core, shared linking logic, touching every syntactic-placeholder call site,
not a narrow addition. Flagged as a distinct category of change, to be scoped and investigated
separately.
