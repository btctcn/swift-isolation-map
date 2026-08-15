# Bulk extraction resolves to a platform whose build products don't exist

## 1. Context

While auditing residual `isUnknown` edges on a real, ~2200-file corpus (`~/ios/lsboutique.xcworkspace`,
scheme `ls.net.ru`) after PR #86, a fresh `--force-reindex` run showed a much higher `isUnknown` rate
than expected (73%, 3972/5595 edges), with the run's own log containing real `xcodebuild` compile
errors:

```
/Users/ab/ios/Pods/Cartography/Cartography/LayoutGuide.swift:27:8: error: no such module 'AppKit'
/Users/ab/ios/Pods/Kingfisher/Sources/Extensions/HasImageComponent+Kingfisher.swift:76:8: error: no such module 'WatchKit'
/Users/ab/ios/Pods/PromiseKit/Extensions/Foundation/Sources/Process+Promise.swift:46:38: error: cannot find 'launchPath' in scope
/Users/ab/ios/Pods/SwiftRichString/Sources/SwiftRichString/Support/Extensions.swift:133:18: error: cannot find type 'NSImage' in scope
```

These are real macOS-only code paths in genuinely cross-platform CocoaPods (Cartography, Kingfisher,
SwiftRichString all ship `#if os(macOS) import AppKit #elseif os(iOS) import UIKit`-style guards)
being taken even though this project only ever gets built for iOS. This doc records the confirmed part
of the investigation and the part that is still open.

## 2. Confirmed: `LiveXcodeBulkExtractionEnvironmentProvider` doesn't pin a destination

`Sources/ProjectResolution/BulkExtractionEnvironmentProviding.swift`'s
`LiveXcodeBulkExtractionEnvironmentProvider.environment()` runs:

```
xcodebuild -showBuildSettings -scheme <scheme> -workspace <path>
```

with **no `-destination`** at all -- unlike `LiveXcodeCompilerArgumentsProvider.runVerboseBuild`
(`Sources/ProjectResolution/XcodeBuildLogCompilerArgumentsProvider.swift`), which explicitly resolves
one via `resolveDeterministicSimulatorDestination` before every real `xcodebuild ... build` it runs.
That function's own doc comment already documents the exact failure mode this hits:

> Confirmed against a real host analyzing a real project (`Swiftfin`): a physical iPhone paired to
> the machine at some point in the past but not currently connected (`ab iphone x`) sorted ahead of
> every Simulator destination in `-showdestinations`. With no `-destination` passed, `xcodebuild
> build` silently built for `Debug-iphoneos` instead of `Debug-iphonesimulator`.

Confirmed directly against this same real corpus, same machine:

```
$ xcodebuild -showdestinations -scheme ls.net.ru -workspace lsboutique.xcworkspace
    { platform:iOS, id:..., name:ab iphone x, error:ab iphone x is not connected ... }
    { platform:iOS, id:...placeholder, name:Any iOS Device }
    { platform:iOS Simulator, id:...placeholder, name:Any iOS Simulator Device }
    { platform:iOS Simulator, arch:arm64, id:..., OS:26.4, name:iPhone 17 Pro }

$ xcodebuild -showBuildSettings -scheme ls.net.ru -workspace lsboutique.xcworkspace | grep -E "PLATFORM_NAME|SDKROOT|FRAMEWORK_SEARCH_PATHS"
    PLATFORM_NAME = iphoneos
    SDKROOT = .../iPhoneOS.platform/Developer/SDKs/iPhoneOS26.4.sdk
    FRAMEWORK_SEARCH_PATHS = .../Build/Products/Debug-iphoneos ".../Debug-iphoneos/Cartography" ".../Debug-iphoneos/Kingfisher" ...
```

