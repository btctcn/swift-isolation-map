# Task: resolve real isolation for symbols from compiled dependencies

**Status: shipped.** (This header originally read "not started" -- a task specification written
before the work began. Phases A-F below were fully implemented, tested (187/187,
`swift test -c release`), and real-world-validated against `Project Iris`; see
`docs/task-compiled-dependency-isolation-usr-granularity.md` and
`docs/task-compiled-dependency-isolation-performance.md` for what followed. Left unedited below as
the original problem statement.) Written after a real-world validation run against two independent
production codebases (`Project Iris`, `~/SQLumen`) surfaced this as a fundamental, not cosmetic, gap.
The user's own framing, verbatim, because it's the clearest statement of the problem: *"Это же
относится к любому базовому классу, который приходит из скомпилированного фреймворка. Есть
базовый класс, он скомпилирован, в проекте используется он сам или создаётся наследник. Бац, и у
нас нет инфы об этом классе по его изоляции."* The user explicitly rejected a partial/heuristic
fix: *"Меня интересует 100% полное решение этой проблемы. На меньшее я не согласен."* Whatever
this task produces must satisfy that bar — see "Definition of done" below, which is written to be
checked, not eyeballed.

## 1. The problem, precisely

`swift-isolation-map`'s entire isolation model is built from `SyntaxAnalysis.DeclarationExtractor`
— a `SwiftSyntax`-based parser that only ever sees `.swift` source text this tool itself
enumerates and reads (`StalenessOrchestration.swiftFiles`, recursive under the project directory).
When a project type's superclass or a protocol it conforms to is declared **outside** that source
set — a compiled dependency of any kind — `IsolationInferenceEngine.resolveInheritedIsolation`
looks up `declarations[superclassUSR]`/`declarations[protocolUSR]`, finds nothing, and the lookup
is skipped as if the relationship didn't exist. Resolution falls through to
`resolveDefaultIsolation`, which for anything not eligible for SE-0466 module-default isolation
(true for both real projects tested — see section 2) returns `.nonisolated` as the final,
unconditional fallback. **The tool cannot currently distinguish "provably not isolated" from "no
idea, the declaration isn't visible to us" — both produce the identical, confident-looking
`.nonisolated` answer**, which then feeds directly into `AnalysisReportBuilder.riskLevel` and can
manufacture a `high`-risk finding (`nonisolated` reaching `.actor`/`.globalActor`) that is, in
reality, not a cross-isolation boundary at all.

"Compiled dependency" is not a narrow category. It covers, uniformly:
- Apple's own SDKs (UIKit, AppKit, WatchKit, Foundation, ...).
- Pure-Swift first- or third-party frameworks shipped with library evolution
  (`-enable-library-evolution`, the mechanism behind `.swiftinterface` — SwiftUI, and any modern
  binary XCFramework or prebuilt SPM binary target).
- CocoaPods/vendored source that happens to sit *outside* whatever directory this tool recursively
  scans (not actually a distinct case technically, just a path-scoping bug risk — worth checking
  as part of this task, but the real, structural gap is the two categories above).
- Any binary-only framework with no textual interface artifact at all (see section 3, tier 3).

This is not a rare edge case for real Apple-platform codebases. Every `UIView`/`UIViewController`/
`UITableViewCell`/`NSView`/`NSViewController`/... subclass, and every `SwiftUI.View`/
`ObservableObject`/... conformance, hits it. In the `Project Iris` real-world run (section 2), this is
very likely responsible for a meaningful fraction of the 164 reported `high`-risk findings — the
true number of *real* cross-isolation risks in that codebase is currently unknown, because the
tool cannot yet tell the two apart.

## 2. Primary spike results (this session, all verified against a real toolchain/real projects, not assumed)

### 2.1 The triggering false positive, root-caused

`Project Iris/UI/News/Cells/NewsTableCell.swift:146` — `captionImageView.kf.indicatorType =
.activity`, called from `configure(withNews:)`, which the tool reports as `nonisolated`. Reported
by the tool as a `high`-risk edge (`nonisolated` → `globalActor(MainActor)`).

