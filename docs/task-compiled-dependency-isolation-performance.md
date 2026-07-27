# Task: make compiled-dependency isolation resolution fast enough for real projects

**Status: not started. This is a task specification for a dedicated future session, not a
record of completed work** (unlike every other file in `docs/`, which documents what was already
built and verified). Written immediately after Phases A-F of
`docs/task-compiled-dependency-isolation.md` (the original 100%-correctness task) were fully
implemented, tested (187/187, `swift test -c release`), and then real-world-validated against
`~/ios` — where the *correctness* is not in question (the oracle resolves what it queries
correctly, per the golden-fixture matrix and every live test) but the **wall-clock time makes the
tool unusable for its own stated purpose**. The user's own words, verbatim, stated after watching
a real run run for over an hour without finishing: *"Не пойдет. Очень долго. Наш
swift-isolation-map просто не пригоден для серьезного применения если он так долго работает."*
Whatever this task produces must make a full analysis run against a real, Pods-based iOS project
complete in a time that's actually usable (interactively or in CI) — see "Definition of done"
below.

## 1. The problem, precisely

`ExternalIsolationBackfill.resolve` (`Sources/swift-isolation-map/ExternalIsolationBackfill.swift`)
resolves every externally-declared USR a project references (superclasses, protocol conformances,
direct call targets) that isn't in the project's own `declarations` dictionary. For each such USR,
absent a cache hit, it does one real `sourcekitd` `cursorinfo` round trip
(`SourceKitDClient.cursorInfo`, `Sources/SourceKitDIntegration/SourceKitDClient.swift`) — and each
round trip triggers `sourcekitd` to build/type-check a real AST for that query's source file
against the project's real, full compiler arguments (SDK, target, every framework search path,
every sibling file in the compilation unit). This is correct — verified exhaustively against real
compiler ground truth, `Tests/swift-isolation-mapTests/CompiledDependencyCLITests.swift`'s golden
fixture matrix, and multiple live-toolchain tests — but it is **not remotely fast enough** at the
scale of a real production codebase.

### 1.1 Concrete numbers from this session's real-world runs

Project: `~/ios`, scheme `ls.net.ru` (Xcode 26.4.0, Swift 6.3, CocoaPods-based, iOS SDK).
2209 `.swift` files, 46010 linked declarations, 137657 call-graph edges (post-Phase-C `callSites`
folding).

- **Before** any compiled-dependency work (pre-Phase-A code): `crossActorBoundaries: 1021`,
  `highRiskBoundaries: 164`, `unspecifiedIsolation: 428`. This is the baseline the whole original
  task (`docs/task-compiled-dependency-isolation.md`) exists to fix — a real fraction of that 164
  is a false positive caused by unresolved external superclasses (the `NewsTableCell`/
  `UITableViewCell` case documented there).
- **First real attempt, live-query-only oracle (no bulk cache yet)**: killed manually after **75
  minutes of wall-clock time**, still not finished. `sourcekitd` stderr logs (captured via
  `--verbose`) showed continuous real query activity the whole time (hundreds of thousands of
  `sourcekit:`-prefixed diagnostic lines), so it was not stuck — genuinely just too slow at the
  observed per-query rate.
- **Bulk `swift symbolgraph-extract`-based cache added** (see section 1.2) for three hardcoded SDK
  modules (`UIKit`, `AppKit`, `SwiftUI`), *before* a separate bug (section 1.3) was found and fixed:
  finished in ~3 minutes, but with `External oracle: 0 resolved, 0 conformance(s) updated, 49891
  unknown` — every single query failed, silently, because of the bug in section 1.3. This
  initially looked like a success (fast!) but was actually a total, silent failure masked as a
  clean run — a serious trap worth flagging to whoever picks this up: **fast-but-wrong must never
  be mistaken for "the optimization worked."** Always check the `External oracle:` verbose log
  line's `resolved` count is meaningfully nonzero, not just that the run finished quickly.
- **After fixing the section-1.3 bug** (clean-build fallback), the bulk cache + live-query oracle
  started doing real, verified work again (`sourcekit:` log lines and `getCursorInfo` call counts
  climbing steadily) — but at an observed throughput of roughly **600-850 `cursorinfo` queries per
  minute**, and with tens of thousands of distinct external USRs apparently still needing live
  resolution (the same order of magnitude as the `49891 unknown` figure above, though that number
  itself came from the fully-broken run and is only a rough upper bound, not a validated count).
  Extrapolated total runtime: on the order of 40-90+ minutes. **This is what the user rejected as
  unusable**, and this task exists to fix.

### 1.2 What's already been built and verified (do not re-derive from scratch)

