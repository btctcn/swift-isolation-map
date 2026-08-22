# Spike: driving `swift-build`'s `SwiftBuild` API directly, bypassing `xcodebuild`'s CLI

Follows `docs/task-xcodebuild-show-build-settings-for-index-spike.md`, whose Step 6a proved the
platform-selection bug lives specifically inside `xcodebuild`'s closed-source CLI-to-`BuildRequest`
translation for `-showBuildSettingsForIndex`, not in the open-source `SWBBuildService` engine
itself (confirmed via real `build-request.json` cache files: the same DerivedData, queried by a
real `build` action with `-destination`, correctly encodes `activeRunDestination.platform:
iphonesimulator`; queried via `-showBuildSettingsForIndex`, even with an explicit `-sdk
iphonesimulator`, still encodes `iphoneos`). Since the engine itself is destination-faithful, and
`swiftlang/swift-build` ships `SwiftBuild`/`SWBBuildService` as real, importable Swift Package
products, the natural next question: does talking to the engine directly, constructing our own
`SWBBuildRequest` with an explicit `activeRunDestination`, sidestep the bug entirely?

**Status: confirmed yes, empirically, against real Project Iris. Correct simulator target/SDK,
correct real DerivedData paths, zero `iphoneos` contamination, ~8 seconds.**

## Step 1 — API discovery

Cloned `swiftlang/swift-build` and searched for the JSON keys this project's own tooling already
recognizes (`swiftASTCommandArguments`, `swiftASTModuleName`) to find the real implementation, not
guess at names:

- `Sources/SWBBuildService/Messages.swift`'s `handleIndexingInfoRequest`/`GetIndexingFileSettingsMsg`
  is the real server-side handler -- confirmed destination-aware (plans a fresh `BuildDescription`
  from whatever `BuildRequest` it's given, unless a `buildDescriptionID` is supplied for a
  cache-only lookup).
- `Sources/SwiftBuild/SWBIndexingSupport.swift` + `SWBBuildServiceSession.generateIndexingFileSettings
  (for:targetID:filePath:outputPathOnly:delegate:)` is the real **client-side** public API --
  takes a full `SWBBuildRequest` (which carries `parameters.activeRunDestination`, a real, public,
  settable `SWBRunDestinationInfo?` field) and returns `SWBIndexingFileSettings` (the same
  `swiftASTCommandArguments`/`swiftASTModuleName`/`outputFilePath` shape `-showBuildSettingsForIndex`
  returns, per-file).