The actual real build on this machine only ever produces `Build/Products/Debug-iphonesimulator`
(confirmed: `Build/Products/Debug-iphoneos` does not exist on disk at all). So every
`FRAMEWORK_SEARCH_PATHS` entry `discoverFrameworks` is given points at a directory that was never
built -- not "the wrong platform variant" in an architectural sense (a module's `@MainActor`-style
isolation attributes don't differ between device and simulator builds of the same iOS SDK), but a
configuration whose build products simply don't exist on this machine.

Confirmed this is real and reproducible, not cosmetic: running the tool's own
`swift symbolgraph-extract` invocation with these exact (wrong) settings against `Cartography`
fails immediately:

```
$ xcrun swift symbolgraph-extract -module-name Cartography -sdk <iPhoneOS SDK> -target arm64-apple-ios15.6 \
    -F ".../Build/Products/Debug-iphoneos/Cartography" -output-dir /tmp/x -minimum-access-level public
Couldn't load module 'Cartography' in the current SDK and search paths.
```

`extract()`'s existing fail-soft contract (`guard result.exitCode == 0 else { return empty }`) means
this doesn't crash -- it silently means **every third-party CocoaPods module's bulk pre-resolution is
entirely disabled** for this project on this machine, forcing all of their symbols through the slower
live-query path instead of the fast bulk cache. `FrameworkModuleDiscovery.discoverFrameworks` only
looks for `.framework` bundles, so pure-source pods like Cartography/Kingfisher/SwiftRichString/
PromiseKit are the ones affected -- confirmed they aren't even *found* under the (wrong) search paths in
the first place (no `.framework` bundle exists there at all), so this specific mechanism cannot be
the source of the `AppKit`/`WatchKit` compile-error text quoted above (see §3).

### Fix direction

Give `LiveXcodeBulkExtractionEnvironmentProvider.environment()` the same destination pinning
`LiveXcodeCompilerArgumentsProvider.runVerboseBuild` already has: resolve via
`resolveDeterministicSimulatorDestination(container:scheme:processRunning:)` and pass `-destination`
to the `-showBuildSettings` invocation before parsing `FRAMEWORK_SEARCH_PATHS`/`SDKROOT`/`ARCHS`. Not
yet implemented in this session -- flagged here first since it's independent of the still-open
mystery in §3.

## 3. Not found: the actual source of the `AppKit`/`WatchKit` compile errors

The above bug is real and worth fixing, but confirmed **not** to be the source of the literal
`no such module 'AppKit'`/`'WatchKit'` compile errors observed in the real run log (real `Pods/...`
file:line references, e.g. `Pods/Cartography/Cartography/LayoutGuide.swift:27:8`).

**The errors are fully deterministic, not flaky.** Every unmodified run against this same corpus
produced the exact same shape of result: `3344 resolved, 887{0,1,2,4} conformance(s) updated, 2583
unknown` (the low-order digit of the conformance count moved by ±2 between runs -- real, harmless
scheduling-order noise in an unrelated code path, not evidence of instability in the mechanism that
matters here) and `4084/5595 (73%)` edges left with unresolved isolation. No amount of environmental
cleanup changed this outcome even slightly, which is itself informative: whatever causes this is a
property of this project's real build configuration + this tool's own code, not of transient host
state.

**Confirmed, via direct instrumentation added to the real code and removed afterward (not guessed),
that neither of the two subprocess-heavy phases inside `ExternalIsolationBackfill.resolve` is the
source:**

1. `LiveXcodeCompilerArgumentsProvider`'s own `xcodebuild -verbose ... clean build` -- dumping its
   real, full captured `stdout`/`stderr` to disk showed `exitCode=0` and **zero** `AppKit`/`WatchKit`
   text in its own output, on a run that *still* went on to produce the familiar errors later.
2. `BulkSymbolGraphExtractor.extract` (bulk `xcrun swift symbolgraph-extract`, both for the
   hardcoded SDK-module list and for `discoveredModules`) -- dumping every real invocation's exact
   arguments and full output showed only the 9 hardcoded SDK modules were even attempted (no
   third-party pod was discovered at all, confirming §2's bug independently), `AppKit`'s own attempt
   failed with the expected, harmless `Couldn't load module 'AppKit' in the current SDK and search
   paths` (no `Pods/...` reference), and every other module succeeded.

**Directly proven, via the existing `SWIFT_ISOLATION_MAP_WORKER_STDERR=1` diagnostic flag (PR #85,
no new code needed), that the errors originate from an oracle worker's own process** -- the real log
line reads:

```
[worker 0 stderr] /Users/ab/ios/Pods/Cartography/Cartography/LayoutGuide.swift:27:8: error: no such module 'AppKit'
```

The `[worker 0 stderr]` prefix is `OracleWorker.runWorker`'s own forwarding of a worker subprocess's
real `stderr` -- meaning worker 0's own in-process `sourcekitd` (`SourceKitDClient`, driven by
`sourcekitdInProc`) is genuinely trying to build an AST for `Cartography/LayoutGuide.swift` using the
per-file compiler arguments it was handed, and that AST build is producing real, correctly-formatted
Swift compiler diagnostics -- meaning `sourcekitd` really is taking the `#if os(macOS)` branch of this
file's conditional imports, despite the arguments it was given targeting `arm64-apple-ios15.6-simulator`/
`x86_64-apple-ios15.6-simulator` (both confirmed correct and, individually, sufficient for a plain
`swiftc`/`swift-frontend` invocation to compile this exact file successfully -- see below).

**Ruled out, with a concrete, real command extracted from the tool's own captured build log and run
by hand:** the captured per-file arguments themselves aren't wrong. `Cartography/LayoutGuide.swift`
is compiled *twice* in the real build (`generic/platform=iOS Simulator` builds both `arm64` and
`x86_64` slices for a fat simulator binary) -- `CompilerArgsLogParser`'s `parsed[file] = fullArguments`
dictionary means whichever invocation is parsed last silently wins for that file path, a real latent
correctness gap, but not the cause here: extracting the *exact*, real, full `x86_64` compile line from
the captured build log (5555 characters, including `-target x86_64-apple-ios15.6-simulator`,
`-sdk .../iPhoneSimulator26.4.sdk`, and `-explicit-module-build`) and running it directly via `eval`
compiled successfully with real `swift-frontend` output, no error.

**Tried and reverted (broke nothing, fixed nothing):** `key.compilerargs` must be driver-style
arguments (see `CompilerArgumentsSanitizing`'s own doc comment), and that sanitizer already strips one
other driver-only flag (`-incremental`) specifically because `sourcekitd`'s own `ASTInvocation` builder
rejects it. `-explicit-module-build` looked like an extremely strong match for the same shape of bug --
it's a driver-only flag whose real effect (having `swiftc` run its own dependency scan and hand
`swift-frontend` a generated, ephemeral `-explicit-swift-module-map-file`) `sourcekitd` never performs
itself. Added it to `CompilerArgumentsSanitizing.frontendOnlyFlags` and re-ran against the real corpus:
**no change at all** -- `3344 resolved, 8871 conformance(s) updated, 2583 unknown`, all 7 `AppKit`/
`WatchKit` errors still present. Reverted (`git checkout --`) rather than leaving an unproven,
ineffective change in the tree.

Hypotheses tested and ruled out this session (each via a real, isolated reproduction, not guessed):

- Two `xcodebuild` invocations running back-to-back within one `--force-reindex` run racing on shared
  state -- ruled out: reproduced with `--force-reindex` omitted (single `xcodebuild` invocation total),
  errors persisted.
- `COMPILER_INDEX_STORE_ENABLE=YES` specifically -- ruled out: a manual `xcodebuild ... build` with this
  setting set succeeded cleanly.
- Wrong working directory (`LiveProcessRunner.run(..., workingDirectory: nil)` inherits the tool's own
  cwd, not the project's) -- ruled out: a manual repro launched from the tool's own cwd succeeded
  cleanly.
- A stray, long-lived `sourcekit-lsp`/`SourceKitService` pair (PID 45190/45196, running since Jul 27,
  `cwd=/Users/ab/ios`, found to have macOS-SDK `.swiftmodule`s open) interfering with the real build --
  ruled out: killing both processes and re-running still reproduced the errors.
- `xcodebuild ... clean build` as one combined invocation (never tested manually before, since
  `LiveXcodeCompilerArgumentsProvider`'s retry path does exactly this) -- ruled out: a manual `clean
  build` with otherwise-identical arguments succeeded cleanly.

- The shared, per-user Clang module cache (`/private/var/folders/.../C/clang/ModuleCache/`, **not**
  scoped to this project's `DerivedData`) had genuinely accumulated stale `.pcm` files from the same
  stray `sourcekit-lsp` session above (its own macOS-targeted precompiled modules, confirmed via
  `lsof`). The user fully cleared it (2031 subdirectories, ~358MB) and the tool was re-run -- ruled
  out: identical errors, identical `3344/8872/2583` stats.

Ten hypotheses tested this session; all ten ruled out via a real, isolated reproduction (never merely
argued from documentation or by analogy). The mechanism is proven narrowed to a specific place --
worker-process-local, in-process `sourcekitd` AST building for these specific files, using arguments
that are individually correct and individually sufficient for a plain `swift-frontend` invocation to
succeed -- without a confirmed explanation for *why* `sourcekitd`'s own AST build takes the `#if
os(macOS)` branch when a hand-run `swift-frontend` invocation with the same arguments does not. The
gap between "proven where" and "proven why" is real and unclosed as of this doc.

## 5. Found: `DeclarationExtractor` is platform-blind to `#if`/`#elseif`

Root-caused via a minimal, isolated, fully reproducible test case -- not guessed.

Real corpus, real oracle-worker query dump (`SWIFT_ISOLATION_MAP_DEBUG_QUERYARGS`, temporary
instrumentation) captured every single live query one real worker process issued, in exact order,
across a genuinely clean rebuild. Bisecting that real sequence by replaying prefixes of increasing
length through the standalone `--oracle-worker-input`/`--oracle-worker-output` entry point (a real,
existing code path, not a new harness) found the exact trigger: query #154 in the real sequence
(`Pods/Cartography/Cartography/LayoutGuide.swift:22:17`) succeeds; query #155
(`Pods/Cartography/Cartography/LayoutGuide.swift:36:17` -- the **same file**) is the one that fails.
Reduced further: a **single, fresh, first-ever query** at `LayoutGuide.swift:36:17`, with nothing
before it in the process, reproduces `error: no such module 'AppKit'` on its own -- ruling out any
carryover/state-corruption theory (§3's two-independent-source concern about a long-lived worker
carrying state between queries): it isn't cumulative, it's this *specific position*.

`LayoutGuide.swift`'s real source:

```swift
#if os(iOS) || os(tvOS)
import UIKit
...
extension UILayoutGuide: LayoutItem {
    public func asProxy(context: Context) -> LayoutGuideProxy { ... }   // line 21
}
#elseif os(OSX)
import AppKit
...
extension NSLayoutGuide: LayoutItem {
    public func asProxy(context: Context) -> LayoutGuideProxy { ... }   // line 36
}
#endif
```

Line 36 -- the `#elseif os(OSX)` branch's own `asProxy(context:)` -- is genuinely dead code for an
iOS build; a real compiler never includes it in the program at all. But `SyntaxAnalysis.
DeclarationExtractor` walks the file with a plain SwiftSyntax `SyntaxVisitor` (confirmed by reading
`Sources/SyntaxAnalysis/DeclarationExtractor.swift`: no `override func visit(_: IfConfigDeclSyntax)`,
no `IfConfigClauseSyntax` handling anywhere in the file) -- SwiftSyntax itself is a pure, lossless
syntax tree with **no `#if` evaluation at all**, so a default `SyntaxVisitor` walks into *every*
clause's body unconditionally, `#elseif`/`#else` included. This project's own declaration/call-graph
extraction therefore finds `asProxy(context:)` **twice** in this file -- once real (line 21), once
phantom (line 36) -- and generates a live-oracle work item for the phantom one exactly like any real
declaration.

`sourcekitd`'s own `cursorinfo`, asked to hover a source offset that falls inside an *inactive*
`#if`/`#elseif` region, doesn't just report "nothing here" -- it appears to still attempt a real,
semantic build treating that region as live (plausibly the same mechanism that lets Xcode's editor
offer syntax highlighting/completion inside a currently-false `#if` block), which means it evaluates
*that* branch's own `import AppKit`, against the real iOS SDK, for real -- and that import genuinely
fails, producing exactly the diagnostic text observed throughout this whole investigation.

This is real, structural, and **general** -- not specific to `Cartography` or to this corpus. Any
third-party dependency with `#if os(X) ... #elseif os(Y) ... #endif`-style cross-platform code (a
very common pattern in shared/multi-platform libraries: Kingfisher, SwiftRichString, and PromiseKit
all confirmed to follow the identical shape) will have this project's own declaration extraction
generate phantom work items for every platform branch *other* than the one actually being analyzed,
each one a live-query call that can spuriously fail and propagate `unknown` outward via this
project's own containingType-member/edge propagation. This plausibly accounts for a large share of
the residual `isUnknown` rate on real, dependency-heavy corpora generally, not just the specific
`AppKit`/`WatchKit` text chased in §3.

### Fix -- implemented, tested, verified against the real corpus

Every `SyntaxAnalysis` `SyntaxVisitor` subclass (5 total, confirmed by grepping the whole `Sources/`
tree -- not assumed to be the one this investigation happened to trip over: `DeclarationExtractor`'s
two nested `Visitor`s plus its own `DeclarationVisitor`, `ClosureIsolationExtractor.Visitor`,
`AwaitedCallSiteExtractor.Visitor`) now subclasses `SwiftIfConfig.ActiveSyntaxVisitor` instead of
plain `SwiftSyntax.SyntaxVisitor`. `ActiveSyntaxVisitor` was chosen over the other real candidate,
`SyntaxProtocol.removingInactive(in:)` (a `SyntaxRewriter` that excises inactive regions from the
tree): rewriting shifts every remaining node's byte offset/line/column relative to the real file on
disk, which would have broken every `SourceLocationConverter`-derived `DeclarationInfo.location` this
project's whole pipeline depends on downstream. `ActiveSyntaxVisitor` walks the *original*, unmodified
tree, just skipping an inactive `#if`/`#elseif` clause's children -- zero position drift.

`SyntaxAnalysis.PlatformBuildConfiguration` (new file) conforms to `SwiftIfConfig.BuildConfiguration`
and answers exactly two axes with real data, permissively (`true`, "assume active") everywhere else --
deliberately narrow, not a full compiler-config re-implementation (see the type's own doc comment for
the two concrete reasons: this real corpus's own dual-architecture `arm64`+`x86_64` simulator build
would make a single hardcoded `arch(...)` answer *wrong* for one of the two, and only `os(...)`/
`canImport(...)` were confirmed hit by this investigation's real evidence):
- `isActiveTargetOS`: real OS aliases per platform (`OSX` recognized as `macOS`, confirmed live in
  `Cartography`'s own source, not a hypothetical legacy form).
- `canImport`: a small, explicit per-module platform-availability table (`AppKit`/`Cocoa`/`IOKit`/...
  → macOS; `UIKit`/`TVUIKit` → iOS+tvOS; `WatchKit` → watchOS only) -- **not** a coarse "macOS vs.
  everything else" split. A real regression in this fix's own first draft caught this the hard way:
  bucketing `WatchKit` together with `UIKit` as one "iOS-family" set answered `canImport(WatchKit)` as
  `true` on iOS, reproducing the exact same `no such module 'WatchKit'` error against `Kingfisher`'s
  own `HasImageComponent+Kingfisher.swift` (three independent, non-`#elseif`-chained `canImport`
  blocks: `AppKit`, `UIKit && !os(watchOS)`, `WatchKit`) -- caught by re-running against the real
  corpus after the `os()`-only fix, not by code review.

The one platform value this whole fix needs is threaded from `SwiftIsolationMap.swift`'s existing,
*already-memoized* `compilerArguments` lookup (the same one `detectConfiguredDefaultIsolation`
triggers to find `-default-isolation`) -- `detectTargetPlatform` reuses that same resolved argument
list to read `-target <triple>`'s OS component, at zero extra build cost, and logs it (`[verbose]
Target platform: iOS`). `.unknown` (never filtering, this project's exact pre-fix behavior for the one
axis that matters: never *silently dropping* a real declaration) for anything undeterminable -- a
SwiftPM package's own differently-shaped `-target`, or a `compilerArguments` failure.

**Tests**: 7 new `DeclarationExtractorTests` cases, all against real, motivating shapes (not
synthesized guesses) -- the real `Cartography/LayoutGuide.swift` `#if os(iOS)/#elseif os(OSX)` shape
(reduced to a fixture, verified both platforms extract exactly the one real declaration, verified
`platform: .unknown` extracts exactly one branch -- never both, an improvement over the true pre-fix
behavior even where platform can't be determined), the real `Kingfisher` three-independent-`canImport`
-blocks shape (the `WatchKit` regression case above), a `canImport` round-trip in both directions
(`AppKit`/`UIKit`), and a phantom-`@globalActor`-in-a-dead-branch case (confirms the fix also prevents
a *global* accept-list, not just one file's own declarations, from being polluted by dead code). Full
suite: 375/375 passing (was 368 before this session).

**Real corpus, before/after** (`~/ios/lsboutique.xcworkspace`, unchanged corpus, §2 still
un-fixed at measurement time -- see the caveat below):

| | before (§3's own baseline) | after (this fix only) |
|---|---|---|
| `no such module 'AppKit'`/`'WatchKit'` occurrences | 7 | **0** |
| External oracle resolved | 3344 | 3333 |
| External oracle unknown | 2583 | 2546 |
| Cross-isolation edges (denominator) | 5595 | 5720 |
| Unresolved % | 73% | 74% |

The traced symptom (§3's whole reason for existing) is fully gone: zero `AppKit`/`WatchKit` compile
errors, confirmed twice (once after the `os()`-only fix caught the `Cartography` case, again after the
`canImport` table fix caught the `WatchKit` regression). `isUnknown` itself only moved modestly (2583
→ 2546, -37) and the *percentage* moved the wrong way at first glance (73% → 74%) -- not a regression,
an artifact of the denominator: fewer phantom declarations reshapes the whole extracted call graph
(fewer total declarations: 47167 → 46587; fewer edges *before* filtering: 137882 → 137548; the
5595 → 5720 *cross-isolation* edge count moving the other direction reflects which edges specifically
survive re-extraction, not a size regression). **§2 (`LiveXcodeBulkExtractionEnvironmentProvider`
ignoring `-destination`) is still real and still unfixed as of this measurement** -- some fraction of
the remaining 2546 `isUnknown` is that separate, independent cause (every third-party CocoaPods
module's bulk pre-resolution still silently disabled), not this fix's own remaining scope. The two
contributions are not yet measured apart from each other.

## 6. §2 -- implemented

`LiveXcodeBulkExtractionEnvironmentProvider.environment()` now resolves a destination via the same
`resolveDeterministicSimulatorDestination(container:scheme:processRunning:)` helper
`LiveXcodeCompilerArgumentsProvider` already used, passed to `-showBuildSettings` before parsing
`SDKROOT`/`ARCHS`/`FRAMEWORK_SEARCH_PATHS`. 4 tests (`BulkExtractionEnvironmentProvidingTests.swift`):
the two pre-existing tests updated to account for the new (real, `-showdestinations`) probe
invocation, plus a new test asserting the resolved `-destination` actually reaches
`-showBuildSettings` using the real `lsboutique`/lightly-adapted-Swiftfin destination shape from §2's
own original repro.

## 7. §5's `.unknown`-platform case -- a real gap caught by review, not by this fix's own tests

Raised directly: `PlatformBuildConfiguration`'s `.unknown` case answered every `BuildConfiguration`
query `true` ("active"), which does **not** mean "every `#if`/`#elseif` branch survives" -- a chain
only ever has one active clause by construction (`ActiveClauseEvaluator` mirrors real `#if`/`#elseif`/
`#else` priority), so answering every condition `true` just makes the **textually-first** clause win,
silently dropping a real declaration written in a later `#elseif` if the true platform (undetected)
happened to need that branch. This is the exact failure mode §5 exists to prevent, inverted (missing
a real declaration instead of duplicating a phantom one) -- and missing a real declaration is strictly
worse than this project's pre-fix status quo (an extra phantom one, already tolerated everywhere
downstream via the fail-soft "unknown, not silently wrong" oracle contract).

Fixed with `PlatformAwareSyntaxVisitor` (`Sources/SyntaxAnalysis/PlatformBuildConfiguration.swift`):
behaves exactly like `ActiveSyntaxVisitor` when the platform is known, and exactly like a plain,
pre-fix `SyntaxVisitor` (visits *every* clause unconditionally) when `configuration.platform ==
.unknown` -- achieved by overriding `visit(_: IfConfigDeclSyntax)` to unconditionally return
`.visitChildren` for the unknown case, bypassing `ActiveClauseEvaluator` entirely rather than trying
to approximate "every branch active" through `BuildConfiguration` answers alone. All 5 extractor
visitor classes now inherit `PlatformAwareSyntaxVisitor` instead of `ActiveSyntaxVisitor` directly.
Test `unknownPlatformStillExtractsBothBranches` (rewritten from its own first-draft, now-wrong
assertion) confirms both branches of the real `Cartography/LayoutGuide.swift` shape survive when
platform is `.unknown`. Confirmed live against a second, independent real corpus (`~/corpora/Swiftfin`,
779 files) -- its own `Target platform: unknown` result (a real detection gap, not investigated
further since it's outside this fix's scope) exercises this exact fallback path in practice, not just
in a synthetic test; no crash across all 779 files.

## 8. A third, independent finding: phantom `setXXX:` edges for read-only Objective-C properties

While auditing the *post-§5* residual `isUnknown` breakdown on the real `lsboutique` corpus, the
single largest edge-count category (240 edges / 17 distinct USRs) was every one a synthesized ObjC
setter selector for a property that has **no real setter** in the actual SDK header: `UIView(im)
setLeadingAnchor:`, `setTopAnchor:`, `setNavigationController:`, `setWindow:`, `setTabBarController:`,
and siblings -- `leadingAnchor`/`topAnchor`/`navigationController`/`window`/`tabBarController` are all
genuinely `readonly` in real UIKit. Real representative location (`Pods/OverlayContainer/.../
UIView+Constraints.swift:21`):

```swift
leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: insets.left).isActive = true
```

A pure read of `leadingAnchor`, immediately used to call `.constraint(equalTo:)`, whose *result* has
`.isActive` assigned -- no assignment to `leadingAnchor` anywhere.

### 8.1 Root-caused via a minimal, non-Apple-SDK-corpus reproduction, not the real 2248-file corpus

Per explicit steer (chasing this on the real corpus would have meant a multi-minute clean-rebuild
cycle per iteration): a from-scratch SPM package (`MiniAnchorRepro`, macOS/AppKit -- `NSView` shares
the identical `NSLayoutAnchor` API surface with `UIKit`'s `UIView`, and macOS needs no SDK/simulator
setup for `swift build`) reproduced the exact same phantom-setter shape in **two lines of source**:

```swift
extension NSView {
    func pinToSuperview() {
        guard let superview = superview else { return }
        translatesAutoresizingMaskIntoConstraints = false
        leadingAnchor.constraint(equalTo: superview.leadingAnchor, constant: 0).isActive = true
    }
}
```

Confirmed general (not `UIView`/`UIKit`-specific), and gave a full raw-occurrence dump (a temporary,
reverted `SWIFT_ISOLATION_MAP_DEBUG_OCCURRENCES` env-gated instrumentation in
`rawIndexStoreOccurrenceApplier`) in seconds instead of minutes:

```
[occ] line=6 col=9 usr=...setTranslatesAutoresizingMaskIntoConstraints: name=setter:translatesAutoresizingMaskIntoConstraints roles=78180
[occ] line=6 col=9 usr=c:objc(cs)NSView(py)translatesAutoresizingMaskIntoConstraints                        roles=69716  (WRITE only)
[occ] line=7 col=9 usr=...leadingAnchor              name=getter:leadingAnchor roles=78180
[occ] line=7 col=9 usr=...setLeadingAnchor:          name=setter:leadingAnchor roles=78180
[occ] line=7 col=9 usr=c:objc(cs)NSView(py)leadingAnchor                                                     roles=69724  (READ+WRITE)
```

The real, load-bearing signal: a **genuine write** (line 6, `translatesAutoresizingMaskIntoConstraints
= false`) produces *only* the setter-named occurrence at its position. A **genuine read** of a
read-only property used as a call-chain base (line 7, `leadingAnchor.constraint(...)`) produces *both*
a getter- and a setter-named occurrence, at the exact same `(file, line, column)` -- the setter one
phantom (no real setter exists to call).

### 8.2 Root-caused all the way to real, current `swiftlang/swift` compiler source -- not a guess

An intermediate hypothesis ("chained member-access-then-method-call defaults to `AccessKind::
ReadWrite`") was floated from `lib/Index/Index.cpp` alone and was **not fully verified** at the time --
that file only shows the *consequence* of a given `AccessKind` (`initVarRefIndexSymbols`: `.Read` sets
`SymbolRole::Read`; `.ReadWrite` sets *both* `Read` and `Write`; `IndexSwiftASTWalker::report` then
independently reports a pseudo-accessor for each role present), never where `AccessKind` itself gets
computed for an expression. A first attempt to find that computation (`lib/SILGen/SILGenApply.cpp`,
`accessKind = AccessKind::ReadWrite`) was the **wrong layer entirely** (SILGen runs after and
separately from the AST-level indexing walk) and, independently, gated on `ValueOwnership::Owned`/
`.InOut` -- inapplicable to a plain, non-`inout` method call on a class instance regardless of layer.

The real mechanism, fully traced through `lib/IDE/SourceEntityWalker.cpp`
(`swiftlang/swift`, real GitHub source, fetched via `gh api repos/swiftlang/swift/contents/...
--jq .download_url` then `curl`, not paraphrased from memory) -- `SemaAnnotator::walkToExprPre`, the
walker every indexing/IDE consumer including `Index.cpp` builds on:

1. `AssignExpr` (line ~567): walking its `dest` sets `OpAccess = AccessKind::Write`.
2. `MemberRefExpr` (line ~414-427), the real code (comment included verbatim, an acknowledged,
   documented imprecision in the compiler's own source, not this project's inference):
   ```cpp
   // This could be made more accurate if the member is nonmutating, or whatever.
   std::optional<AccessKind> NewOpAccess;
   if (OpAccess) {
     if (*OpAccess == AccessKind::Write)
       NewOpAccess = AccessKind::ReadWrite;
     else
       NewOpAccess = OpAccess;
   }
   llvm::SaveAndRestore<...> C(this->OpAccess, NewOpAccess);
   if (!MRE->getBase()->walk(*this)) return Action::Stop();
   ```
   Walking a `MemberRefExpr`'s own **base** upgrades an inherited `.Write` to `.ReadWrite`, and
   preserves an inherited `.ReadWrite` unchanged, while descending.
3. `CallExpr`/`ApplyExpr` has **no dedicated case** in this walker at all (confirmed: no `CallExpr`/
   `ApplyExpr` branch anywhere in the file) -- it falls through to the default child-walk, which does
   *not* touch `OpAccess`, so whatever access kind was in effect going in comes back out unchanged for
   its function-reference and arguments.

Composing these three real, confirmed facts for `leadingAnchor.constraint(equalTo:...).isActive =
true`'s real AST shape (`AssignExpr(dest: MemberRefExpr(.isActive, base: CallExpr(fn: MemberRefExpr
(.constraint, base: MemberRefExpr(.leadingAnchor, base: DeclRefExpr(self/view))), args: ...)), src:
true)`):

`.Write` (from the assignment) → upgraded to `.ReadWrite` walking `.isActive`'s base → passed through
unchanged by the un-cased `CallExpr` → still `.ReadWrite` walking `.constraint`'s own base (the
`else NewOpAccess = OpAccess` branch, since it's no longer literally `.Write`) → **`.leadingAnchor`
itself gets reported with `OpAccess = .ReadWrite`**, three AST levels removed from the actual
assignment, despite being a pure read.

This is real, general, and **not specific to this one source shape**: any read-only property that
ends up anywhere in the base-expression chain leading to an eventual assignment -- regardless of how
many `MemberRefExpr`/`CallExpr` levels separate it from the `=` -- gets the same treatment, because
`.ReadWrite` propagates unchanged through every un-cased node (confirmed specifically for `CallExpr`;
not exhaustively re-verified for every other `Expr` subtype the walker doesn't special-case, but the
same "no case → no reset" structure applies to whichever ones aren't listed).

### 8.3 Fix

`RawIndexStoreClient` (`Sources/IndexStoreIntegration/RawIndexStoreClient.swift`): a `CALL`-role
occurrence whose reported `name` starts with `"setter:"` is no longer added as a call-graph edge
immediately. It's deferred (`pendingSetterEdges`) until the whole store has been scanned, then
reconciled against every position that also carried a `"getter:"`-named `CALL`-role occurrence
(`getterCallLocations`) via a new pure, independently-tested function:

```swift
static func realSetterEdges(
    pendingSetterEdges: [(location: SymbolLocation, edge: CallGraphEdge)], getterCallLocations: Set<SymbolLocation>
) -> [CallGraphEdge] {
    pendingSetterEdges.filter { !getterCallLocations.contains($0.location) }.map(\.edge)
}
```

A setter-named edge survives exactly when its exact position was never *also* a getter-named
occurrence -- matching §8.1's own real, load-bearing signal (a genuine write never has a co-located
getter; a read-only property's `.ReadWrite`-tainted read always does). Deferred rather than filtered
inline because occurrence order within an index record isn't guaranteed to put the getter before the
setter. `SymbolLocation` made `Hashable` (previously only `Equatable`) to support the `Set`.

5 new tests (`RawIndexStoreClientAccessorResolutionTests.swift`, pure/synthetic, no real index store
needed, mirroring `resolvedOwningPropertyUSR`'s own precedent): co-located setter dropped, genuine
write with no co-located getter survives, two edges at different positions filtered independently,
empty input, and a same-line-different-column case (a getter elsewhere on the *same line* -- e.g. the
`equalTo:` argument's own `.leadingAnchor` reference -- must not suppress an unrelated setter at a
different column). Full suite: 381/381 passing.

Real minimal-repro verification: `MiniAnchorRepro`'s own call-graph edge count dropped 16 → 12 (the
4 phantom `setLeadingAnchor:`/`setTopAnchor:` edges removed), and its `isUnknown` cross-isolation edge
list dropped to empty.

**Real `lsboutique`-corpus before/after (§2+§5+§7 already applied on both sides -- this fix's own
isolated contribution):**

| | before §8 | after §8 |
|---|---|---|
| Linked call-graph edges (whole project, pre-filtering) | 137548 | 133748 (**-3800**) |
| Cross-isolation edges (denominator) | 5720 | 4618 (**-1102**) |
| External oracle resolved | 3333 | 3333 |
| External oracle unknown | 2546 | 2498 (**-48**) |
| Unresolved % | 74% | **67%** |

Two things worth calling out honestly. First, the whole-project call-graph shrank by 3800 edges --
far more than the ~240-edge `leadingAnchor`/`topAnchor`/etc. family §8.1 sampled to find the bug --
confirming §8.2's own prediction that the mechanism is general (any read-only property anywhere in an
assignment's base-expression chain, project-wide, not one property family). Second, this is the first
fix in this whole investigation (§2, §5, §7, §8) where the unresolved *percentage* itself moved
meaningfully (74% → 67%), not just raw counts moving while the percentage stayed flat or worsened
because the denominator moved too -- here the denominator shrank *faster* than the numerator, a real
signal that phantom edges (not just phantom *unknown* answers) were being counted as genuine
cross-isolation boundaries at all.

## 9. Status

- §2 (bulk extraction ignores destination) -- **FIXED AND VERIFIED**.
- §3/§5 (source of the `AppKit`/`WatchKit` errors; `#if`/`canImport` phantom declarations) --
  **FIXED AND VERIFIED**, including the `.unknown`-platform correction (§7).
- §8 (phantom `setXXX:` edges for read-only ObjC properties) -- **FIXED AND VERIFIED** against the
  real `lsboutique` corpus (table above), root-caused to real, current `swiftlang/swift` compiler
  source (not a guess at any stage of the final explanation), 5 new tests (381/381 total), also
  verified against a minimal reproduction.