`Sources/SourceKitDIntegration/BulkSymbolGraphExtractor.swift` — bulk-resolves isolation for
**every public symbol in a whole SDK module at once** via a real subprocess call:
```
xcrun swift symbolgraph-extract -module-name <ModuleName> -sdk <sdkPath> -target <triple> \
  -output-dir <dir> -minimum-access-level public
```
This produces one `<ModuleName>.symbols.json` file (plus sibling `<ModuleName>@<OtherModule>.
symbols.json` cross-reference files, currently ignored) containing an array of every symbol in the
module, each with `identifier.precise` (the real USR, module-qualified and unambiguous) and
`declarationFragments` — **the exact same shape** `SourceKitDIntegration/
SymbolGraphIsolationParser.swift` already parses from a single `cursorinfo` response's
`key.symbol_graph` field. `BulkSymbolGraphExtractor.extract` reuses
`SymbolGraphIsolationParser.isolation(fromFragments:)` directly, so the parsing logic is identical
and already trusted — only the *retrieval* is bulk instead of one-at-a-time.

Empirically confirmed, this session, on the real toolchain (Xcode 26.4.0):
- Extracting all of `UIKit` (iOS Simulator SDK): ~26MB JSON, thousands of symbols, completes in a
  few seconds. `UIViewController`'s entry correctly carries `@MainActor`
  (`declarationFragments` contains `{"kind":"attribute","spelling":"MainActor",
  "preciseIdentifier":"s:ScM"}`), confirming the mechanism produces the right answer for the
  original motivating case's *sibling* type (`UITableViewCell` itself wasn't separately checked
  this way, but the same header/ClangImporter mechanism applies to the whole class hierarchy).
- Extracting `AppKit` (macOS SDK): ~14s live in the test suite
  (`Tests/SourceKitDIntegrationTests/BulkSymbolGraphExtractorTests.swift`'s live test).
  `NSView` (`c:objc(cs)NSView`) correctly resolves to `.globalActor(name: "MainActor")`; `NSViewController`
  and `NSApplication`, checked manually during the same investigation, do **not** carry `@MainActor`
  on this particular SDK version — a good reminder that isolation facts are genuinely
  version-dependent and must always come from the real, currently-active SDK, never cached across
  SDK versions or hardcoded.
- Requesting a module absent from the current SDK (e.g. `AppKit` against an iOS SDK) makes
  `symbolgraph-extract` exit non-zero — `BulkSymbolGraphExtractor.extract` fails soft (returns
  `[:]`) in that case, unit-tested.

`ExternalIsolationBackfill.resolve` wires this in as a **performance cache only, never a new
source of truth**: `bulkSymbolGraphCache(...)` (private, same file) finds SDK/target from any one
project file's already-resolved real compiler arguments (`-sdk`/`-target` flags, present in every
real `swiftc`/`swift-frontend` invocation), then calls
`BulkSymbolGraphExtractor.extractAll(moduleNames: BulkSymbolGraphExtractor.defaultModules, ...)`
— `defaultModules` is currently the hardcoded array `["UIKit", "AppKit", "SwiftUI"]`. The shared
`query(...)` function and the declaration-level trigger both consult this cache **by exact USR**
first, falling back to the existing, unchanged, correct live `cursorinfo` path only for whatever
the bulk cache doesn't cover. **This part is finished, tested, and should not need to change** —
what needs to change is *what set of modules gets bulk-extracted*.

### 1.3 A separate, real, now-fixed bug worth knowing about (not this task's job, but context)

`Sources/ProjectResolution/XcodeBuildLogCompilerArgumentsProvider.swift`'s
`LiveXcodeCompilerArgumentsProvider` used to run a single `xcodebuild -verbose ... build` and parse
its log for `builtin-Swift-Compilation --` lines. **Confirmed empirically**: when the target is
already fully up to date (the common case for a repeated analysis run, or any CI pipeline that
already built the app before invoking this tool), Xcode's incremental build system prints **zero**
such lines — `-verbose` only echoes commands the build system actually decides to run. This
silently produced an empty file→arguments map, making every single `compilerArguments(forFile:)`
call throw, which made every oracle query (bulk *and* live) fail immediately, before ever reaching
`sourcekitd` — exactly the section-1.1 "fast but 0 resolved" trap. Fixed by retrying once with
`clean` prepended (`clean build`) whenever the first attempt yields zero invocations
(`runVerboseBuild(extraActions:)`, same file). This fix is real, necessary, and unit-tested
(`liveXcodeProviderFallsBackToCleanBuildWhenTheFirstAttemptYieldsNoInvocations`,
`Tests/ProjectResolutionTests/XcodeCompilerArgsTests.swift`) — **but it adds real, potentially
large, rebuild cost of its own** (a genuine `clean build` of a 2209-file Pods-based project) every
time this tool runs against an already-built project. This interacts with the performance problem
this task is about (both costs are paid on a "just built the app, now analyze it" CI run, which is
probably the single most common real usage pattern) and the researcher should keep it in mind, but
**fixing it further is out of scope for this task** unless it turns out to be entangled with the
chosen solution (e.g. a solution that reads compiler args from `.xcactivitylog` instead would
plausibly make this whole clean-build-fallback unnecessary — worth noting as a possible side
benefit of one of the options below, not a requirement).