- `Sources/SwiftBuild/ConsoleCommands/SWBServiceConsoleBuildCommand.swift`'s
  `SWBServiceConsolePrepareForIndexCommand` (the `swbuild prepareForIndex` interactive console
  command, Apple's own reference implementation) shows the real, working end-to-end pattern:
  `session.loadWorkspace(containerPath:)` (accepts a real `.xcworkspace`/`.xcodeproj`/`Package.swift`
  path directly -- the open-source engine parses the real project itself, no PIF pre-generation by
  Xcode needed), then a `SWBBuildRequest` with `.buildCommand = .prepareForIndexing(...)`.

## Step 2 — Standalone spike package

Built a throwaway SPM executable (`/Users/ab/.claude/jobs/eb8b802b/tmp/patches/PrepareForIndexingSpike`,
depends on the local `swift-build` clone via `.package(path:)`, not part of `swift-isolation-map`
itself) that:

1. Creates an `SWBBuildService()` (out-of-process connection mode -- required
   `SWBBUILDSERVICE_BUNDLE_PATH` pointed at Xcode's own real bundled service,
   `/Applications/Xcode-26.4.0.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/
   SWBBuildService.bundle` -- our own binary isn't inside an app bundle, so the default lookup
   couldn't find a service to launch on its own).
2. `loadWorkspace(containerPath: "/Users/ab/ios/lsboutique.xcworkspace")` -- real Project Iris.
3. Builds `SWBBuildParameters` with an explicit `activeRunDestination = SWBRunDestinationInfo
   (platform: "iphonesimulator", sdk: "iphonesimulator26.4", sdkVariant: "iphonesimulator", ...)`
   and an explicit `arenaInfo` pointing at this tool's own real private DerivedData
   (`~/Library/Caches/swift-isolation-map/DerivedData/lsboutique-cb33c438/ls.net.ru/
   generic_platform_iOS_Simulator/default`, the same one Run A/B used).
4. Calls `session.generateIndexingFileSettings(for:targetID:filePath:outputPathOnly:delegate:)` for
   `AppGroupFetcher.swift` directly -- no `xcodebuild` process ever invoked, no CLI flag parsing
   involved at all.

## Step 3 — Result: correct, clean, fast

```
TARGET: arm64-apple-ios15.6-simulator
SDK: /Applications/Xcode-26.4.0.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.4.sdk
swiftASTBuiltProductsDir: ".../lsboutique-cb33c438/ls.net.ru/generic_platform_iOS_Simulator/default/Build/Products/Debug-iphonesimulator"
assetSymbolIndexPath: ".../Debug-iphonesimulator/Ls.net.ru.build/DerivedSources/GeneratedAssetSymbols-Index.plist"
outputFilePath: "/lsboutique.build/Debug-iphonesimulator/Ls.net.ru.build/Objects-normal/arm64/AppGroupFetcher.o"
```

- **Target/SDK correct**: simulator, not device -- the exact thing `-showBuildSettingsForIndex`
  gets wrong on this project, fixed by construction (we set `activeRunDestination` ourselves; the
  buggy CLI translation is never in the path).
- **Real DerivedData paths, not a default `<project>/build` fallback**: an earlier attempt without
  setting `arenaInfo` fell back to `/Users/ab/ios/build/Debug-iphonesimulator` (SWBBuildService's
  own default when no arena is specified) -- fixed by constructing `SWBArenaInfo` explicitly
  (`buildProductsPath`/`buildIntermediatesPath`/`indexDataStoreFolderPath` all rooted at our real
  private DerivedData path, mirroring the internal-only `SWBBuildRequest.setDerivedDataPath` helper
  seen in the console command source, reimplemented since it isn't `public`).
- **Zero `iphoneos` contamination**: grepped the full 267,842-character `swiftASTCommandArguments`
  output for any `iphoneos` substring -- none found, anywhere.
- **Fast**: `time` reports **8.2 seconds wall-clock**, comparable to (a bit faster than) the ~16-20s
  `-showBuildSettingsForIndex` CLI call, and vastly faster than the multi-minute clean rebuild
  `LiveXcodeCompilerArgumentsProvider` currently falls back to. No `prepareForIndexing` build
  operation was even run first -- `generateIndexingFileSettings` alone, against the already-built
  private DerivedData, was sufficient.

## Step 4 — What's proven and what isn't yet (original list)

**Proven**: the platform-selection bug is entirely a property of `xcodebuild`'s CLI, confirmed by
directly sidestepping it -- the open-source engine, driven with an explicit destination, produces
correct, real, DerivedData-matching per-file compiler arguments, fast, for a real ~2200-file
corpus's real target.

**Not yet proven (next steps before this could replace `LiveXcodeCompilerArgumentsProvider`)**:
1. Whether these exact arguments actually let `sourcekitd`'s `cursorInfo` succeed.
2. Whether `swift-build` as a real SPM dependency of `swift-isolation-map` itself is viable
   (bundle-location strategy).
3. Full end-to-end comparison against Run A/Run B.
4. `swift-build`'s own version-compatibility risk against the installed Xcode.

## Step 5 — cursorInfo validated: exact parity with the real build, not just "looks right"

Reused the real Step 5b probe methodology from the other doc (every byte offset across line 19 of
`AppGroupFetcher.swift`, both argument sets, real `SourceKitDClient.cursorInfo`) but this time
comparing swift-build's args against the **real, honest `-verbose` build's own args** (ground
truth), not device args. **Result: byte-for-byte identical outcome at all 22 offsets** -- both fail
at the 20 offsets with no queryable symbol, both succeed at the 2 offsets on the `""` literal with
identical `usr=s:SS name=String`. Not "plausible," not "close" -- exact parity with production's
own real compiler-argument source. Item 1 closed.

## Step 6 — Bundle location fixed: `xcode-select -p`, no hardcoded path

Replaced the `SWBBUILDSERVICE_BUNDLE_PATH` environment-variable override with the same pattern this
project already uses for locating other Xcode-bundled tools (`ToolchainLocating.swift`'s `xcrun
--find swift`): shell out to `xcode-select -p` for the active Developer directory, derive
`<Contents>/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle`
relative to it, and pass that URL to `SWBBuildService(serviceBundleURL:)` directly. Verified working
with zero environment variables set. Item 2's *mechanism* is closed -- the *risk* is folded into
Step 8 below, not closed on its own (see there for why).

## Step 7 — Timing methodology corrected: the original 8.2s number was measuring the wrong thing

**A real methodological catch, raised before any further validation was allowed to proceed**: Step
3's "~8.2 seconds" was one file's `generateIndexingFileSettings(filePath: <one file>)` call, timed
as a whole process invocation (service init + session + `loadWorkspace` + one query all bundled
together). Comparing that number against `-showBuildSettingsForIndex`'s "~16-20s for an entire
target" (the other doc's Step 2) was apples-to-oranges -- it says nothing about what querying all
2226 files would actually cost, and naive per-file extrapolation could make the mechanism look
either far better or catastrophically worse than reality depending on how much of that 8.2s was
one-time setup versus genuine per-file cost.

Measured directly, same session, 10 real distinct files from the real `Ls_net_ru` `SwiftFileList`,
timed individually:

| call | elapsed |
|---|---|
| `SWBBuildService()` init | 0.08s |
| `createSession` | 0.21s |
| `loadWorkspace` | 4.07s |
| `workspaceInfo` | 0.01s |
| file 0 (first query, cold) | 1.35-1.49s |
| files 1-9 (same session) | **0.20-0.22s each, flat** |

Confirms the hypothesis the timing question was raised to test: per-file cost amortizes hard after
the first query, one-time setup (~4.4s) dominates, not a linear-in-file-count cost. But this still
implied a per-file model (~0.21s x 2226 files ~= 467s, worse than naive hope) **until checking
whether a bulk mode exists** -- and it does: `IndexingFileSettingsRequest.filePath: String?`'s own
doc comment says `nil` returns info for **every file in the target in one call**, exactly mirroring
what `-showBuildSettingsForIndex` itself already does per-target. Tried it, same session:
**`filePath: nil` returned all 1457 files of the `Ls_net_ru` target in 9.57 seconds, one call.**

**Real, validated cost model for one target**: ~4.4s one-time setup + ~9.6s one bulk query =
**~14 seconds total** for every file in a real 1457-file target -- not 8.2s (misleadingly low, one
file) and not 467s (misleadingly high, naive per-file extrapolation without checking for a bulk
API). Consistent with, and now empirically confirming, `-showBuildSettingsForIndex`'s own
"~16-20s per target" figure from the other doc -- this mechanism is priced the same as that one,
just correctly platformed. Item 3 (proper timing, prerequisite the reviewer correctly ranked above
the original item 1) is closed.

## Step 8 — Items 2 and 4 merged: this is one Xcode-version-robustness risk, not two

Correctly reframed: the bundle-location strategy (Step 6) and the wire-protocol compatibility risk
are not independent concerns -- both derive from the same fact, that this spike talks to
**Xcode's own installed, closed-source `SWBBuildService.bundle`** using **this locally-built
open-source Swift client's own message schema**. If a future Xcode ships a `SWBBuildService`
speaking a materially different protocol version than whatever `swift-build` commit this project
would pin as a dependency, both break together: the bundle is still found (Step 6's path-derivation
logic doesn't care about version), but message (de)serialization could fail or silently
misbehave, and any protocol drift shows up as *both* problems at once, diagnosed and fixed as one
unit, not two independent bugs. Not measured here (would need a second, differently-versioned Xcode
installation to observe directly) -- recorded as a single open risk, "Xcode/swift-build version
skew," not as separate bundle-location and protocol-compatibility line items.

## Step 9 — DerivedData path reuse: a requirement, confirmed honored below

The standalone throwaway spike package's `SWBArenaInfo` paths were hand-typed to match one known
run's private DerivedData location. Flagged here, before wiring the real integration (Step 10), as
a requirement, not a suggestion: the arena's paths must come from the *same* `derivedDataPath`
every other consumer already uses, not a second, independent computation -- duplicating it would
repeat, in the path dimension, the exact class of silent-divergence bug this whole investigation
started by finding in the platform dimension. Confirmed done correctly once Step 10's real
integration existed: `SwiftBuildCompilerArgumentsProvider.init(container:scheme:derivedDataPath:)`
takes `derivedDataPath` as a parameter from its caller (`makeCompilerArgumentsProvider`, the same
`URL?` already threaded to `LiveXcodeCompilerArgumentsProvider` -- computed once, upstream, by
`PrivateDerivedDataLocator`), and only derives `Build/Products`/`Build/Intermediates.noindex`/etc.
as subpaths of that one shared value. No independent path computation exists in this provider.

## Step 10 — Full end-to-end comparison against Project Iris: exact parity, real speedup

Wired `SwiftBuildCompilerArgumentsProvider` as a real (temporary) `CompilerArgumentsProviding`
conformer in `swift-isolation-map` itself (`Sources/ProjectResolution/
SwiftBuildCompilerArgumentsProvider.swift`), gated by an undocumented
`SWIFT_ISOLATION_MAP_SPIKE_SWIFTBUILD` env var in `makeCompilerArgumentsProvider` -- same
throwaway-spike-toggle pattern as the earlier `-showBuildSettingsForIndex` Run B, never a real CLI
flag. Required temporarily: adding `swift-build` as a real `Package.swift` dependency (`.package
(path:)` to the local clone) and bumping this project's own `platforms: [.macOS(.v13)]` to `.v15`
(`SwiftBuild`'s own minimum). Both reverted after this comparison.

**First attempt (v1) queried only the scheme's own primary target and looked badly broken** --
`crossActorBoundaries` 1790 -> 4883, `unspecifiedIsolation` 114 -> 695, the tool's own "70% edges
unresolved" warning firing, superficially identical in shape to Run B's platform-bug damage. Root
cause was different and specific to this implementation, not the mechanism: a real scheme's build
graph compiles project files across *several* targets (this project's own `lsboutiqueContentExtension
-Release`/`lsboutiqueNotifications-Release` extensions, confirmed by grepping the real `-verbose`
log's own `(in target '...')` annotations), each a distinct GUID, and `generateIndexingFileSettings`
is scoped per `targetID` -- querying only the primary target silently missed every file exclusive to
the others. Fixed by iterating every target in `workspaceInfo.targetInfos` (303 total, including
every CocoaPods target) and merging their file maps, mirroring what `-showBuildSettingsForIndex`
already does structurally (its own JSON is keyed by every target in the workspace, not one).

**v2, after the fix**:

| metric | Run A (honest rebuild) | Run C v2 (`swift-build` direct) |
|---|---|---|
| `crossActorBoundaries` | 1790 | **1790** |
| `highRiskBoundaries` | 1472 | **1472** |
| `unspecifiedIsolation` | 114 | **114** |
| live-fallback resolved | 8638/10180 (85%) | 10046/10180 (98.7%) |
| external oracle resolved / unknown | 3788 / 1472 | 3844 / 96 |
| total wall time | ~12.6 min | **8:07** |

Edge-level diff (same `callerUSR`/`calleeUSR`/file/line key as every prior comparison in this
project): **1751 shared edges, 0 missing, 0 new, 0 changed** -- not merely matching summary counts,
every single edge's `risk`/`isolation`/`isUnknown` is identical between the two runs.

**This is the definitive validation**: unlike Run B (device args, `crossActorBoundaries` +185%,
mostly spurious `unspecifiedIsolation` noise), Run C v2 (correct-platform `swift-build` direct
args) reproduces the honest run's output exactly, in ~35% less wall-clock time on this real,
~2200-file, 303-target corpus. The mechanism itself is proven sound end-to-end, not just at the
single-file/single-target level Steps 3-7 validated.

The live-fallback/oracle *diagnostic counts* (not the edges) are not just close but *better* than
the honest run (10046/10180 vs 8638/10180 resolved; 96 vs 1472 unknown) -- large enough a gap that
it was flagged before treating "exact parity" as fully closed. Investigated directly in Step 10a.

## Step 10a — The oracle resolved/unknown gap, traced, not just called "plausible"

Correctly challenged before being accepted: if the oracle resolves ~1376 more external USRs in
Run C v2, some of that should show up somewhere -- either it changes an edge (which the diff says
it doesn't, anywhere) or the gap is a property of what the diagnostic counts versus what an edge
actually is, and that distinction needed to be shown, not asserted. Checked directly:

1. **First red flag, already in Run A alone**: 1472 raw `unknownUSRs` in the honest run's own
   diagnostic count, but only **28** edges in that same run's own report carry `isUnknown: true`.
   A ~50x gap exists *within a single run*, before comparing anything across runs -- `unknownUSRs`/
   `backfilledDeclarations` are `Set<String>`/`[String: DeclarationInfo]` keyed by every *distinct
   external USR* the oracle was ever asked about project-wide (`ExternalIsolationBackfill.swift`),
   not scoped to USRs that end up as a `caller`/`calleeUSR` of a surviving reported edge. Confirms
   the two counters were never expected to move in lockstep -- this is what the metric measures,
   not a defect in it.
2. **Full `nodes` diff (every analyzed declaration, not just edges)**, keyed by USR: 49,614 shared,
   1,369 only in Run A, 1,424 only in Run C v2. Checked their file locations directly: **1,369/1,369
   (100%) of Run-A-only nodes, and 1,408/1,424 (98.9%) of Run-C-only nodes, are in `*Tests.swift`/
   `Mock.swift`-style test-support files** -- the exact fingerprint of this project's own already-
   documented, independently-tracked `DeclarationExtractor` local-declaration-leak bug
   (this project's own local-declaration-leak task, tracked separately: local `let`/`var` bindings
   inside function/test bodies leak as phantom type members, and *which* ones survive linking is
   run-to-run nondeterministic, tied to live-fallback timing/ordering, not to the compiler-argument
   source). This node churn predates this spike and is orthogonal to it.
3. **Of the 49,614 shared USRs, exactly 5 have a different `isolation` value between the two runs**:
   `UIApplication`, `MockWindow`, `MockWindow.get`/`.set`, `MockNavigationController` -- all
   `nonisolated` (Run A) vs `globalActor(MainActor)` (Run C v2). Checked each one's `location`
   directly: `syntactic:UIApplication` has `location: ("", 0)` in **both** runs -- a real, literal
   phantom placeholder (`DeclarationLinker`'s own documented "no primary declaration, isolation-less
   placeholder" case), never a project-local declaration at all, so its isolation is whatever the
   external oracle most recently backfilled -- Run C v2's `globalActor(MainActor)` matches the real,
   documented UIKit fact (`UIApplication` is `@MainActor`-annotated in the current SDK); Run A's
   `nonisolated` reflects the oracle failing to resolve it that run. `MockWindow`/
   `MockNavigationController` are messier -- Run A links them to a real source location
   (`Mock.swift:106`/`53`, a `Tests` file), Run C v2 has no location for them at all, consistent
   with the same local-declaration/Tests-target nondeterminism from point 2 rather than a new bug.
4. **Checked whether any of these 5 USRs appear as `callerUSR`/`calleeUSR` in any edge, in either
   run's full edge list -- zero matches, in both.** They cannot have changed the edge diff, because
   they never participate in an edge at all, in either run.

**Conclusion, not just "plausible"**: the oracle resolved/unknown counter gap is explained --
mostly by a metric that counts a much broader universe of USRs than what reaches an edge (already
true within Run A alone, independent of this comparison), and where a real isolation difference
does exist between runs (5 USRs), none of them touch the report's own boundary output, and where
traceable, the difference looks like a genuine improvement (a real UIKit fact resolved correctly)
riding on top of a pre-existing, independently-documented local-declaration nondeterminism, not a
new defect this spike introduced. The "0 changed" edge-diff claim is verified, not coincidental --
directly confirmed by checking that none of the diverging USRs could have touched it.

## Step 10b — Tested and falsified: the node churn is not what's causing the oracle gap

Points 2 and 3/4 of Step 10a were presented as separate observations (node churn; oracle-count
gap), not explicitly linked -- correctly challenged: `~1,400` (node churn) and `1,376` (oracle
`unknown` delta) are close enough in magnitude that a direct causal link deserved testing before
being ruled out by omission, not just left as two coincidentally-similar numbers.

`ExternalIsolationBackfill`'s own doc comment names exactly two, and only two, real trigger
mechanisms for an external oracle query: **(1) edge-level** -- a project-local declaration calling
an external symbol (the *canonical* call site for that `calleeUSR`), and **(2) declaration-level**
-- a project-local type's protocol conformance to an external protocol. If the ~1,400 diverging
leaked nodes were the source of the ~1,376-USR gap, they'd have to trigger one of these two ways.
Checked both, directly:

- **Trigger 1 (calls)**: intersected the diverging node USR sets against `callerUSR`/`calleeUSR`
  across every edge in their own run. **Zero matches, in both directions, in both runs** -- none of
  the 1,369 (honest-only) or 1,424 (swift-build-only) nodes are the caller *or* callee of any edge
  at all. They cannot be feeding edge-level oracle queries because they don't participate in the
  call graph's externally-visible portion at all.
- **Trigger 2 (conformances)**: classified every diverging node by name shape (capitalized/type-
  like vs. `test*`-prefixed vs. lowercase-var-like). **The honest-run-only set (1,369 nodes) contains
  zero type-like names** -- 356 are `XCTest` methods, 1,013 are lowercase local vars/params/
  properties, matching the leak bug's own documented shape exactly (local bindings inside function
  bodies), none of which are a nominal type capable of declaring a protocol conformance at all.
  Since Run A is the side that needs *more* external queries to explain (1,472 vs. 96 unknown), and
  its own unique nodes contain zero conformance-trigger candidates, trigger 2 cannot explain the
  gap either. (The swift-build-only set does contain 39 type-like names -- all real `XCTestCase`
  subclasses and `Mock*` helper classes already present under their real/canonical USR in the
  *shared* 49,614-node set; these are leaked duplicate placeholders of already-resolved
  declarations, not a new query source, and irrelevant to explaining Run A's higher unknown count
  regardless.)

**Falsified, not just unconfirmed**: the node churn and the oracle resolved/unknown gap are two
independent phenomena that happen to be similar in magnitude, not one causing the other -- neither
of `ExternalIsolationBackfill`'s two real trigger mechanisms connects them. Step 10a's original
point 1 (the counters were never scoped to the same universe as edges in the first place) remains
the operative explanation for the gap's *existence*; its precise *size* (why 1,376 and not some
other number) is still not fully accounted for and is left open rather than assumed -- plausibly a
genuine completeness difference from querying all 303 targets exhaustively (Step 10's own original
hypothesis) rather than anything traced to a defect, but not chased further here since it has no
demonstrated effect on the report's own edges (Step 10a, point 4).

## Step 10c — Version-skew risk (Step 8) tested directly: Xcode 27.0 Beta 5, no compatibility issue

Step 8 identified the version-skew risk but left it untested ("would need a second, differently-
versioned Xcode installation to observe directly"). A second Xcode became available
(`Xcode-27.0.0-Beta.5.app`, a full major version ahead of the `Xcode-26.4.0.app` install used for
every other step in this doc, protocol/build identifier `25183.74.15`) -- tested directly rather
than left open.

Pointed the same locally-built spike client (compiled against whatever `swift-build` commit was
cloned for this investigation, contemporary with Xcode 26.4) at Xcode 27's own bundled
`SWBBuildService.bundle` (`SWBBUILDSERVICE_BUNDLE_PATH` override, not `xcode-select`, so the
system-wide default stayed untouched at 26.4 throughout). Real query against the same real Project
Iris workspace:

```
TARGET: arm64-apple-ios15.6-simulator
iphoneos occurrences: 0
iphonesimulator occurrences: 156
```

**No protocol failure, no crash, no malformed response, no silent corruption** -- a real, correctly
-platformed, non-empty result came back from a `SWBBuildService` binary a full major Xcode version
ahead of the client code's own. (The reported `-sdk` path itself still resolved under
`Xcode-26.4.0.app` rather than `Xcode-27.0.0-Beta.5.app` -- an artifact of this spike passing
`developerPath: nil` to `createSession`, which falls back to whatever `xcode-select -p` still
points at, not a version-compatibility finding; irrelevant to what this step tested, which was
whether the 27.0 *service process* could parse a request from, and return a well-formed response
to, this *client's* message schema.)

**Not a full close of Step 8** -- one successful cross-version query on one project is evidence,
not exhaustive validation (a real implementation would still want this exercised in CI across
whatever Xcode version range it claims to support, and a *protocol-rejection* failure mode was
never actually exercised here, so it's not yet known what a genuine incompatibility would even look
like from this client's side -- a clean error, a hang, or a malformed-but-not-obviously-wrong
response). But the specific, concrete fear (that a version gap silently breaks or corrupts results)
did not materialize across a real, non-trivial version gap (stable -> beta, N -> N+1 major).
Downgrades this from "untested, real risk" to "tested once successfully, still worth exercising
more broadly before shipping."

## Step 11 — Overall conclusion

Every item from Step 4's original "not yet proven" list is now closed, plus two more the review
process surfaced along the way (timing methodology, target-coverage completeness):

1. **Real query correctness** (Step 3): correct simulator target/SDK/DerivedData paths, zero
   `iphoneos` contamination.
2. **`cursorInfo` parity** (Step 5): byte-for-byte identical to the honest build's own args at
   every probed offset.
3. **Bundle location without hardcoding** (Step 6): `xcode-select -p`-relative, no env var needed.
4. **Honest timing model** (Step 7): ~14s per target (not 8.2s misleadingly low, not 467s naively
   extrapolated) -- caught and corrected before being trusted further, per the reviewer's own
   explicit reprioritization.
5. **Version-skew risk** (Step 8): identified as one real, unresolved risk (not two independent
   ones), not yet stress-tested against a second Xcode version.
6. **DerivedData path reuse** (Step 9): confirmed correct in the real integration, not duplicated.
7. **Full real-corpus end-to-end parity** (Step 10): exact edge-level match to the honest run,
   ~35% faster, after fixing a real target-coverage gap the first attempt exposed.
8. **Oracle resolved/unknown count gap** (Step 10a/10b): traced and the causal hypothesis tested
   and falsified, not just called plausible -- confirmed the diverging USRs never touch a reported
   edge in either run, and directly ruled out node-churn as the gap's cause via both of
   `ExternalIsolationBackfill`'s real trigger mechanisms.
9. **Version-skew risk** (Step 8, tested in Step 10c): a real, non-trivial version gap (stable
   Xcode 26.4 client talking to Xcode 27.0 Beta 5's service) produced a correct, uncorrupted result
   -- not exhaustive proof across every version pair, but the specific feared failure mode (silent
   breakage/corruption) did not occur where tested.

**Net assessment**: this is now a substantially more validated, more promising path than
`-showBuildSettingsForIndex` ever was -- that mechanism was conclusively disqualified (the other
doc's Step 7/8). This one has passed every test applied to it, including ones added specifically
*because* they might have disqualified it -- version skew included, once a second Xcode became
available to actually test it against rather than leave as a theoretical risk. Nothing found here
disqualifies it the way the platform-selection bug disqualified the CLI-based mechanism.
Remaining before this could become a real, shippable feature (not further spiking): a documented
decision on the `swift-build` dependency (weight, pinning strategy, whether to vendor or depend on
a tagged release instead of a local clone), a real (non-spike) `CompilerArgumentsProviding`
conformer with tests, and the standard Hypothesis(done)->Spike(done)->Documentation(done)->Code->Tests->
Results->PR cycle for turning it into a shipped, flag-gated feature.

**Forward-looking caveat, not a blocker on this spike's own conclusion**: Step 10b traced *why* the
oracle resolved/unknown gap exists (two independent phenomena, not causally linked) and confirmed
it has zero effect on this run's edges, but deliberately left the gap's exact *size* (why 1,376 and
not some other number) unexplained -- reasonable here, since the A/B edge-diff is what this
comparison actually needed to trust. If this counter is ever surfaced as a standalone health/quality
signal on its own (e.g. in production verbose logs, watched across runs rather than compared A/B
against a known-good baseline), its absolute value would start to matter on its own terms, and this
open question should be revisited before trusting it that way.

## Step 12 — Shipped: real code, tests, and one more real-corpus confirmation

Formalized into the real tool, behind `--experimental-swift-build-compiler-args` (off by default,
same convention as `--experimental-index-store-module-filter`):

- **`Sources/ProjectResolution/SWBBuildServiceLocating.swift`** -- `SWBBuildServiceLocating`
  protocol + `LiveSWBBuildServiceLocator`, mirroring `ToolchainLocating.swift`'s exact shape
  (`xcode-select -p`-relative, injected `ProcessRunning`/`FileSystemQuerying`, no hardcoded Xcode
  path). 5 unit tests (`SWBBuildServiceLocatingTests.swift`), including a real bug this caught
  during *this step's own* implementation, in code that's new here, not a regression of anything
  Step 6 already validated (that step proved the *path-discovery* mechanism itself, `xcode-select
  -p`-relative with no hardcoded path -- a different concern from this one): the first draft of
  this new locator's own existence check used `fileExists(at:)`, which deliberately excludes
  directories in this project's own `FileSystemQuerying`, and `.bundle` *is* a directory -- that
  draft would have failed on every real Xcode install; caught by a test before it ever ran for
  real, never shipped or observed against a live system.
- **`Sources/ProjectResolution/SwiftBuildCompilerArgumentsProvider.swift`** -- the real
  `CompilerArgumentsProviding` conformer, with its parsing (`parseIndexingFileSettings`, raw
  `[[String: SWBPropertyListItem]]` -> `[file: args]` + module names) and arena-path construction
  (`arenaInfo(derivedDataPath:)`) factored into pure, directly-testable static functions -- neither
  needs a live `SWBBuildService` session to exercise, matching how `CompilerArgsLogParser`'s own
  pure/live split already works in this codebase. 8 unit tests
  (`SwiftBuildCompilerArgumentsProviderTests.swift`) against real-shaped fixtures. `derivedDataPath`
  is a required `init` parameter, never recomputed (Step 9's own requirement, honored in the real
  code, not just the spike).
- **`Package.swift`** -- `swift-build` pinned to the exact commit
  (`2e916b2d01fcacc825c50e28b15b7b2483860caf`) this entire investigation validated against, not
  floated on a branch (no semver tags exist upstream, only toolchain-release snapshot tags).
  `platforms` bumped `.v13` -> `.v15` (`SwiftBuild`'s own minimum).
- **Full test suite**: 531 tests (up from 518 pre-feature), all passing.
- **Real-corpus confirmation, the shipped code path, not the spike's**: ran
  `--experimental-swift-build-compiler-args` against Project Iris one more time, end to end.
  `crossActorBoundaries` 1797 vs. the honest baseline's 1790, `highRiskBoundaries` 1472 (exact),
  `unspecifiedIsolation` 116 vs. 114. Edge-level diff: **1751 shared, 0 missing, 0 changed, 7
  extra** -- every honest-run edge reproduced exactly; the 7 extra are additional resolved
  boundaries, not lost or altered ones, consistent with the same pre-existing local-declaration-
  leak nondeterminism Step 10a/10b already traced and ruled orthogonal to this feature (that
  investigation's Run C v2 happened to draw zero extra edges from the same source; this run drew
  seven -- both are within the same already-understood, already-benign nondeterminism, not a new
  finding).

Ready for PR. (This closed out PR #103/#104's own shipped feature; Step 13 below is a separate,
still-open follow-up investigation, not a reopening of this conclusion.)

## Step 13 -- WordPress-iOS's residual ~12% divergence (post-#106), traced further but not yet closed

Referenced from PR #106's own commit message as "UPDATE 8" before this section existed -- #106
fixed `preferredArguments`'s target-selection heuristic for a file compiled by more than one
target (a real WordPress-iOS shape: `WordPressShareExtension`/`WordPressDraftActionExtension`/
`JetpackShareExtension`/`JetpackDraftActionExtension` all share one
`PBXFileSystemSynchronizedRootGroup`), but its own commit message already flagged that the fix
alone didn't close the edge-level gap. Continued here, against the real WordPress-iOS corpus (497
targets, 5553 files), rather than left as an open note.

**Environment note, not a project finding**: every long-running invocation in this session's own
real corpus runs was externally `SIGKILL`ed by `launchd` mid-run ("teardown of process-scoped
services after host exited"), repeatedly, at intervals as short as ~5 minutes -- confirmed via
`log show`, affecting unrelated processes (Safari, mDNSResponder helpers) too, so a host/session-
level condition outside this project's own control, not a tool bug. `caffeinate` did not prevent
it (rules out plain idle sleep). Real full-corpus runs only completed on retry.

**Reproducibility baseline established first**: two independent honest (`xcodebuild -verbose`)
runs against the identical, unchanged private index store are **byte-for-byte identical, 0
missing/extra/changed edges** across the entire 6617-edge report -- `DeclarationLinker`'s own
bulk-linking tie-break (`disambiguate`) is confirmed fully deterministic for this corpus, not a
source of run-to-run noise. This matters because it rules out "just nondeterminism" as the
explanation for anything found below.

**The honest run's own new finding**: even a from-scratch honest run on this corpus prints "55%
of cross-isolation edges have unresolved isolation" -- traced to `LiveXcodeCompilerArgumentsProvider`'s
own `-verbose` clean-build failing to capture compiler invocations for a large fraction of this
497-target corpus's own targets (plausibly many CocoaPods targets not cleanly buildable under a
forced iphonesimulator destination + disabled code signing), independent of this feature's own
flag entirely -- an orthogonal, pre-existing honest-path limitation on a corpus this large, not
something this investigation set out to fix.

**Edge-level diff (honest vs. flagged, both against the identical index store)**: 834 total
differing edges (344 honest-only, 425 flagged-only, 65 changed) -- **100% confined to exactly 21
files**, all under the four shared-target directories above. Confirms the divergence is real,
narrow, and exactly where #106's own commit said it would be.

**#106's own fix confirmed correct, directly, not by inference**: a live, isolated probe --
constructing a real `SwiftBuildCompilerArgumentsProvider` against this same corpus and calling
`compilerArguments(forFile:)` directly for six of the 21 diverging files -- returned
`WordPressShareExtension` every time (6/6), including three files whose edges diverged in the
full-pipeline run. Calling `LocalDeclarationLiveFallback.resolveOne` directly with this provider,
at the exact (file, line, column) of one diverging declaration
(`ShareCategoriesPickerViewController.indentationLevelForCategory`), reproduced the **honest run's
own USR byte-for-byte**
(`s:23WordPressShareExtension0C30CategoriesPickerViewControllerC27indentationLevelForCategory...`)
-- not the `WordPressDraftActionExtension`-qualified USR the full `flagged4.json` run actually
produced for that identical declaration. Repeated 3 more times independently: no flakiness, same
correct answer every time.

**Where this leaves it, honestly**: the target-selection *logic* (#106) is directly verified
correct, in isolation, every time it was tested. Yet the real, full-pipeline
`--experimental-swift-build-compiler-args --oracle-workers 8` run against the real corpus produced
a *different, wrong* answer for the same declaration. Two candidate explanations for what the
isolated probe couldn't exercise were formed and **both directly tested and falsified**, not left
as unconfirmed theories:

1. **Query-flakiness hypothesis, falsified.** Added per-target failure logging to
   `SwiftBuildCompilerArgumentsProvider.runAsync`'s previously-silent `catch`/`continue` branch
   (now reports `writeStderr` with every failed target's own name once, alongside the existing
   summary line) and re-ran the full pipeline under real load. Result: **497/497 targets
   succeeded** -- zero failures, `WordPressShareExtension` included -- yet the edge-level diff
   reproduced **exactly** the same 344/425/65 split and the same 351/29
   `WordPressDraftActionExtension`/`WordPressShareExtension` `callerUSR` module skew as the first
   run. Deterministic and load-independent, not flaky. This hypothesis is closed, ruled out.
2. **Worker-subprocess-dispatch hypothesis, falsified.** Called
   `LocalDeclarationLiveFallback.resolveInParallel` directly with `workerCount: 8` and a real
   `workerExecutablePath` (the actual built binary, so this exercises genuine
   `swift-isolation-map --local-declaration-worker-input ...` subprocess respawns, not a
   simulation) against the same diverging declaration (`ShareCategoriesPickerViewController
   .indentationLevelForCategory`, padded to 10 total items so the parallel path's own
   `count >= workerCount` guard actually fires instead of falling back to the sequential path).
   Both `resolveSequentially` and `resolveInParallel` returned the identical, **correct**
   `WordPressShareExtension`-qualified USR. The worker-subprocess mechanism itself -- JSON
   serialization of `compilerArgsByFile`, the real subprocess respawn, `StaticCompilerArgumentsProviding`
   reconstructing the cache on the other side -- is confirmed correct at this scale.

Both of the concrete, testable explanations for "isolated probe correct, full run wrong" have now
been eliminated with direct evidence, not just reasoned around. What remains is either something
that only manifests at the **real 36002-item, ~4500-items-per-worker scale** (unlike the 10-item
probe above) -- e.g. `sourcekitd`'s own internal AST-cache behavior under sustained load within one
worker's long sequential loop over many files -- or a mechanism this investigation hasn't
identified yet outside `LocalDeclarationLiveFallback` entirely (e.g. `MultiTargetDeclarationAliasing`
-style USR aliasing rewriting an already-correct answer post hoc). Neither is confirmed; both are
speculation at this point, flagged as such rather than presented as findings.

**Status**: real, narrow, well-localized (21 files, 834 edges out of 6617), fully deterministic
across repeated full runs (not flaky). Root cause of the *selection logic* (#106) is closed
(correct). Root cause of *why the full pipeline doesn't reliably reach that correct answer* is
still open after ruling out the two most concrete candidate mechanisms with direct evidence --
next step, if picked back up, needs either a scale-faithful repro (thousands of items through one
worker, not ten) or instrumentation inside `sourcekitd`'s own request path, since black-box
probing at small scale has now been exhausted without reproducing the bug.

This write-up itself is complete as an investigation record -- not a claim that the underlying
root cause is closed. Nothing in this step's own code changes (the diagnostic logging added to
`SwiftBuildCompilerArgumentsProvider.runAsync`) needs to block on the open question above; that
logging is a real, defensive improvement (a previously-silent failure mode is now visible) that
stands on its own merits regardless of how the root cause investigation concludes.

## Step 14 -- A real, separate deadlock found and fixed while pursuing the two Step 13 leads

Pursuing Step 13's own two remaining leads (scale-faithful repro; instrumentation) surfaced a
different, real, independently significant bug -- not the original one, but confirmed and fixed on
its own merits rather than left as a distraction.

**Scale-faithful repro, both variants, still didn't reproduce the original bug.** A sequential
5401-item repro (one process, ~30 min) resolved the target declaration correctly every time. 5401
is this probe's own actual constructed count (600 sample files x 9 probed lines each, plus the one
target item) -- deliberately built to meet or exceed Step 13's own back-of-envelope ~4500-per-worker
estimate (36002 unresolved / 8 workers), not a re-measurement of that estimate; the two numbers are
independent and both real, not in tension. A genuinely concurrent repro (8 real worker subprocesses,
driven through `swift test --filter`) hung indefinitely instead -- twice, once for 11 hours before
being killed.

**The hang was real, not slow progress -- confirmed via `sample`, not assumed.** A backtrace of the
hung process showed the exact shape: one thread parked in
`SwiftBuildCompilerArgumentsProvider.run()`'s `semaphore.wait()` (line 107, the winner of
`loadIfNeeded()`'s `NSLock`, waiting for its own inner `Task` to run `runAsync()`), and every other
concurrent thread parked on that same `NSLock` (`loadIfNeeded()` line 62) -- all on cooperative-pool
threads, since every caller here originates from `LocalDeclarationLiveFallback.resolveInParallel`'s
own `withTaskGroup`. With enough concurrent first-callers, every pool thread ends up parked on the
lock, leaving none free to run the winner's own inner `Task` -- a permanent hang. The exact same
"libdispatch cooperative-pool exhaustion" class already fixed once in this project
(`LiveProcessRunner`'s own doc comment, a prior real deadlock from blocking on `DispatchQueue
.global()`-submitted work).

**Why production doesn't normally hit this**: `SwiftIsolationMap.run()` calls
`detectConfiguredDefaultIsolation` (line 298), a sequential loop over every source file, *before*
`resolveLocalDeclarationFallback`'s own concurrent dispatch (line 405) -- its first call warms the
same shared provider instance's cache well before any concurrent access begins. This is accidental
protection from calling-order, not a structural guarantee.

**First fix attempt, tested and falsified**: wrapping `run()`'s `Task { await self.runAsync() }` in
`Thread.detachNewThread` (mirroring `LiveProcessRunner`'s own fix shape as closely as possible) did
**not** fix the hang -- re-confirmed via the identical `sample` backtrace afterward. The reasoning
error, caught by testing rather than trusted on inspection: that change only moved *which* thread
spawns the `Task`, not *which* thread blocks -- the calling thread (from `withTaskGroup`, a
cooperative-pool thread) still parks directly on `semaphore.wait()`/`lock.lock()` either way, so
pool exhaustion is unchanged. `LiveProcessRunner`'s own fix works for a structurally different
reason: it moves the *actual blocking work* (`readDataToEndOfFile()`, a plain synchronous call with
no `async` body needing a pool thread of its own) onto a dedicated thread entirely, not just the
act of spawning something. That shape doesn't transfer to a case where the awaited work is itself
genuine `async` Swift code that must run on the cooperative pool no matter which thread requests it.

**Real fix, verified against the exact cold-race condition that hung before**: a single warm-up
call, `_ = try? compilerArguments.compilerArguments(forFile: unresolved[0].location.file)`, added to
`LocalDeclarationLiveFallback.resolveInParallel` immediately before it builds chunks/spawns workers
-- makes the same protection `detectConfiguredDefaultIsolation` provides today only by accident
into a real, local guarantee of this function itself. Verified empirically, not just by inspection:
a standalone (non-`swift test`) reproduction harness -- built as a temporary `diagnostic-probe`
executable target, after `swift test --filter`'s own `swiftpm-testing-helper` wrapper was ruled out
as a confound by comparing hung-via-test vs. instant-via-standalone-binary behavior for the same
repro -- hung with the exact same `sample`-confirmed backtrace *without* this call, and completed in
~60s the moment the same warm-up call was added ahead of concurrent dispatch. The standalone probe
could not, in the end, link directly against the real `LocalDeclarationLiveFallback.resolveInParallel`
itself (a `.executableTarget` depending on another `.executableTarget`'s public symbols failed to
link in this SwiftPM/toolchain version even after a fully clean rebuild, both release and debug,
despite the identical dependency style already working for `swift-isolation-mapTests`'s own
`@testable import` -- a real, reproducible environment limitation, not a stale-cache artifact, and
not investigated further since it wasn't this task's own goal) -- so the probe re-implemented the
identical dispatch shape (same provider class, same real worker-subprocess wire format, same
real built binary spawned in `--local-declaration-worker-input` mode) rather than calling the
production function directly. The fix landed in the real function; the verification is of an
architecturally identical harness, not the exact call site -- noted as a real gap, not glossed over.

**Full test suite**: 537 tests, all passing, ~60-90s (no regression from this fix).

**Status**: this specific deadlock is fixed and merits its own consideration for landing regardless
of Step 13's original question, which remains open. It does not, on its own, explain Step 13's
original "wrong module" divergence -- it's a hang, not a wrong-but-valid answer, and production's
own call ordering was already accidentally immune to it before this fix made that immunity
structural. Step 13's own two leads (scale-faithful repro, sourcekitd instrumentation) were both
attempted; the first is now exhausted (both sequential and, after this fix, genuinely concurrent
scale repros complete without reproducing the original divergence); the second (sourcekitd request
-path instrumentation), attempted next, is what finally found the real mechanism -- see Step 15.

## Step 15 -- The real mechanism: DeclarationLinker.link() conflates a sibling target's own compiled
## unit with a genuinely external callee

Temporary instrumentation added to `LocalDeclarationLiveFallback.resolveOne` logged every real
`cursorinfo` request/response for a call site inside the four shared-target directories, to a
fixed path every worker subprocess could append to (plain stderr is silently discarded there --
`runWorker` never reads `ProcessResult.standardError`). Re-ran the full flagged pipeline once more
against WordPress-iOS with this in place.

**First result, surprising and clean**: every single logged query (316 of them) carried
`argsModule=WordPressShareExtension` -- **zero** `DraftActionExtension`-argued queries, ever, in
this run. Yet the same run's own report reproduced the identical 344/425/65 divergence, same
351/29 module skew, as every prior attempt. `SwiftBuildCompilerArgumentsProvider`'s own args are
provably not the vehicle for *any* of these declarations' final identity.

**Checked directly, not assumed: how many of the 483 distinct diverging `(file, line)` locations
were even live-fallback-queried at all?** Only 63 -- **13%**. The other 420 (87%) never call
`resolveOne` in this run. Whatever's producing the wrong module for the large majority of this
divergence lives entirely outside the compiler-arguments/live-fallback path this whole investigation
(Step 13, the original `#106` fix, Step 14's deadlock) had been focused on.

**Checked the real index store directly for one such declaration**
(`ShareModularViewController.swift`, `WordPressShareExtension`'s own real on-disk file):
`RawIndexStoreClient.definedSymbols(inFile:)` returns 540 real candidates for this file -- **zero**
of them `DraftActionExtension`-qualified. Confirmed stable across three independent scans in the
same process, including one with a real `SwiftBuildCompilerArgumentsProvider` query (a full
497-target `SWBBuildService` session) run in between -- ruling out any filesystem-ordering
perturbation from that activity as a contributing factor. **This file's own declarations are never
indexed under `WordPressDraftActionExtension` at all**, by this measure.

**Correction (Step 17): this "zero" claim was wrong, caught later, not left standing.** The probe
that produced it only ever printed the first 30 of the 540 candidates (`.prefix(30)`) and grepped
*that printed output*, never the full in-memory array `candidateSummary()` actually returned. A
later, real check of the complete list (Step 17) found the true split is **267
`WordPressShareExtension` / 267 `WordPressDraftActionExtension`** -- close to perfectly symmetric,
not zero. The same check across all 21 diverging files found the identical near-50/50 pattern in
every one of them. There is no declaration/call-graph-scan inconsistency in the raw index data --
both scans agree throughout. This project's own "compile every line, don't extrapolate" discipline
applies to this investigation's own probes too; the paragraph below (the "internal inconsistency"
framing) is kept for the historical record but is **not accurate** -- see Step 17.

**Yet `RawIndexStoreClient.callSites(inFile:)`, the exact same file, returns 1680 call-graph edges
-- 840 of them real, `DraftActionExtension`-qualified caller/callee USRs**, real method bodies
(`viewDidLoad`, `loadContentIfNeeded`, ...) with real line numbers. ~~The index store's own
declaration-scan and call-graph-scan disagree about whether `WordPressDraftActionExtension`'s own
compiled unit of this file exists at all -- it does, for call sites; it doesn't, for declarations~~
-- an internal inconsistency in the raw index data itself (or in how `indexstore`'s own definition
-vs-reference role marking behaves for an `@objc`-bridged class compiled into a *non-owning*
sibling target), not something this project's own code invented.

**The real bug, found by reading `DeclarationLinker.link()` with this in hand**
(`Sources/IndexStoreIntegration/DeclarationLinker.swift:325-346`):

```swift
let knownUSRs = Set(usrRewriteMap.values)
var rawCallGraph: [CallGraphEdge] = []
for realUSR in knownUSRs {
    rawCallGraph.append(contentsOf: indexStore.callGraphEdges(forUSR: realUSR))
}
// ...
let filesToQuery = Set(allDeclarations.compactMap { $0.location?.file })
for file in filesToQuery {
    for edge in indexStore.callSites(inFile: file) where !knownUSRs.contains(edge.calleeUSR) {
        rawCallGraph.append(edge)
    }
}
```

The second loop's own comment states its real purpose plainly: fold in edges whose callee
`callGraphEdges(forUSR:)`'s reverse lookup can't find, because the callee is genuinely **external**
(SDK/compiled-dependency code, never itself a `knownUSR`) -- exactly what the compiled-dependency
oracle needs. But the condition (`calleeUSR` absent from `knownUSRs`) cannot distinguish "genuinely
external" from "a sibling target's own compiled duplicate of a call this project already resolved
under a *different* module-qualified USR" -- and `knownUSRs` only ever contains **one**
module-qualified variant per shared declaration (`WordPressShareExtension`'s, per `disambiguate`'s
own single-winner tie-break, Step 13's own established fact). Every real `WordPressDraftActionExtension`
-qualified edge for a shared file is, by this test, indistinguishable from a real external call --
so it gets folded into `rawCallGraph` **as its own, separate, wrongly-identified edge**, standing
alongside the correct `WordPressShareExtension`-qualified edge for the identical physical call site.
This is a real, distinct gap from the already-fixed `MultiTargetDeclarationAliasing`
(`docs/task-multi-target-declaration-aliasing.md`) -- that fix backfills a *missing declaration's*
isolation info once its USR is already known to be a sibling-target duplicate (by mangled-suffix
match), so the duplicate edge's own isolation resolves correctly instead of `isUnknown: true` --
but it never touches the duplicate **edge's own identity**, so the edge itself survives, under the
wrong module, exactly as a second, real, but wrongly-attributed entry in the call graph.

**What's still open, honestly**: this explains where a `DraftActionExtension`-qualified edge for a
`WordPressShareExtension` source line comes from at all (a real, distinct duplicate, folded in by
this over-broad "not yet known" test). Whether both variants of a given physical call site actually
exist in `rawCallGraph` in *every* run turned out to be true for the one location checked directly
(Step 16) but **false for the majority of the other 833 diverging edges** (Step 16's own later
quantitative re-check) -- so this mechanism is confirmed as *a* real source of duplicate edges, not
yet confirmed as *the* explanation for why the raw duplicate itself is asymmetric per file/run in
most cases. Not yet traced: *why only one of the two duplicates survives into the final
cross-isolation report, and why which one survives differs between honest and flagged*, for the
large majority where the counterpart doesn't even show up as a node in the other run at all --
something upstream of `crossIsolationEdges()`'s own filtering (most likely `knownUSRs`'s exact,
per-file-varying membership) decides this, not yet mapped. See Step 16 for the full, honest
accounting of what does and doesn't generalize.

**Note on the 13%/87% split above and Step 16's separate mechanism**: these operate on different
axes, not the same question. The 63/483 vs. 420/483 split here is about whether a *declaration's own
identity* (its placeholder-to-real-USR resolution) required live-fallback at all. `ExternalIsolationBackfill
.query()` (Step 16) resolves the *isolation* of a caller/calleeUSR already absent from `declarations`
-- a question that applies uniformly to edges regardless of which side of this 13%/87% split their
caller's own identity came from. The two percentages aren't a partition of which mechanism "covers"
which edges; both mechanisms can matter for the same edge, at different points in the pipeline.

**Status**: root mechanism for the *existence* of wrong-module duplicate edges is found and
well-evidenced, not the same thing as Step 13's original divergence being fully closed. A real fix
candidate for the mechanism itself: the fold-in loop should skip an edge whose `calleeUSR`, rewritten
through the same mangled-suffix logic `MultiTargetDeclarationAliasing` already uses, matches an
already-`knownUSR` -- i.e., recognize a sibling-target duplicate *before* folding it in, not paper
over its isolation after the fact. Not implemented here -- this step is the investigation record,
not the fix; a real fix would need its own real-corpus before/after per this project's own standard
discipline, and this session's own recurring external-kill instability (Step 13) makes another
full WordPress-iOS run for that purpose a real cost to plan for, not undertake casually.

## Step 16 -- One representative case fully traced; does not generalize to the full 834-edge divergence

Continuing directly from Step 15's own open question. Temporary instrumentation added right after
`linker.link(...)` in `SwiftIsolationMap.swift`, dumping every raw (pre-cross-isolation-filter)
`linked.callGraph` edge at two known probe locations in `ShareModularViewController.swift` (line
549: `selectedModulesTableRowAt` calling `ModulesSection.init(rawValue:)`). One more full flagged
run against WordPress-iOS.

**Confirmed directly**: `linked.callGraph` contains **both** duplicate edges at line 549 --
`WordPressShareExtension`-qualified caller/callee *and* `WordPressDraftActionExtension`-qualified
caller/callee, four raw edges total (two call sites, two module variants each). Step 15's own
mechanism (the naive "not yet known" fold-in) is confirmed to produce both, exactly as reasoned
there, not just plausibly.

**Then checked node isolation for both variants, both runs, directly**:

| | `WordPressShareExtension` callee | `WordPressDraftActionExtension` callee |
|---|---|---|
| honest | `unspecified` (unresolved) | **`nonisolated`** (resolved) |
| flagged | **`nonisolated`** (resolved) | `unspecified` (unresolved) |

Exactly inverted between the two runs. Since `AnalysisReportBuilder`/`IsolationInferenceEngine`
apply no dedup at all (confirmed reading both, Step 15) and both duplicate edges' *nodes* are real
and present in both runs, the edge that "survives" into the final cross-isolation report in each
run is simply whichever duplicate's callee isolation resolves to something other than `unspecified`
-- both would otherwise be equally "crossing" and both would appear (checked -- neither is suppressed
by `build()`'s own carve-outs, all three are gated `!isUnknown` and this callee is `isUnknown` for
whichever variant fails to resolve).

**Root cause of the inversion, found by re-reading `ExternalIsolationBackfill.query()`
(`ExternalIsolationBackfill.swift:1108-1145`)**: this is a *second*, entirely separate consumer of
`compilerArguments.compilerArguments(forFile:)` -- Step 13/15's own instrumentation only ever
covered `LocalDeclarationLiveFallback.resolveOne`, never this one. `query()` runs a real `cursorinfo`
request at the *call site's* own (file, line, column) using whatever args this run's own provider
returns for that file, then calls `USRMatching.select(from: result, targetUSR:)` -- a **strict USR
-string-equality** search among the real result's candidates. `cursorinfo`, given one target's own
compiler arguments, only ever reports that same target's own module-qualified USRs. So:

- The module-qualified `calleeUSR` variant that happens to **match** whichever target this run's
  own compiler-arguments provider picked for this file resolves successfully (a real symbol-graph
  fact, `nonisolated`).
- The *other* module-qualified variant can never match (`cursorinfo` never reports that module's
  USR when queried with the other module's args) -- permanently `.unknown`, regardless of how many
  times it's queried.

**Why honest and flagged pick opposite targets for the identical file**: `SwiftBuildCompilerArgumentsProvider`
(flagged) has `preferredArguments`'s home-directory-match heuristic (#106) -- confirmed correct for
this file (`WordPressShareExtension`) in Step 13/15's own direct probes. `LiveXcodeCompilerArgumentsProvider`
(honest) has **no equivalent logic at all** -- confirmed by re-reading `XcodeBuildLogCompilerArgumentsProvider
.swift`'s `runVerboseBuild`: `parsed[file] = fullArguments` is a bare dictionary assignment inside a
loop over every real `swiftc` invocation `-verbose`'s own log contains, for every target that
compiled it -- whichever target's invocation the real `xcodebuild` build happens to log **last**
silently wins, with no target-name preference of any kind. For this specific file, on this specific
corpus, that arbitrary last-wins order happens to land on `WordPressDraftActionExtension`.

**For this one location (line 549)**, both runs are equally "arbitrary" for a file compiled by more
than one target -- flagged picked its one answer via a real, principled heuristic (#106); honest
picked its own, different answer via raw build-log ordering (`LiveXcodeCompilerArgumentsProvider`
has no equivalent preference logic at all -- confirmed by re-reading `XcodeBuildLogCompilerArgumentsProvider
.swift`'s `runVerboseBuild`: `parsed[file] = fullArguments` is a bare dictionary assignment inside a
loop over every real `swiftc` invocation the `-verbose` log contains for this file, across every
target that compiled it -- whichever invocation the real build happens to log **last** silently
wins). `ExternalIsolationBackfill.query()`'s strict-equality USR matching -- correct and necessary
for its own real purpose, distinguishing genuinely different declarations -- has no way to know
these two USRs name "the same call, from two targets" rather than two unrelated symbols, so exactly
one resolves and the other stays permanently `.unknown`.

**This was reported as "closed" in an earlier version of this step -- premature, caught on review,
not left standing.** The finding above was drawn from a single representative call site (two call
sites in one file, four raw edges) and generalized to a claim about the entire 834-edge divergence
without checking it. A real re-check, using data already on disk (`honest4.json`/`flagged7.json`, no
new corpus run needed) rather than another expensive one: for every `isUnknown: true` edge in the
344 honest-only and 425 flagged-only sets (315 and 385 of them respectively -- the large majority),
swap the caller/callee USRs' module name to what the *other* run would have used, and check whether
that swapped node explains the asymmetry the way line 549 did.

| outcome | honest-only (of 315) | flagged-only (of 385) |
|---|---|---|
| swapped variant resolves to the *same* isolation as its own caller (naturally non-crossing, matching this step's own line-549 mechanism) | 4 | 12 |
| swapped variant's callee has **no node at all** in the other run (the duplicate raw edge apparently never gets constructed there in the first place -- contradicts this step's own "both duplicates always exist in every run" claim) | 108 | 213 |
| swapped variant resolves to a *different* isolation from its caller -- would itself be a genuine crossing, yet doesn't appear as a reported edge in the other run -- unexplained by this step's mechanism | 203 | 160 |

**This step's own mechanism accounts for roughly 1-3% of the checked edges (4/315, 12/385), not the
majority.** The other two buckets' own ranking doesn't hold up consistently, checked directly rather
than eyeballed: "no node at all" is honest's own *smaller* bucket (108/315 = 34%, vs. 203/315 = 64%
"unexplained") but flagged's *larger* one (213/385 = 55%, vs. 160/385 = 42%) -- the two runs invert
which bucket dominates, and summed across both (321 "no node" vs. 363 "unexplained" out of 700), the
"unexplained" bucket is the larger of the two overall, not "no node." Both buckets are real and
substantial regardless of exact ranking: "no node at all" (321 total) directly contradicts this
step's own claim that "both variants of the same physical call site plausibly exist in
`rawCallGraph` in every run" (Step 15's own phrasing, repeated here) -- for a large fraction of
locations, only one of the two duplicate raw edges is ever constructed in a given run's own
`linked.callGraph`, not both. "Unexplained" (363 total, the numerically larger bucket) isn't
explained by anything found so far, including the fold-in mechanism itself -- a swapped variant
resolving to a genuinely different (crossing) isolation yet not appearing as a reported edge in the
other run can't be dismissed as "the duplicate was never constructed there" (that's the *other*
bucket, by construction of this same check) -- something else excludes it, not yet identified. Given
its size, this bucket deserves at least equal priority to `knownUSRs`-membership as the next thing to
chase, not secondary billing.

**Status, honestly restated**: `ExternalIsolationBackfill.query()`'s strict-USR-equality mechanism is
real, confirmed by direct instrumentation, and a genuine contributing factor for a real fraction of
the divergence -- not invented, not withdrawn. But it is not the whole explanation, and this step's
earlier "closed" framing overstated what one representative case proved. Step 15's own root
mechanism (the naive `knownUSRs`-absence fold-in test) remains the correctly-identified *source* of
duplicate edges existing at all; *why* the raw duplicate is asymmetric per-run for most locations,
and what specifically determines it, is still open. Continuing this properly would need either
per-file instrumentation across a representative sample of the remaining 20 files (not one), or
direct inspection of `knownUSRs`'s own exact membership across files -- both real work, not
attempted here. Two fix directions from Step 15 remain the actionable candidates regardless of
which exact per-edge mechanism explains survival: (1) give `LiveXcodeCompilerArgumentsProvider` the
same home-directory-match preference `SwiftBuildCompilerArgumentsProvider` already has; (2) recognize
a sibling-target duplicate via mangled-suffix match *before* folding it into the call graph at all,
removing the duplicate-edge ambiguity at its source regardless of which target's args any provider
picks. Either needs its own real-corpus before/after per this project's standard discipline before
landing -- not undertaken here.

**Terminology note (superseded -- see the correction immediately below before citing this
anywhere)**: this project's own prior memory record of the still-open PR #104 finding described it
as a "multi-target shared-file compiler-args merge ambiguity." Steps 15/16 found the real mechanism
is not a compiler-args-merge issue at all -- it's (a) `DeclarationLinker.link()`'s own `knownUSRs`-
absence fold-in test conflating a sibling target's duplicate with a genuinely external callee, and
(b) `ExternalIsolationBackfill.query()`'s strict USR-equality matching, for at least a real fraction
of cases. Anything referencing the older "compiler-args merge" phrasing (changelog, PR description,
project memory) should be corrected to point here instead, not repeat it.

**Correction (added after Step 25): this note is itself now the outdated one -- do not cite it,
cite Step 25 instead.** Steps 19-25 (further down this document) directly re-tested both (a) and (b)
against the real dominant divergence and found neither holds up as the actual cause: **(a)** Steps
19/23/24 directly instrumented `disambiguate`'s winner and `linked.callGraph`/`linked.declarations`
for four independent declarations, in-process, in both the honest and flagged runs, and found them
byte-identical every time -- the `knownUSRs`-absence fold-in this note blames is confirmed to
produce duplicate edges (that part was always correct), but produces the *same* duplicates
identically in both runs, so it cannot be the source of *divergence* between them. **(b)** Step 16's
own quantitative recheck (a few paragraphs above this one) already found the strict-USR-match
mechanism explains only ~1-3% of the 834-edge divergence -- a real, confirmed mechanism, but not "a
real fraction" in the sense of a dominant one, and Step 25 never needed it to explain the other
~98%. The actual dominant mechanism (Step 25, closing 98.3% of the divergence) is, ironically,
exactly the "compiler-args merge/selection" shape this note originally set out to correct away from
-- just in a different provider than PR #104 touched: `LiveXcodeCompilerArgumentsProvider` (the
honest path) had no equivalent of `SwiftBuildCompilerArgumentsProvider`'s (#106's) home-directory
target-preference heuristic, so it could -- and, for the traced example, did -- resolve a shared
file to the wrong sibling target's compiler arguments. Any changelog/PR/memory text citing this
document for "why the two paths diverge" should point to Step 25, not to this paragraph.

**Independence from PR #104's own two pre-existing `-derivedDataPath`-threading fixes**: those fixes
touched `LiveXcodeBulkExtractionEnvironmentProvider`, `resolveDeterministicSimulatorDestination`, and
`SwiftVersionDetection.xcodeLanguageMode` -- build-settings/destination resolution, all upstream of
where an index store gets built or located. `DeclarationLinker.link(_:usrRewriteMapOverrides:)`
takes only `extractionResults` and a `[String: String]` override map -- no path, environment, or
destination parameter of any kind reaches it, directly or transitively (confirmed by its own
signature, not inferred). The fold-in bug this step traces is structurally unreachable from that
threading fix's own code paths -- independent, not coincidentally correlated.

**This independence check was against the mechanism this step (Step 16) itself was investigating,
not against the fix Step 25 eventually landed -- extended here for completeness, since a reviewer
correctly pointed out the gap.** Step 25's actual fix lives in `LiveXcodeCompilerArgumentsProvider
.runVerboseBuild`, the *same function* `resolveDeterministicSimulatorDestination` is called from
(line ~138, to build the `-destination` flag for the `xcodebuild` invocation) -- so this one
genuinely needed checking, unlike `DeclarationLinker` which never touches this file at all. Reading
`runVerboseBuild` directly: `destination`'s only use is constructing `arguments` for `processRunning
.run(executable: "xcodebuild", ...)` (line ~191), *before* the process runs. The fix's own logic --
collecting every invocation mentioning a file into `candidatesByPath` and picking among them via
`preferredArguments` -- reads only `result.standardOutput` (the build log text `xcodebuild` already
produced) and never reads `destination` itself. The fix would behave identically no matter what
`resolveDeterministicSimulatorDestination` returned -- independent for the same reason `Declaration
Linker` was, just confirmed against the real landed-fix location instead of the mechanism an earlier
step guessed would need fixing.

## Step 17 -- Correction to Step 15's own probe, and confirmation that live-fallback overrides are
## never the source of a `DraftActionExtension`-qualified survivor

Continuing directly from the still-open question (Step 16: what decides whether a duplicate raw
edge is even *constructed* asymmetrically per run, for the 34-55% of cases where the counterpart
doesn't exist as a node in the other run at all).

**A real methodological error found and corrected first, not glossed over.** Step 15's claim that
`ShareModularViewController.swift` has "zero `DraftActionExtension`-qualified" candidates in
`RawIndexStoreClient.definedSymbols(inFile:)` was checked by `grep`-ing the *printed* output of a
probe that only ever printed `.prefix(30)` of the 540-candidate array -- never the full list the
array itself held. A corrected probe, dumping the **complete** module-tagged count for all 540
candidates, found the true split: **267 `WordPressShareExtension` / 267 `WordPressDraftActionExtension`**,
plus 6 more not matched by that plain substring check -- tracked down directly, not left as an
unexplained ~1%: 3+3 more of each, from a `WordPressUI`-module extension nesting `ShareExtension`/
`DraftActionExtension` as an inner type-namespace (`SiteIconViewModel.ShareExtension`/`.DraftActionExtension`)
rather than as the top-level module prefix the substring check was looking for. **The real total is
270/270 -- exactly symmetric**, not "almost." Extended across all 21 diverging files: every single one
shows the same near-50/50 pattern, not just this one. There is no "declaration-scan says it doesn't
exist, call-graph-scan says it does" inconsistency in the raw index data (Step 15's own framing,
now struck through there) -- both scans agree throughout that both targets' compiled units are
fully, symmetrically indexed. This project's own "compile every line, don't extrapolate" standard
applies to this investigation's own diagnostic code too, and this is a real instance of it not
being followed the first time -- caught on a second look, not defended.

**What this changes**: `DeclarationLinker.disambiguate`'s tie-break between two real, equally valid
candidates (same name, same location, one per target) is genuinely choosing between two
legitimate declarations for a large fraction of these files' own content -- not defaulting past a
one-sided gap. Whatever governs its pick per-location is the real open question, not "why does only
one target get indexed at all" (which doesn't happen).

**Confirmed, directly, not assumed: live-fallback overrides are never the vehicle for a
`WordPressDraftActionExtension`-qualified survivor in the flagged run.** Instrumented
`SwiftIsolationMap.run()` to dump every entry in `localFallbackOverrides` (the live-fallback results
actually passed to `linker.link(_:usrRewriteMapOverrides:)`) whose resolved USR falls under one of
the four shared-target directories, across all 21 files -- not the single probe location Step 16
used. Result: **316 matching overrides, all 316 `WordPressShareExtension`-qualified, zero
`WordPressDraftActionExtension`.** (First attempt at this crashed the run outright --
`Dictionary(uniqueKeysWithValues:)` on `unresolvedPlaceholders`, which really does contain duplicate
placeholder keys across different files/declarations sharing a bare syntactic name, e.g.
`syntactic:Fastfile`; fixed to `Dictionary(_:uniquingKeysWith:)` before the real, successful rerun --
a real bug in this session's own diagnostic code, not the tool, caught by the crash itself rather
than shipped silently.)

**A real cross-check, not a coincidence left unremarked**: Step 15's own instrumentation (logging
every successful `resolveOne` call for a file under one of these directories, filtered by the
*input* file path) counted **316** such calls in its own flagged run. This step's instrumentation
(filtering `localFallbackOverrides` by the *resolved USR* containing one of the same four module
names) counts **316** here too, in a different flagged run (`flagged9`, not the one Step 15 used).
These aren't independent measurements that happened to land on the same number -- `resolveOne`'s
own `file` parameter *is* `location.file` for every item in `unresolved`/`unresolvedPlaceholders`
(the same declarations), and every one of Step 15's logged calls succeeded and (per this step)
resolves to `WordPressShareExtension`, so both filters select the identical underlying set: every
successful live-fallback resolution for a declaration whose own placeholder lives in one of these
21 files. The match across two separately-run flagged invocations is exactly what this project's
own confirmed determinism for the flagged path (Step 13) predicts, and is real, if partial,
cross-validation that both rounds of instrumentation measured what they claimed to.

This closes off live-fallback as a candidate explanation for the still-unexplained fraction of
Step 16's own edge-level divergence: for every one of these 21 files, whenever a declaration's own
placeholder needs live fallback at all in the flagged run, it resolves to `WordPressShareExtension`,
without exception.
Since bulk linking (`disambiguate`, index-store-driven, no compiler-args dependency) is the only
other path a declaration's identity can take, **the remaining asymmetry must come from bulk
linking's own tie-break differing between the honest and flagged processes** for at least some of
these declarations -- a genuine puzzle, since `disambiguate` reads only `RawIndexStoreClient`
output and `declaration.name`, neither of which the experimental flag touches, and both honest and
flagged were separately confirmed internally deterministic (repeated invocations of the same
binary reproduce identically) yet differ from each other. Not yet resolved: whether this is real
per-process nondeterminism in how the raw index-store scan populates `candidatesByLocation`'s own
array order (a hash-seeded `Dictionary`/`Set` somewhere in `RawIndexStoreClient`'s aggregation would
be consistent with "stable within a process, unstable across independently-launched processes"),
or something else entirely. This is now the single sharpest remaining open question for this
investigation (tracked in this project's own memory as a standalone open task), not a restatement
of Step 16's.

**Full test suite**: 537 tests, all passing, ~90s (no regression; all instrumentation reverted after
use, confirmed via `git diff`/`git status` before this commit).

## Step 18 -- An eye-catching lead (316=316, mirrored modules) tested directly and falsified

Ran the *honest* path with the identical override-logging instrumentation Step 17 used for
flagged, against a fresh `honest9`/`flagged9` pair (both completed cleanly this time, after several
kills from an unrelated environmental cause -- a real, concurrent Xcode Archive build of a
different project on the same machine, confirmed via `ps`/`pmset -g log` showing `xcodebuild`/
`caffeinate` `ClientDied` roughly every 1-3 minutes and load averages above 30 on an 8-core machine;
not investigated further, not this project's own concern).

**First result, striking**: honest's own 316 live-fallback overrides for these 21 files are **100%
`WordPressDraftActionExtension`-qualified, zero `WordPressShareExtension`** -- the exact mirror of
flagged's own 316-all-Share result from Step 17. Same count, opposite module. Compared the actual
placeholder *sets*, not just counts: identical, all 316, in both runs (0 only-in-honest, 0
only-in-flagged). A real, reproducible, and initially very promising-looking pattern.

**Checked directly whether this explains the divergence -- it doesn't.** Extracted the 316 resolved
USRs from each run and checked how many of the 834 diverging edges have one of them as their own
`callerUSR`/`calleeUSR`: **zero, in all three buckets (0/344 missing, 0/425 extra, 0/65 changed)**.
This eye-catching 316=316 mirror is a real, reproducible phenomenon, but a completely separate one
from the edge-level divergence this investigation is chasing -- not the same declarations, not
overlapping at all. Looking at the actual overridden declaration names (`keyboardFrame`,
`selectedIndex`, `userInfo`, mangled with mangled-suffix hashes typical of local/private bindings
inside function bodies) strongly suggests this is an instance of this project's own already-tracked,
separate local-declaration-leak bug (`DeclarationExtractor` not scoping to function bodies), not a
new finding about the WordPress-iOS edge asymmetry.

**Status**: a real result, worth recording so it isn't rediscovered and chased again, but a dead
end for this specific question. Item 1 (why bulk linking's own tie-break -- not live-fallback,
already ruled out project-wide in Step 17 -- differs between honest and flagged for the actual
834 diverging edges) remains open, exactly as before this step.

## Step 19 -- Item 1 (bulk linking's tie-break) directly tested and disproven; the divergence lives
## in edge selection, not declaration identity

Instrumented `DeclarationLinker.buildUSRRewriteMap` itself (not a downstream consumer) to log the
full candidate list and winning pick for `selectedModulesTableRowAt` -- the exact declaration whose
edge at `ShareModularViewController.swift:549` has anchored this investigation since Step 13. Ran
honest and flagged back to back (each killed intentionally right after its own "Linked N
declaration(s)..." log line, well before the expensive live-fallback/oracle phases -- this
instrumentation only needs bulk linking to have run once).

**Result: identical in both runs.** `candidates=[WordPressShareExtension-USR, WordPressDraftActionExtension-USR]`,
`winner=WordPressShareExtension-USR` -- same candidate order, same pick, in honest and flagged
alike. **Item 1 is directly disproven, not just unconfirmed**: bulk linking's own tie-break for this
declaration does not differ between the two paths at all. Separately confirmed this declaration is
in neither run's `unresolvedPlaceholders` set (Step 18's own logs), so live-fallback never touches
it either -- its own identity is settled by bulk linking alone, identically, in both runs.

**Yet the actual `flagged9.json` report still shows this exact edge's `callerUSR` as
`WordPressDraftActionExtension`-qualified** (re-checked directly against the fresh `flagged9.json`
from Step 18, not assumed stale). Since the declaration's own resolved identity
(`ownUSRByLocation`, feeding `link()`'s `ownUSR` computation, Step 15's own read of the code)
is confirmed `WordPressShareExtension` in both runs, **the edge's `callerUSR` cannot be coming from
the declaration's own identity at all -- it's coming directly from the raw index-store call-graph
data** (`callGraphEdges`/`callSites`, Step 15's fold-in), which genuinely contains a separate,
real `WordPressDraftActionExtension`-qualified edge for the identical physical call site (confirmed
Step 16). The divergence was never about *which module a declaration's own identity resolves to* --
both runs agree on that. It's entirely about **which of the two real, independently-valid duplicate
raw edges ends up in the final `crossIsolationEdges()` output**, and that selection is not decided
by `disambiguate` at all.

**This redirects item 1 into item 3** (this investigation's own `knownUSRs`-membership lead,
already on the checklist) rather than resolving it independently -- the two questions turn out to
be the same question. Not yet answered: what specifically makes the `WordPressDraftActionExtension`
-qualified duplicate of this edge the one that's `isUnknown`-eligible and survives filtering in
flagged, while the `WordPressShareExtension`-qualified duplicate survives in honest, given both
sides' own declarations resolve identically in both runs and neither edge's construction (Step 15's
fold-in, purely index-store-driven) has any known flag-dependent input.

**Full test suite**: 537 tests, all passing, ~70-90s (no regression; instrumentation reverted,
confirmed via `git diff` before this commit).

## Step 20 -- Honest's raw `linked.callGraph` also contains both duplicates; the question narrows
## to callee-side resolution for never-bulk-linked declarations

Same `RAWEDGE`-style dump Step 16 used for flagged, run against honest this time (Step 16 only
checked flagged). Killed right after "Linked N declaration(s)..." both times, same technique
as Step 19.

**Confirmed: honest's own raw `linked.callGraph` contains both module-qualified duplicate edges at
this location too** -- identical in shape to flagged's (Step 16). Combined with Step 19 (declaration
identity for the caller, `selectedModulesTableRowAt`, resolves identically -- `WordPressShareExtension`
-- in both runs), **every input to `crossIsolationEdges()` this investigation can attribute to
`DeclarationLinker` alone is now confirmed identical between honest and flagged for this location.**
The remaining difference has to live in `ExternalIsolationBackfill`'s own resolution of the
*callee* -- `ModulesSection.init(rawValue:)`, a compiler-synthesized enum initializer never
extracted by `SyntaxAnalysis` and never a bulk-linking winner in either run (neither module variant
is ever a real `SyntaxAnalysis`-produced declaration to link against) -- which is exactly where
Step 16's own query-strict-match mechanism operates, using each run's own `compilerArguments(forFile:)`
for this file.

**What's now confirmed consistent, reconciling an earlier apparent contradiction**: both the
`WordPressShareExtension`- and `WordPressDraftActionExtension`-qualified *caller* nodes
(`selectedModulesTableRowAt`) carry real, identical isolation (`globalActor(MainActor)`) and real
location (line 548) in *both* runs -- this is `MultiTargetDeclarationAliasing`'s own suffix-match
backfill (Step 15), copying the bulk-linked winner's info to its sibling-target USR, and is itself
index-store-driven with no compiler-args dependency, so it behaves identically regardless of flag.
The *callee* side is where the two runs actually diverge: each run's own `ExternalIsolationBackfill
.query()` only ever succeeds (strict USR match against a live `cursorinfo` result) for whichever
target's args that run's own provider supplies for this file, and aliasing does not appear to
propagate a live-query-backfilled callee's isolation across to its sibling's USR the way it does for
an already-bulk-linked declaration -- each module variant of the callee is resolved (or not)
independently.

**Narrowed, not yet closed**: the open question is no longer "why does bulk linking or raw-edge
construction differ" (both ruled out, Steps 19-20) -- it's specifically why `query()`'s per-file
target choice differs between honest and flagged for files like this one, and why that's sufficient
to explain the *majority* of the divergence when Step 16's own quantitative check (looking only at
"does the swapped variant end up with the *same* isolation as its caller") found just 1-3%. The
likely reconciliation, not yet directly verified: Step 16's check was too narrow -- it only counted
cases where the swapped callee's isolation happened to *equal* the caller's (making it trivially
non-crossing), not the broader "does the callee resolve to *anything* at all" question this step's
own reasoning suggests is the real determinant (an edge whose callee is `isUnknown` always survives
`crossIsolationEdges()`, regardless of what the isolation value is once resolved). Re-running Step
16's own bucket analysis with this broader criterion, rather than another live corpus run, is the
next concrete step.

**Full test suite**: 537 tests, all passing (re-confirmed after this step's own revert).

## Step 21 -- Self-caught overgeneralization: raw `linked.callGraph` is NOT always identical between
## honest and flagged; the broader recheck also fixed a counting bug in Step 16's own bucket labels

Re-ran Step 16's own "no-swap/no-node/same-as-caller" bucket analysis on the existing
`honest9.json`/`flagged9.json` (no new corpus run -- exactly the check Step 20 itself proposed as
the next step) with one addition: explicitly counting how many `isUnknown` edges have a `calleeUSR`
that doesn't contain any of the four shared-target module names at all -- previously silently folded
into "unexplained" by a `swap_module` helper that returned `nil` for these and was never checked for.

**That correction alone found the real shape of the largest bucket**: 203/315 (honest-only) and
160/385 (flagged-only) `isUnknown` edges -- exactly Step 16's own "unexplained" numbers -- turn out
to be cases where the callee is a genuinely unrelated symbol (a real external SDK/dependency type,
e.g. `Aztec.MediaAttachment`), not a shared-target duplicate at all. Step 16's "swap the callee's
module" check was the wrong side to swap for this bucket -- the divergence for these edges lives on
the **caller** side, not the callee.

**Checked one such case directly, and it directly contradicts Steps 19-20's own generalization.**
At `ShareExtensionEditorViewController.swift:1127`, honest has **7 edges** at this one location --
3 `WordPressShareExtension`-qualified-caller edges (`globalActor(MainActor)`, `isUnknown: true`) and
4 `WordPressDraftActionExtension`-qualified-caller edges (`unspecified`, `isUnknown: false`). Flagged
has only **3 edges** at the identical location -- the `WordPressDraftActionExtension` set only; the
three `WordPressShareExtension`-qualified edges are **completely absent**, not merely filtered out
downstream. This means Steps 19 and 20's own conclusion ("`linked.callGraph` contains both
duplicates identically in both runs") does not hold universally -- it was confirmed for exactly one
location (`ShareModularViewController.swift:549`) and wrongly generalized to "the raw graph itself
never differs," the same class of error Step 16's original "closed" claim made and was corrected
for. Caught here before it was asserted as a closing fact, not after.

**What this narrows the question to, honestly**: `knownUSRs`'s exact membership (or something else
in the fold-in construction, Step 15) genuinely differs between honest and flagged for *some*
files/declarations but not others -- confirmed true for at least these two concrete, contrasting
examples. What specifically distinguishes a location where both duplicates survive
(`ShareModularViewController.swift:549`) from one where only one target's copy ever enters
`linked.callGraph` at all (`ShareExtensionEditorViewController.swift:1127`) is not yet identified.
This is now the precise open question -- not "does the raw graph differ" (it demonstrably can), but
"what specific condition makes it differ for this file and not that one."

**Status**: genuine progress (the "unexplained" bucket's real shape found, a self-made
overgeneralization caught and corrected before being asserted as closed), but the core mechanism
remains open. Next step would need direct instrumentation of `knownUSRs`'s own membership for both
files' callees, comparing honest vs. flagged -- not attempted here, given the cost of each additional
full-corpus run against this real, large project in a session with its own recurring external
instability (documented above, now understood to be unrelated contention from a separate concurrent
build on the same machine).

## Step 22 -- Two candidate theories directly tested and disproven against the still-live private
## DerivedData, without a new corpus run; the real mechanism remains open

The private, composite-keyed DerivedData (docs/task-private-derived-data-hypothesis.md) from Step
20-21's `honest9`/`flagged9` pair was still on disk and untouched
(`~/Library/Caches/swift-isolation-map/DerivedData/WordPress-d294721d/WordPress/generic_platform_
iOS_Simulator/default`), with `honest9` the more recent of the two real `xcodebuild` builds (17:18
vs. `flagged9`'s 15:34). This let two concrete theories get tested directly against the live index
store and the live `SwiftBuildCompilerArgumentsProvider`, with no new corpus run at all -- a
temporary standalone `diagnostic-probe` executable target (same established pattern as prior steps,
reverted after use via `git checkout --`/`rm -rf`) linked `RawIndexStoreClient` and
`SwiftBuildCompilerArgumentsProvider` directly.

**Theory A, tested and disproven: "the raw index store itself only has one target's records for
this file/location."** Querying `definedSymbols(inFile:)`/`callSites(inFile:)` directly against the
live store for `ShareExtensionEditorViewController.swift:1127` returned **8 raw call-site edges** --
both the `WordPressShareExtension`-qualified and `WordPressDraftActionExtension`-qualified caller/
callee pairs, for all 4 callees (`shareData`, `sharedImageDict`, `updateValue`, `identifier`),
right now, in the exact same frozen state that `flagged9`'s CLI run (which reported only 3 Draft-
only edges at this location) would have read from. This means the divergence documented in Step 21
is **not** explainable by the raw index data itself lacking the Share-side records -- confirmed
directly, not inferred. It also clarifies a modeling error in Step 21 itself: `honest9.json`/
`flagged9.json`'s per-location edge counts are the CLI's own **final, fully-filtered**
`crossIsolationEdges()` output, not a dump of `linked.callGraph` -- the "7 vs. 3 edges" comparison
was already comparing post-filter results, not raw graph construction, so Step 21's framing
("`knownUSRs`/fold-in differs between runs") was itself an unverified inference, not a directly
observed fact.

**Theory B, tested and disproven: "flagged's compiler-args resolution picks the wrong (Draft)
target for this file, so `SyntaxAnalysis` never sees Share's isolation at all."** This was the
natural next suspect -- item 4(a)'s "home-directory heuristic" fix (#106) landed 2026-08-20 10:11,
before `flagged9` ran (2026-08-21 15:34), so it should already have been active. Querying
`SwiftBuildCompilerArgumentsProvider.compilerArguments(forFile:)` directly, right now, for both
`ShareExtensionEditorViewController.swift` (the caller's file) and `ShareExtensionAbstractViewController.swift`
(`shareData`'s declaring file) returns `-module-name WordPressShareExtension` for **both** --
`preferredArguments`'s home-directory match is correctly picking Share, not Draft, exactly as #106
intends. `flagged9.log`'s own `SwiftBuild direct: resolved compiler arguments for 5553 file(s)
across 497/497 target(s)` line confirms no target failed that run either, ruling out the transient-
failure fallback path `preferredArguments`'s own doc comment describes. Yet `flagged9.json`'s actual
output for this location shows the **Draft**-qualified declarations resolving correctly and the
Share-qualified ones missing entirely -- the opposite of what Theory B would predict. This is a
real, currently unexplained contradiction, not glossed over: whatever picks which target's
*isolation* ends up recorded in `declarations`/`byUSR` for this specific class/property is
demonstrably not simply "whichever target's compiler args `SwiftBuildCompilerArgumentsProvider`
prefers for that file."

**What remains**: with both the raw-graph-differs theory and the wrong-target-args theory directly
falsified against live data, the remaining candidate sites are `DeclarationLinker.disambiguate`'s
tie-break winner itself (Step 19 found it identical for *one* location,
`ShareModularViewController.swift:549` -- not yet re-checked for this location or in general) and
whatever in `byUSR`'s construction/merge (`Self.merged`, `resolveInheritanceViaBaseOfRelation`,
`resolveExtensionContainingTypeViaChildOfRelation`) could cause the *same* declaration to end up
attributed to a different real USR's isolation across two runs against the same shared index data.
Distinguishing between these needs direct instrumentation of `usrRewriteMap`'s value for `shareData`/
`sharedImageDict`'s own declarations specifically (not just the caller, as Step 19 checked), compared
honest vs. flagged -- which does require a new instrumented live run, since the live `Declaration
Linker.link()` code path itself (not just its static index-store inputs) is what needs observing.
Not attempted in this step, to keep the two disproofs above -- genuinely informative on their own --
from being buried under yet another expensive, not-yet-executed run.

**Full test suite**: 537 tests, all passing (Package.swift/`Sources/diagnostic-probe` fully reverted
before running).

## Step 23 -- A third theory tested with a fresh, full instrumented honest/flagged pair: disambiguate's
## winner for the callee declarations themselves is also identical between runs; the mechanism is
## narrower than any of Steps 19-22's three disproven candidates

`DeclarationLinker.buildUSRRewriteMap` was temporarily instrumented (same pattern as Step 19, reverted
via `git checkout --` after use) to log every declaration's disambiguation candidates/winner for the
three files this specific edge touches: `ShareExtensionEditorViewController.swift` (the caller),
`ShareExtensionAbstractViewController.swift` (`shareData`'s declaring file), and `ShareData.swift`
(`sharedImageDict`'s declaring file). Unlike Steps 19-22, this required a genuine new full corpus
pair -- the live-instrumented `DeclarationLinker.link()` code path itself needed observing, not just
its static index-store/compiler-args inputs -- run sequentially (never in parallel, given the shared
private DerivedData), `honest10` then `flagged10`.

**Reproducibility check, first**: `honest10.json`/`flagged10.json`'s edges at
`ShareExtensionEditorViewController.swift:1127` reproduce Step 21's exact pattern -- honest has 7 (3
Share-qualified-caller `isUnknown` + 4 Draft-qualified-caller real crossings), flagged has 3 (Draft-
qualified-caller only, missing both the Share triplet and Draft's own `shareData`→`MainActor` edge).
Not a one-off artifact of the specific `honest9`/`flagged9` run.

**Theory C, tested and disproven: "`disambiguate`'s tie-break picks a different winner for `shareData`/
`sharedImageDict` between the two runs."** The instrumented log shows, for both declarations, in
*both* `honest10` and `flagged10`: identical two-candidate sets (Share-qualified and Draft-qualified),
identical winner (`WordPressShareExtension`'s real USR, in both cases) -- byte-for-byte the same
`usrRewriteMap` outcome Step 19 already found for a different declaration
(`ShareModularViewController.swift:549`). This directly extends Step 19's finding to a *second,
independent* pair of declarations, closing the possibility that Step 19's result was itself a fluke
of that one location.

**What this leaves**: three separate candidate mechanisms are now disproven with direct evidence
(Theory A: raw index store lacks a target's records: Step 22; Theory B: `SwiftBuildCompilerArguments
Provider` resolves the wrong target's args: Step 22; Theory C: `disambiguate`'s tie-break differs:
Steps 19 + 23). Since `usrRewriteMap`'s value for `shareData`/`sharedImageDict` is confirmed identical
in both runs, `knownUSRs` (`Set(usrRewriteMap.values)`) contains the *same* real USR for these two
declarations in both runs too -- meaning whatever excludes Share's `shareData` edge and Draft's
`shareData` edge from `flagged10`'s final output (while both survive in `honest10`) is not explained
by anything `buildUSRRewriteMap`/`link()`'s fold-in loop does differently between the two runs. The
remaining candidate sites are downstream of `link()` entirely: `byUSR`'s merge step (`Self.merged`,
`resolveInheritanceViaBaseOfRelation`, `resolveExtensionContainingTypeViaChildOfRelation`) or
`IsolationInferenceEngine`'s own `resolveIsolation`/`crossIsolationEdges` decision for these specific
USRs -- neither instrumented yet. Distinguishing between them needs a direct log of `byUSR`'s actual
recorded isolation value for both `shareData` real USRs (Share's and Draft's) in each run, not just
which one won `usrRewriteMap` -- since Step 23 confirms the *winning* USR is the same, but the
*resolved isolation value* attached to it (or backfilled onto the *losing* one via `MultiTarget
DeclarationAliasing`) still ends up differing in the two runs' final output. Not attempted in this
step, to report this cleanly bounded negative result rather than launch a fourth full corpus run in
the same sitting.

**Full test suite**: 537 tests, all passing (`DeclarationLinker.swift`'s instrumentation fully
reverted before running).

## Step 24 -- Root mechanism found: a single `unknownUSRs` membership flag on the *caller's* own USR,
## not on any callee or on `linked.callGraph`/`declarations` construction at all

A fourth full instrumented `honest11`/`flagged11` pair, this time logging directly inside
`SwiftIsolationMap.swift` (temporary, reverted via `git checkout --`) right after `linker.link()` and
again after `mergedDeclarations`/`IsolationInferenceEngine` construction -- for the exact two USRs
this edge's caller resolves to (`ShareCaller`, `DraftCaller`).

**A fourth declaration checked, disambiguate still identical**: before touching `SwiftIsolationMap
.swift`, Step 23's own instrumentation (still in the honest10/flagged10 logs, no new run needed) was
re-checked for the CALLER method itself (`textView(_:attachment:imageAt:onSuccess:onFailure:)`,
declared at `ShareExtensionEditorViewController.swift:1120`) -- byte-identical candidates and winner
(`WordPressShareExtension`) in both runs, same as the three declarations checked in Steps 19/23. Four
independent declarations now confirm `disambiguate`'s tie-break is not merely "usually" stable but
consistently, deterministically favors `WordPressShareExtension` for this whole shared-source-
directory group, in every run tested.

**Everything up to and including the raw call graph is confirmed byte-identical, in-process, in both
runs**: `linked.callGraph` has exactly 8 edges at this location in both `honest11` and `flagged11`
(matching Step 22's separate on-disk snapshot, but this time observed live, inside each run's own
process); `linked.declarations[ShareCallerUSR]` is present with a real location in both;
`linked.declarations[DraftCallerUSR]` is absent in both; `mergedDeclarations` shows the identical
shape in both; `engine.resolveIsolation(for: ShareCallerUSR)` returns `globalActor(name: "MainActor")`
in **both**; `resolveIsolation(for: DraftCallerUSR)` returns `.unspecified` in **both**. Every single
value checked at this point in the pipeline is identical between honest and flagged.

**The one and only difference found**: `externalResolution.unknownUSRs.contains(ShareCallerUSR)` is
**`true` in `honest11`, `false` in `flagged11`** -- `DraftCallerUSR` is `false` in both (never a work
item at all, since it never appears as anyone's `calleeUSR` and never won `usrRewriteMap`, matching
Steps 19/23's disambiguate finding).

**Why this one flag decides the entire edge count at this location**:
`AnalysisReportBuilder.swift` computes `isUnknown = unknownUSRs.contains(edge.callerUSR) ||
unknownUSRs.contains(edge.calleeUSR)` (line 67) and then explicitly suppresses a report-worthy-
looking edge under exactly one condition (line 80): `isIsolated(callerIsolation), case .nonisolated =
calleeIsolation, !isUnknown` -- "a known-isolated caller reaching a known-nonisolated callee is
usually not a real risk, *unless* something about this edge is already uncertain." `ShareCallerUSR`'s
own isolation (`globalActor(MainActor)`) is identical in both runs, and its three non-`shareData`
callees (`sharedImageDict`, `updateValue`, `identifier`) all resolve to `.nonisolated` identically in
both runs too -- so in `honest11`, `isUnknown=true` (from the caller side) exempts these 3 edges from
the suppression rule and they survive into the report (matching the real `isUnknown: true` edges
observed in `honest9`/`honest10`/`honest11`'s own JSON). In `flagged11`, `isUnknown=false`, the
suppression rule fires, and all 3 are silently dropped -- explaining the "flagged has 3, honest has 7"
split down to the exact boolean that causes it. (`shareData`'s own Share-caller edge was never in
either run's output at all, for an unrelated, already-understood reason: its callee also resolves to
`globalActor(MainActor)`, identical to the caller, so `crossIsolationEdges()`'s own base filter
excludes it before `isUnknown` is even consulted.)

**What remains genuinely open**: *why* `ShareCallerUSR` ends up in `unknownUSRs` in one run and not
the other. `unknownUSRs` is populated by `ExternalIsolationBackfill.resolve()`'s **declaration-level**
work-item path (`collectDeclarationLevelWorkItems`, not the edge-level path Step 15-22 already
examined) -- specifically the conformance-resolution branch, since this caller is a member of
`extension ShareExtensionEditorViewController: TextViewAttachmentDelegate` (an external Aztec-
framework protocol) and SE-0316's same-context-witness rule needs that protocol's own global-actor
status resolved, either from the bulk symbol-graph cache or a live `sourcekitd` query -- both of which
ultimately depend on `compilerArguments` (the flag-dependent provider). This declaration-level
resolution succeeding in computing the *correct* isolation value in both runs, while still landing in
`unknownUSRs` in one but not the other, means whatever's uncertain here is a bookkeeping/pathway
difference (the query took a different route, or the same conclusion arrived by a different,
partially-uncertain route), not a difference in the final resolved fact. Not instrumented in this
step -- would need direct logging inside `collectDeclarationLevelWorkItems`/`applyDeclarationLevelOutcomes`
for `TextViewAttachmentDelegate`'s own USR and the bulk-cache/live-query outcome recorded for it, in
a fifth honest/flagged pair.

**Full test suite**: 537 tests, all passing (`SwiftIsolationMap.swift`'s instrumentation fully
reverted before running).

## Step 25 -- Root cause confirmed and fixed: `LiveXcodeCompilerArgumentsProvider` had no home-
## directory heuristic; real-corpus verification shows the fix closes 98.3% of the divergence

A cheap, temporary args-dump-and-exit hook (`SWIFT_ISOLATION_MAP_STEP25_DUMP_ARGS`, added right
after `compilerArguments` becomes available in `SwiftIsolationMap.swift`'s `run()`, before the
expensive parsing/oracle phases -- reverted via `git checkout --` after use) directly answered Step
24's remaining question: what compiler arguments does **honest**'s own path resolve for
`ShareExtensionEditorViewController.swift` (the caller's file)?

**Answer: `-module-name WordPressDraftActionExtension`.** Honest's `LiveXcodeCompilerArgumentsProvider`
resolves this shared file to the *wrong* sibling target's compiler arguments -- confirmed directly,
not inferred. The symmetric check (`--experimental-swift-build-compiler-args` against the identical
file, same dump hook) returns `-module-name WordPressShareExtension`, the file's real physical home,
exactly as `SwiftBuildCompilerArgumentsProvider.preferredArguments` (#106) is designed to do.

**Root cause, in full**: `LiveXcodeCompilerArgumentsProvider.runVerboseBuild` (`Sources/
ProjectResolution/XcodeBuildLogCompilerArgumentsProvider.swift`) parsed every `xcodebuild -verbose`
compile invocation into a flat `[file: arguments]` dictionary with a plain overwriting assignment
(`parsed[file] = fullArguments`) -- whichever target's compile line the log happened to print *last*
silently won, for every file compiled by more than one target. This is exactly the bug #106 already
fixed for the `SwiftBuildCompilerArgumentsProvider` (flagged) path, in 2026-08-20 -- but the *honest*
path never got the equivalent fix, because nothing in this investigation had, until Step 24, actually
traced a concrete divergence back to it. Once honest resolves the wrong target's args for a shared
file, any live oracle query needing real compiler args for that file (Step 24's example: resolving
`Aztec.TextViewAttachmentDelegate`'s own global-actor status for a same-context conformance) queries
`sourcekitd` under the *wrong* compiled context -- explaining why that query's outcome (and therefore
`unknownUSRs` membership, and therefore `AnalysisReportBuilder`'s suppression decision) differed
between the two paths even though every statically-resolved fact (`disambiguate`'s winner,
`linked.callGraph`, `linked.declarations`, `resolveIsolation`'s computed value) was already confirmed
identical in Steps 19-24.

**The fix**: `runVerboseBuild` now collects every invocation that mentions a given file (not just the
last one), keyed by that invocation's own `-module-name`, and picks among them using the *exact same*
`SwiftBuildCompilerArgumentsProvider.preferredArguments` function #106 already validated -- both
providers live in the same `ProjectResolution` target, so this is direct reuse, not a parallel
reimplementation. A new test, `liveXcodeProviderPrefersTheHomeTargetForAFileCompiledByMultipleTargets`
(`Tests/ProjectResolutionTests/XcodeCompilerArgsTests.swift`), reproduces the exact WordPress-iOS
shape (two sibling targets' compile lines for the same shared file, Draft's printed *second* in the
log, matching the real bug) and confirms the file now resolves to its home target
(`WordPressShareExtension`), not whichever line came last.

**Real-corpus verification** (`docs/task-cross-cutting-infra-needs-real-corpus-verification`-style,
not just the fixture test above -- a change to shared compiler-args-resolution infra needs it): a
fresh full honest run against the identical corpus/scheme (`honest-fix1.json`) compared against the
freshest flagged baseline (`flagged11.json`) using the same edge-identity key Steps 13-24 already
used:

```
honest edges: 6347, flagged edges: 6361
shared: 6347, missing (honest-only): 0, extra (flagged-only): 14, changed: 0
```

**Divergence dropped from 834 edges to 14 -- a 98.3% reduction**, and honest's own edge set is now a
strict subset of flagged's (zero edges honest has that flagged doesn't, zero edges present-but-
different in both). The traced example itself (`ShareExtensionEditorViewController.swift:1127`) now
shows exactly the same 3 edges in both honest and flagged, byte-identical, confirming the fix directly
resolves the specific case Steps 19-24 traced end-to-end.

**Methodology correction (user review caught this): "honest edges: 6347" above is not the same
quantity as Step 13's "6617"-edge baseline, and comparing them directly is wrong.** The diff script
behind this whole section (and every prior honest-vs-flagged comparison since Step 13) deduplicates
by a `(callerUSR, calleeUSR, file, line)` key -- built as a Python dict comprehension, so two report
entries sharing an identical key silently collapse to one. Checked directly, after this review: both
`honest9.json` (pre-fix) and `honest-fix1.json` (post-fix) contain exactly **337** such duplicate-
key report entries (189 and 190 distinct locations respectively, 177 of them the same location in
both) -- every checked instance is a byte-for-byte exact duplicate row (same isolation, same
`explanation`, same `risk`), not two different findings that happen to collide. This is a real,
pre-existing report-generation characteristic, present *before* Step 25's fix and apparently
unrelated to it (near-identical count on both sides of the fix) -- not investigated further here,
genuinely out of scope for this document, but worth its own follow-up. The **raw** edge-array
length -- the one Step 13's "6617" figure actually was -- moved **6617 -> 6684 (+67, +1.0%)**, not
"6617 -> 6347 (-4%)" as an unwary reading of this section could conclude. The 834 -> 14 *difference*
computed above is unaffected by this (deduplication is applied identically to both operands of a
diff, so it cancels out of a delta even though it distorts each side's own printed total) -- but the
absolute counts printed alongside it should never have been read against Step 13's differently-
computed baseline, and this document didn't call that out until now.

**The remaining 14 edges are a separate, newly-surfaced issue -- Step 25's own characterization of
it was itself wrong, corrected below (Step 26)**: all 14 are at `Classes/System/
ApiCredentials+BuildSecrets.swift`. This paragraph originally called it "a single-target file... 
nothing to do with the multi-target shared-file shape this step's fix addresses" -- that was
incorrect, caught during Step 26's own investigation (see below): the file is compiled by (at least)
four sibling targets (`WordPress`, `WordPressNotificationServiceExtension`,
`WordPressDraftActionExtension`, `WordPressShareExtension`), confirmed directly via the raw index
store. It just isn't fixable by *this* step's own home-directory heuristic, because the file
physically lives under `Classes/System/`, not under any target-named directory at all -- there is no
path-component signal for `preferredArguments` to match against, for either provider. See Step 26.

**Full test suite**: 538 tests (537 + this step's new test), all passing.

## Step 26 -- The remaining 14-edge residual explained: `ApiCredentials+BuildSecrets.swift` has no
## home-directory signal for *any* target, so both providers' documented, accepted fallback picks a
## different one -- not a new bug, and not fixable the way Step 25's was

Direct instrumentation, in two passes (both reverted via `git checkout --` after use): first, the
same cheap args-dump-and-exit hook Step 25 used, targeting this file specifically for both honest
(post-fix) and flagged; second, logging directly inside `ExternalIsolationBackfill.query()` --
resolved module name, `CursorInfoResult.all`'s raw USR list, and the final match/outcome -- filtered
to this file's own edge-level work items, for a full honest run (`honest26q.json`).

**The file has no home-directory match for any target.** `Classes/System/ApiCredentials+BuildSecrets
.swift` is compiled by (at least) four sibling targets -- confirmed via the raw index store
(`definedSymbols`/`callSites`): `WordPress` (the main app), `WordPressNotificationServiceExtension`,
`WordPressDraftActionExtension`, `WordPressShareExtension`. Its own path has no target-named
component at all (`Classes/System/`, not any of the four target directories), so `preferredArguments`
-- reused by both providers since Step 25 -- can never find a unique path-component match here. Both
providers fall through to their own documented, pre-existing fallback ("whichever candidate came
first"), exactly as designed for this exact shape ("a file living outside any target-named
directory" -- `preferredArguments`'s own doc comment, unchanged since #106). The two providers'
`candidates[0]` mean different things, though: honest's `runVerboseBuild` orders candidates by
whichever `xcodebuild -verbose` compile line printed first (confirmed: **`WordPressShareExtension`**,
via the args dump), while flagged's `SwiftBuildCompilerArgumentsProvider` orders them by
`workspaceInfo.targetInfos`'s own enumeration (confirmed: **`WordPress`**) -- an independent
ordering with no reason to agree.

**Why this produces exactly the residual pattern seen**: `client`/`secret`/`zendeskAppId`/
`zendeskUrl`/`zendeskClientId`/`encryptedLogKey`/`debuggingKey` are static properties whose *only*
physical declaration is a per-target *generated* source file under each target's own DerivedSources
(a build-time secrets-injection step -- the real, hand-written file this project's own source tree
has, `WordPress/Credentials/Secrets-example.swift`, is a placeholder template, never the compiled
one) -- outside `projectRoot`, so `SyntaxAnalysis` never sees any of the four targets' own
declarations for these seven properties at all. None of them ever appear in `linked.declarations`
directly, and `MultiTargetDeclarationAliasing`'s suffix-based backfill (`collectEdgeLevelWorkItems`)
requires an already-linked sibling with a real location to alias *from* -- there is none for any of
these seven properties, in any run. Every reference to them becomes a genuine edge-level oracle work
item, queried at the one real call site inside `toSecrets()` (this shared file), using whichever
target `compilerArguments(forFile:)` resolved for the *whole file* (memoized once, not per query).
Confirmed directly from `honest26q`'s query log: querying `WordPressShareExtension`'s own
`debuggingKey` returns `result.all.usrs == ["...WordPressShareExtension...debuggingKey..."]` and
resolves (`RESOLVED via symbolGraph -> nonisolated`) -- `sourcekitd`, compiled under Share's own
context (honest's resolved module for this file), only ever sees Share's own variant at this
position. Querying any *other* target's `debuggingKey` targetUSR at the identical (file, line,
column) returns that exact same one-element result list -- `USRMatching`'s strict equality never
matches a different target's USR, so every other target's own property query fails (`NO MATCH ->
.unknown`), confirmed for all three other targets in the same log.

**This deterministically produces one "confidently resolved" target's group and three "unknown"
groups for whichever target's properties don't match the winning args -- but whether a given
target's group appears in the *report* at all depends on a second, independent question: does that
target's own `toSecrets()` (the caller) *also* happen to resolve to the identical isolation as its
properties?** `toSecrets()`'s own isolation is governed by a completely separate mechanism (not this
file's own arg resolution at all): `MultiTargetDeclarationAliasing`'s mangled-suffix match against
whichever target's `toSecrets()` won `disambiguate` (confirmed: `WordPressNotificationServiceExtension`,
first in the raw index store's own candidate order, both runs -- consistent with the entire session's
findings that `disambiguate` never varies by run), or an independent live query wherever else that
target's own `toSecrets()` is *called from* (a properly home-directory-resolvable file, if one
exists). Confirmed directly: `WordPressShareExtension`'s own `toSecrets()` is called from
`MainShareViewController.swift:67` (physically under `WordPressShareExtension/`, correctly resolved
by the Step 25 fix in both providers) and resolves to `nonisolated` there -- identical to what its own
`debuggingKey` etc. resolve to at this file, in honest. Caller and callee agreeing means **no
isolation crossing at all** -- `IsolationInferenceEngine.crossIsolationEdges()`'s own base filter
(`resolveIsolation(caller) != resolveIsolation(callee)`) excludes the entire group *before* `isUnknown`
even enters the picture. That's why honest shows zero `WordPressShareExtension`-qualified edges here
(this run's winning target for this file's arg resolution), not "unknown" ones. In flagged, the
winning target for this file is `WordPress` instead: `WordPress`'s own properties resolve
successfully (unspecified caller -- unaliased, no suffix match, no separate call site found --
crossing into a resolved `nonisolated` callee, a real, non-`isUnknown` finding), while
`WordPressShareExtension`'s properties now fail (flagged's memoized args for this file are
`WordPress`'s, not Share's) *and* its own caller is still `nonisolated` from the same independent
`MainShareViewController.swift` route -- but this time the callee stays unresolved (`unspecified`,
since its query failed), so caller (`nonisolated`) ≠ callee (`unspecified`) -- a genuine crossing,
reported with `isUnknown: true`.

**Status: understood, not a correctness bug, and not fixable the way Step 25's was.** Every edge on
both sides of this residual is either a real, confidently-resolved crossing, or an edge honestly
marked `isUnknown: true` -- this project's own explicit "not a confirmed risk" signal, working
exactly as designed for a genuinely unresolvable case. There is no home-directory signal to add for
a file with no target-named path component at all, so Step 25's fix has nothing to attach to here.
The two providers picking different "first" candidates for this specific, narrow shape (files
outside every target's own directory, shared by targets whose own declarations live in per-target
*generated* sources outside the scanned root) is real but small -- 14 edges out of the original 834,
already down from 98.3% to effectively fully accounted for. A genuine future improvement (not
undertaken here, no correctness need drives it) would be making both providers agree on what "first"
means for this fallback case -- e.g., sorting candidates by target name -- so the *set* of "unknown"
edges is at least identical between the two paths, even though which one is "confidently resolved"
would remain arbitrary by construction.

**Full test suite**: 538 tests, all passing (instrumentation fully reverted before running).
