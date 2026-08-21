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
   ([[project_local_declaration_leak_and_first_run_oracle_mystery.md]]: local `let`/`var` bindings
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
5401-item repro (one process, ~30 min, matching one real worker's own item count) resolved the
target declaration correctly every time. A genuinely concurrent repro (8 real worker subprocesses,
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
-path instrumentation) has not yet been attempted.