## 2. Why the current fix doesn't cover the real bottleneck

`defaultModules = ["UIKit", "AppKit", "SwiftUI"]` is a **hardcoded, closed list**. `~/ios` is a
real, large, CocoaPods-based app. Confirmed this session via
`xcodebuild -showBuildSettings -workspace ~/ios/lsboutique.xcworkspace -scheme ls.net.ru` (fast,
read-only, no build triggered) — its `FRAMEWORK_SEARCH_PATHS` build setting lists **35+ distinct
third-party framework/module directories**, each named after a real Pod/module, e.g.:
```
ActionSheetPicker-3.0, Alamofire, CMSteppedProgressBar, Cartography, CocoaLumberjack,
DZNEmptyDataSet, DeviceKit, FirebaseCore, FirebaseCoreExtension, FirebaseCoreInternal,
FirebaseCrashlytics, FirebaseInstallations, FirebaseMessaging, FirebaseRemoteConfigInterop,
FirebaseSessions, GoogleDataTransport, GoogleUtilities, Kingfisher, MGSwipeTableCell, Marshal,
Mindbox, MindboxLogger, MindboxNotifications, Moya, OverlayContainer, PromiseKit, PromisesObjC,
PromisesSwift, SVGKit, SVProgressHUD, Signals, SkyFloatingLabelTextField, SwiftRichString,
TagListView, UIColor_Hex_Swift, libPhoneNumber-iOS, nanopb, ... (plus several
XCFrameworkIntermediates/Google*/Firebase* entries)
```
(`PODS_ROOT = /Users/ab/ios/Pods` is also directly available as a build setting.)

**The original motivating bug this whole feature exists to fix
(`docs/task-compiled-dependency-isolation.md` §2.1) is itself a Kingfisher call** —
`captionImageView.kf.indicatorType`. Kingfisher is not in `defaultModules`. Neither is any of the
other 34+ third-party frameworks. So for a real project like `~/ios`, the bulk cache — while
correctly implemented — resolves only a minority of what actually needs resolving, and the
overwhelming majority of external USRs still fall through to the slow, one-at-a-time live
`cursorinfo` path this whole bulk-cache mechanism was built to avoid.

**This is the actual problem to solve**: generalize bulk resolution to cover *whatever a project
actually depends on*, not a fixed list of Apple frameworks — without regressing the "no hardcoded
name lists as a source of truth" principle established throughout this whole feature's design (see
`docs/task-compiled-dependency-isolation.md` §3, restated here because it applies with equal force
to this task: a list may only ever be a *performance hint about what to bulk-extract*, never a
substitute for the real, compiler-derived answer).

## 3. What "acceptable performance" must mean

Not formally benchmarked/agreed with the user yet (worth confirming explicitly at the start of
whatever session picks this up), but as a concrete starting target: **a full analysis run against
`~/ios` (2209 files, 35+ third-party dependencies) should complete in low single-digit minutes**,
not tens of minutes — ideally comparable to or not wildly worse than the pre-compiled-dependency
baseline's own runtime (which this session did not precisely measure end-to-end, but which
involved no external oracle at all and should be used as a reference point — measure it fresh if
not already known). Whatever number is ultimately agreed, it must be **validated by an actual
timed run against both `~/ios` and `~/SQLumen`**, not estimated from a partial/killed run the way
this document's own numbers had to be.

### Definition of done (concrete, checkable)

1. A design decision, made only after empirically investigating the options in section 4 below
   (or any better option the researcher identifies) against real data from **both** `~/ios`
   (CocoaPods, iOS SDK, large) and `~/SQLumen` (SwiftPM-style dependencies via a
   `.xcodeproj`/CocoaPods mix if any — re-confirm its actual dependency shape first, don't assume
   it mirrors `~/ios`).