Real compiler ground truth, obtained empirically, not assumed:
```swift
// /tmp/concurrency-repro/repro2.swift
import UIKit
final class Wrapper { @MainActor var indicatorType: Int = 0 }
final class NewsCellRepro: UITableViewCell {
    let wrapper = Wrapper()
    func configure() { wrapper.indicatorType = 1 }   // no error
}
```
```
xcrun swiftc -swift-version 5 -sdk $(xcrun --show-sdk-path --sdk iphonesimulator) \
  -target arm64-apple-ios17.0-simulator -typecheck repro2.swift
# exit 0 — no diagnostics at all
```
Removing `UIKit`/`UITableViewCell` and using a plain `final class` superclass instead reproduces a
**hard compiler error** for the identical body (`main actor-isolated property 'indicatorType' can
not be mutated from a nonisolated context`). The only variable is the superclass. Root cause:
`UITableViewCell`'s real superclass chain is genuinely `@MainActor`, and the real compiler knows
it; this tool does not, because `UITableViewCell` has no `.swift` source in the project.

### 2.2 Two different concrete mechanisms exist for *why* the compiler knows, confirmed for both

**Mechanism A — Objective-C bridged frameworks (UIKit, AppKit, WatchKit): isolation lives in the
`.h` header, not in any Swift-parseable artifact.**
```
$ grep -n "@interface UITableViewCell" \
    "$(xcrun --show-sdk-path --sdk iphonesimulator)/System/Library/Frameworks/UIKit.framework/Headers/UITableViewCell.h"
80:UIKIT_EXTERN API_AVAILABLE(ios(2.0)) API_UNAVAILABLE(watchos) NS_SWIFT_UI_ACTOR
81:@interface UITableViewCell : UIView <NSCoding, UIGestureRecognizerDelegate>
```
`NS_SWIFT_UI_ACTOR` expands to `__attribute__((swift_attr("@MainActor")))` — a Clang attribute the
ClangImporter reads when bridging the class into Swift. **This is not a small, one-off
annotation**: `grep -rl NS_SWIFT_UI_ACTOR` over `UIKit.framework/Headers` matches **301 files**;
over `AppKit.framework/Headers`, **71**. Confirmed matches include both classes (`UIApplication`,
`UIButton`, `UICalendarView`, ...) and *protocols* (`UIAdaptivePresentationControllerDelegate`,
`UIActivityItemsConfigurationReading`, `UIBarPositioning`, ...) — so this mechanism covers both
superclass inheritance and protocol-conformance inference uniformly.
Critically: `UITableViewCell`'s *own* Swift-visible interface (`UIKit.swiftinterface`) contains
**no primary class declaration for it at all** — only `extension UITableViewCell { ... }` blocks
(confirmed: `grep -n UITableViewCell UIKit.swiftinterface` finds only extensions, never a `class
UITableViewCell` line). **This means a `.swiftinterface`-only fix cannot ever see this class's own
declaration or its `@MainActor`-ness — mechanism A's data genuinely does not exist in Swift-visible
form.**

**Mechanism B — pure-Swift frameworks with library evolution (SwiftUI and, in general, any modern
binary Swift dependency): isolation lives in real Swift syntax, in `.swiftinterface`.**
`~/SQLumen/SQLumen/UI/Workspace/WorkspaceView.swift:7` — `struct WorkspaceView: View` — `View` is
publicly documented, unambiguous Apple API to be `@MainActor`-isolated (its `body` requirement and
related members). `.swiftinterface` files for SwiftUI/SwiftUICore exist on-disk under the SDK
(`find $(xcrun --show-sdk-path --sdk macosx) -iname '*.swiftinterface'` locates them) and are real,
`SwiftSyntax`-parseable Swift source — in principle re-usable by the *existing*
`DeclarationExtractor` with zero new parsing code. (This session did not manage to grep the exact
`protocol View` declaration line inside the located `.swiftinterface` — worth 5 minutes of the next
session's time to pin down exactly, but the fact that `View` is `@MainActor` is not in doubt, and
the file format itself was confirmed to be ordinary parseable Swift.)

**These are two structurally different mechanisms with disjoint textual homes** (ObjC header macro
vs. Swift source attribute). Neither one's fix subsumes the other. A solution that only handles one
is not 100%.

### 2.3 IndexStoreDB was checked and confirmed to carry zero isolation information

```
find .build/checkouts/indexstore-db -iname '*.swift' | xargs grep -l 'MainActor\|isolat\|actor'
# no output — no match anywhere in IndexStoreDB's own Swift-facing API surface
```
This closes off "just read it from the index we already query" as an option — consistent with (and
now more thoroughly confirmed than) Phase 0's original finding that IndexStoreDB's symbol *kind*
can't even distinguish `actor` from `class`.