2. `BulkSymbolGraphExtractor`/`ExternalIsolationBackfill` extended (or a new mechanism added
   alongside them) so that the *set of modules eligible for bulk resolution* is derived from the
   project's own real, discovered dependencies — not a hardcoded array — while the actual
   *isolation facts* still come 100% from the real compiler (`swift symbolgraph-extract` or
   whatever mechanism is chosen), never from any kind of name-based table.
3. A full real-world timed run against `~/ios` (scheme `ls.net.ru`) and `~/SQLumen` (scheme
   `SQLumen`), `--output json --verbose`, with the `External oracle:` log line's `resolved` count
   checked to be meaningfully nonzero (not just "the run finished fast" — section 1.1's trap) and
   the wall-clock time reported and compared against the target in section 3's opening paragraph.
4. Regression check: rerun the full `swift test -c release` suite (187 tests as of this writing)
   and confirm no correctness regression — the golden-fixture matrix
   (`Tests/swift-isolation-mapTests/CompiledDependencyCLITests.swift`) is the one most likely to
   catch a bulk-vs-live discrepancy, since it pairs every assertion with real `swiftc` ground
   truth.
5. A decision record written up in `docs/priority-3-*.md` style (see existing files in that
   directory for the convention) documenting the chosen approach, the real numbers before/after,
   and — per this project's established discipline — any sub-case that remains slow or unsolved,
   written up as an explicit, evidenced, permanent limitation rather than silently dropped.

## 4. Candidate approaches to investigate (not a prescription — the researcher should weigh these against real data, and is free to find better ones)

**A. Auto-discover modules from real build settings/compiler-arg search paths.**
`FRAMEWORK_SEARCH_PATHS`/`SWIFT_INCLUDE_PATHS`-equivalent `-F`/`-I` flags are already present in
every real per-file compiler-argument list this tool retrieves (`CompilerArgumentsProviding`,
Phase A). Enumerate `.framework` bundles and `.swiftmodule` bundles/files found in those search
paths (each subdirectory/file's base name is a real, unambiguous module name — confirmed above:
`FRAMEWORK_SEARCH_PATHS` entries are literally one directory per Pod, named after the module) and
bulk-extract *all* of them via the same `swift symbolgraph-extract -module-name <X> ...` mechanism,
passing through the same `-F`/`-I`/`-sdk`/`-target` flags already available. Open questions this
approach must answer empirically, not assume:
   - Does `symbolgraph-extract` work identically for a CocoaPods-built `.framework` (often
     containing a `.swiftmodule` inside) as it does for an SDK framework? Verify against a real Pod
     from `~/ios` (Kingfisher is the obvious, motivating choice) before designing further.
   - What is the real cost of bulk-extracting 35+ modules, one process invocation each? Even at a
     conservative ~10-15s/module (this session's AppKit measurement), 35 modules is ~6-9 minutes —
     acceptable, but must be measured for real, not assumed, and ideally done fully in parallel
     (each `symbolgraph-extract` invocation is an independent subprocess with its own output
     directory — no shared mutable state the way `SourceKitDClient`'s actor has).
   - Some discovered "modules" might be C/Objective-C-only (no Swift interface at all,
     `symbolgraph-extract` would legitimately fail/produce nothing) — must fail soft per the
     existing pattern, not treated as an error.
   - Whether to bulk-extract *every* discovered module unconditionally, or only ones actually
     referenced by at least one unresolved external USR in this run (cheaper, but requires knowing
     which module an unresolved USR belongs to *before* extracting anything — likely needs a light
     demangling step, e.g. via `swift demangle` or `-module-name`-shaped USR prefixes, to map a USR
     to its owning module without a live query). This could meaningfully cut the number of modules
     that need bulk-extracting on a project with 35+ dependencies where only a handful are
     actually subclassed/conformed-to/called into.

**B. Parse Xcode's persisted `.xcactivitylog` from the project's last real build**, instead of
running any new `xcodebuild -verbose`/`clean build` at all. Xcode writes a gzip-compressed,
Apple-proprietary "SLF"-ish binary log to `DerivedData/<Project>/Logs/Build/*.xcactivitylog` on
*every* real build (regardless of whether anything needed recompiling), which should contain the
actual literal compile invocations from whenever the project was last really built — potentially
solving section 1.3's bug *and* this task's problem simultaneously, since it requires no new build
at all if a recent one already happened (the common "CI just built the app" case). Real, existing
open-source parsers exist for this format (e.g. `XCLogParser`) and can be used as a format
reference, though the format itself is undocumented by Apple and has shifted across Xcode versions
before — must be verified empirically against the actual Xcode 26.4.0 log format on this machine,
not assumed stable, before committing to this approach. Was proposed once during this session and
the user preferred the simpler clean-build fallback for section 1.3's narrower bug — but it may be
worth reconsidering here if it turns out to *also* solve this task's core problem (avoiding a
39-plus-module bulk-extraction pass entirely by reading facts already computed during the app's own
last real build).

**C. Parallelize bulk extraction (approach A) and/or the remaining live `cursorinfo` fallback
queries.** `BulkSymbolGraphExtractor.extract` calls are independent subprocesses with no shared
state — trivially parallelizable (e.g. `withThrowingTaskGroup`). `SourceKitDClient` is currently a
single `actor` (Phase B's deliberate, documented simplicity choice, made before real-world scale
was known) serializing every live query — investigate whether multiple `SourceKitDClient`
instances (multiple in-process `sourcekitd` sessions) can run concurrently without the SIGSEGV race
Phase B hit and fixed with a `pthread_mutex_t` in the C shim (`Sources/CSourceKitD/shim.c`) — that
fix guards *shim-global* state, so it's unclear without checking whether multiple *client*
instances each get their own independent `sourcekitd` session or still contend on some global
resource. This must be verified empirically (a live test issuing concurrent queries from multiple
clients, watching for crashes/corruption) before being trusted, given Phase B's own explicit
uncertainty about `sourcekitd`'s concurrency safety beyond the single-threaded case the original
research spike verified.

**D. A persistent, on-disk, cross-run cache** of `USR -> isolation`, keyed by (module name, module
version/build identifier, SDK version) so that a *second* run against the same project (or even a
different project using the same Pods/SDK version) doesn't repeat any bulk-extraction or live query
work at all. This is orthogonal to A/B/C (a caching layer on top of whichever retrieval mechanism
is chosen) and worth doing regardless of which of A/B/C wins, since CI reruns against a
slowly-changing dependency set are presumably the dominant real usage pattern. Needs a real
invalidation key — investigate what's actually available and stable (a Pod's version string from
`Podfile.lock`, an XCFramework's own version metadata, a `.swiftmodule`'s embedded compiler
version/hash) rather than inventing one.

## 5. Relevant existing architecture (context for whoever picks this up)

- `Sources/SourceKitDIntegration/BulkSymbolGraphExtractor.swift` — the bulk-extraction mechanism,
  already built and tested; `defaultModules` is the one piece of hardcoded state this task should
  replace or generalize.
- `Sources/swift-isolation-map/ExternalIsolationBackfill.swift` — `bulkSymbolGraphCache(...)`
  (private) is where SDK/target are currently derived and `BulkSymbolGraphExtractor.extractAll` is
  invoked; this is almost certainly where a module-discovery step would plug in.
- `Sources/ProjectResolution/CompilerArgumentsProviding.swift` / `XcodeBuildLogCompilerArgumentsProvider.swift`
  / `SwiftPMCompilerArgumentsProvider.swift` — the source of real per-file compiler arguments
  (including `-F`/`-I`/`-sdk`/`-target`) this task would need to enumerate search paths from.
- `Sources/SourceKitDIntegration/SourceKitDClient.swift` — the live-query fallback path; relevant
  if pursuing parallelization (option C).
- `Tests/SourceKitDIntegrationTests/BulkSymbolGraphExtractorTests.swift` — existing unit + live
  tests for the bulk mechanism; extend rather than replace when adding module-discovery tests.
- `Tests/swift-isolation-mapTests/CompiledDependencyCLITests.swift` — the golden-fixture matrix;
  the fixture's `ExternalDep` package (`Tests/Fixtures/compiled-dependency/ExternalDep/`) could
  plausibly be extended with an *additional*, differently-named fake dependency to prove
  module-discovery works generically, not just for the one fixture module already exercised.
- `docs/priority-3-phase-a-compiler-args.md`, `docs/priority-3-phase-b-sourcekitd-client.md`,
  `docs/priority-3-phase-c-oracle-triggers.md` — the decision records for the original
  correctness-focused work; read these for context on why things are shaped the way they are
  before changing them.

## 6. Explicitly out of scope for this task (do not silently expand into these)

- Any change to *what* gets resolved or *how correctly* (the existing oracle's correctness is not
  in question — every fixture and live test passes). This task is purely about *how fast* the
  existing, correct mechanism can produce its answer.
- Fully fixing section 1.3's clean-build-fallback cost (only relevant here if a chosen solution,
  e.g. option B, happens to subsume it — not a requirement to solve independently).
- Re-litigating `IsolationInferenceEngine`'s stability invariant — untouched throughout the
  original task, and nothing about a performance fix should require touching it.
- Changing the risk heuristic or report schema (`AnalysisReportBuilder`, `OutputFormat`) — this
  task's success criterion is purely about the oracle's wall-clock time, not its output shape.