### 2.4 What's on this machine to build a real fix on top of

- `swift-ide-test` — **not present** in this Xcode 26.4.0 toolchain (`xcrun --find` fails, and it's
  absent from the whole `XcodeDefault.xctoolchain` tree). An older assumption (this tool used to
  ship and could `-print-module` a fully-resolved, attribute-annotated interface for *any* module,
  ObjC-bridged or not) does not hold on current toolchains. Do not assume it exists; re-check on
  whatever machine actually builds this.
- `sourcekitd`/`sourcekitdInProc` — **present**, as real `.framework`/dylib bundles under
  `XcodeDefault.xctoolchain/usr/lib/`. This is the same *class* of dependency as `libIndexStore`
  (already successfully `dlopen`'d and wrapped in Phase 0/`IndexStoreIntegration`), so this
  project already has a working precedent and pattern for depending on an Apple-shipped dylib this
  way.
- `sourcekit-lsp` — **present** as an actual, directly-invokable binary
  (`XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp`), confirmed runnable (`--help` succeeds). This
  is a real LSP server (JSON-RPC over stdio) — no `dlopen`/C-ABI bridging needed to talk to it, only
  a subprocess and a documented-ish protocol. sourcekit-lsp is exactly the thing Xcode's own Quick
  Help / hover uses to show "MainActor-isolated" for a symbol regardless of whether it came from
  ObjC-bridged or pure-Swift compiled code — because it resolves through the compiler's *actual*
  semantic model (post-ClangImporter, post-attribute-inference), not through re-deriving facts from
  raw header/interface text the way mechanisms A/B above do. **This is the single most promising
  candidate for a true, mechanism-agnostic, 100% answer**, and is the first thing the next session
  should spike empirically (send a `textDocument/hover` — or whatever the actual right LSP
  request turns out to be — for `UITableViewCell` and separately for `SwiftUI.View`, from one
  running `sourcekit-lsp` process, and confirm the response text actually surfaces MainActor
  isolation for both, before designing anything around it).

## 3. What "100% solution" must mean (per explicit user instruction, not a suggestion)

The user was explicit: partial/heuristic coverage is not acceptable as the final state. A
**falsifiable** definition of done, not a vibe:

For **any** symbol a project's own analyzed declarations reference as a superclass, protocol
conformance, or (later, if in scope) any other isolation-relevant relationship — regardless of
whether that symbol's declaration lives in:
1. This tool's own analyzed source (already correct, unchanged, Priority 1 baseline),
2. An Objective-C-bridged compiled framework (mechanism A),
3. A pure-Swift compiled framework with a `.swiftinterface` (mechanism B),
4. A binary-only framework with **no** textual interface artifact at all (unexplored territory —
   see below, not yet confirmed solvable or unsolvable),

...the tool must resolve that symbol's **real** isolation, matching what `swiftc` itself would
enforce, not an approximation, a name-based guess, or a per-framework special case list. A
mechanism that hard-codes "these ~300 UIKit names, these ~70 AppKit names" is explicitly **not**
sufficient on its own — it is neither complete (misses anything Apple adds/renames, misses every
third-party framework, misses case 4 entirely) nor principled (re-derives, by hand, information the
compiler already has authoritatively). If used at all, it may only be as a fast-path/cache in front
of a real, general oracle — never as the sole source of truth.

**Case 4 must be genuinely investigated, not assumed impossible.** This session provisionally
called it "genuinely unsolvable by static text scanning" — but that conclusion was reached while
only considering *text* artifacts (headers, `.swiftinterface`). A compiled `.swiftmodule` (the
actual binary form every Swift dependency ships, with or without a human-readable
`.swiftinterface`) contains full serialized semantic information, including attributes — that's
what powers Xcode's autocomplete/quick-help even for such dependencies. Whether `sourcekitd`/
`sourcekit-lsp` can recover isolation from a `.swiftmodule`-only dependency (no `.swiftinterface`,
no ObjC header) is an open, unverified question the next session must answer empirically before
this task can be declared complete or a documented permanent limitation.

### Definition of done (concrete, checkable)

1. A design decision, made only after empirically spiking the sourcekitd/sourcekit-lsp route (and
   any other candidate that surfaces during that spike) against real symbols from **both**
   mechanism A and mechanism B, plus at least one attempt at a case-4 (`.swiftmodule`-only, no
   `.swiftinterface`, no ObjC header) dependency — a synthetic one can be built on purpose
   (`swift build -enable-library-evolution` off, or deliberately strip the `.swiftinterface`) if a
   real-world example isn't handy.
2. An integration point that plugs into the existing architecture without regressing it:
   `IsolationInferenceEngine` (unmodified since Priority 1, a deliberate stability invariant this
   project has maintained throughout — touching it is a real decision, not a formality) either
   stays untouched with the new data backfilled at the `DeclarationLinker` layer (this project's
   existing precedent for exactly this shape of problem — see its `protocolGlobalActorName`
   cross-file backfill), or is extended deliberately and explicitly, with the same rigor as every
   prior engine-adjacent change in this project (full test coverage, documented in a `docs/*.md`
   record, not silently).
3. A new golden-fixture test exercising the real thing end to end: a real project (or a minimal,
   purpose-built fixture, mirroring this project's existing `Tests/Fixtures/*` convention) that
   subclasses/conforms to a real compiled-dependency type from **each** of mechanisms A and B (at
   minimum: a `UIView`/`UITableViewCell`-style ObjC-bridged case, and a `SwiftUI.View`-style
   pure-Swift case), asserting the tool's resolved isolation matches real `swiftc` behavior
   (provable the same way section 2.1's repro proved the current wrong answer — a paired "does
   this actually compile / does it actually error" check, not just an assertion against the tool's
   own output).
4. Re-running the exact two real-world commands this session used
   (`Project Iris` with Project Iris's scheme, `~/SQLumen` with scheme `SQLumen`, both `--output json`)
   and diffing the `high`-risk finding count/contents before and after — confirming the fix
   demonstrably changes real output on real, previously-tested projects, not just fixture output.
5. If case 4 (truly no textual/binary-introspectable interface at all — should be rare to
   nonexistent for anything actually consumable as a Swift dependency, but must be confirmed, not
   assumed) turns out to have **no** possible mechanism, that must be written up as an explicit,
   evidenced, permanent limitation (this project's established "close what's closable, document the
   rest" discipline — see `docs/isolation-rules.md`'s Gap A/B/C history for the precedent) — not
   silently absent from the final design.

## 4. Relevant existing architecture (context for whoever picks this up)

- `Sources/SyntaxAnalysis/DeclarationExtractor.swift` — the only current source of `DeclarationInfo`
  facts; reusable as-is for parsing `.swiftinterface` text (mechanism B), since that's ordinary
  Swift syntax.
- `Sources/IndexStoreIntegration/DeclarationLinker.swift` — existing backfill precedent
  (`protocolGlobalActorName`, cross-file); the natural integration point for "resolve this
  unresolved external superclass/protocol from an external oracle" if that path is chosen over
  touching the engine directly.
- `Sources/IsolationCore/IsolationInferenceEngine.swift` — unmodified since Priority 1; any change
  here is a first for this project and must be weighed deliberately, not incidentally.
- `Sources/swift-isolation-map/StalenessOrchestration.swift` — currently the only place that
  decides which `.swift` files exist "in scope"; will very likely need a parallel/related mechanism
  for "which external modules are actually referenced and need their compiled-dependency isolation
  resolved," probably driven by each file's own `import` statements (already syntactically visible,
  though not currently captured as structured data anywhere — check `FileWideNameCollector`) plus
  the active SDK/toolchain paths (not currently captured anywhere — today only `SWIFT_VERSION`/
  `tools_version` and the raw compiler version are resolved, see
  `Sources/swift-isolation-map/SwiftVersionDetection.swift`; `SDKROOT`/target triple resolution is
  new work).
- `Sources/swift-isolation-map/AnalysisReportBuilder.swift` — `riskLevel`'s behavior is a direct,
  automatic consumer of whatever this task produces; no changes anticipated there, but worth
  re-reading its doc comment (already documents the risk heuristic's own honest limitations) before
  starting, since the fix this task produces is exactly what closes one of those documented gaps.

## 5. Explicitly out of scope for this task (do not silently expand into these)

- Detecting `@unchecked Sendable`/`nonisolated(unsafe)` escape hatches — a separate, already
  documented v0.2+ gap (see `AnalysisReportBuilder`'s own doc comment), unrelated to this problem.
- Any change to the risk heuristic's *classification logic* itself (`high`/`medium`/`low`) — this
  task's success criterion is that inputs to that heuristic become correct for compiled-dependency
  cases; the heuristic itself is not what's broken.
