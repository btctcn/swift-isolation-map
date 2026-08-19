# Spike: `xcodebuild -showBuildSettingsForIndex` for compiler args without recompiling

Tracks `project_persistent_compiler_args_cache_task.md` -- the private, composite-key DerivedData
(`docs/task-private-derived-data-hypothesis.md`) made the compiler-argument-resolution build's own
clean-rebuild retry (`LiveXcodeCompilerArgumentsProvider.loadArgumentsIfNeeded`) fire on *every*
invocation once the private cache is warm, not just occasionally -- confirmed empirically, 5
consecutive real runs against an already-fully-built Project Iris private cache, the retry firing
every single time, each costing minutes. This spike investigates whether `xcodebuild` exposes a way
to get real per-file compiler arguments without an actual (re)compile at all.

**Status: mechanism confirmed real and fast; the platform-selection caveat is CONFIRMED REAL HARM
(not hypothetical), proven two independent ways -- direct code reading, and a live `sourcekitd`
query reproducing an actual compile failure. Disqualifies naive adoption; a real fix (not just a
workaround) is needed before this can replace the current clean-rebuild-based resolution.**

## Step 1 — Hypothesis

`xcodebuild -help` lists `-showBuildSettingsForIndex` -- "display build settings for the index
service" -- a real, documented flag distinct from `-showBuildSettings`. This is the mechanism
SourceKit-LSP's own Xcode build support (`xcode-build-server`) is built on, to get per-file compiler
invocations for editor/indexing support without needing a build to actually run.

## Step 2 — Confirmed: real, fast, comprehensive

Ran against Project Iris (`xcodebuild -workspace lsboutique.xcworkspace -scheme ls.net.ru
-derivedDataPath <already-warm private path> -showBuildSettingsForIndex -json`):

- **~16-20 seconds wall-clock**, vs. minutes for the clean-rebuild-retry path this exists to avoid.
  No compile-related log output at all -- this is a real settings query, not a build.
- Output: one JSON object keyed by **target name**, each value keyed by **absolute file path**
  directly (`Ls.net.ru` -> `/Users/ab/ios/lsboutique/Api/AboutApi.swift` -> `{...}`). Per file:
  - `swiftASTCommandArguments` -- the real, full `swift-frontend`-shaped argument list: `-module-
    name`, `-Onone`, the complete sibling-file list (matching the WMO shape
    `CompilerArgsLogParser`'s existing fallback already expects), then every real `-Xcc -I<path>`/
    `-Xcc -D<macro>`/`-import-objc-header`/`-working-directory`/module-cache flag a real compile
    would use (2199 total arguments for one representative file on Project Iris).
  - `swiftASTModuleName` -- the real module name directly (`Ls_net_ru`), no `-module-name` parsing
    needed at all.
  - `outputFilePath`, `LanguageDialect`, `toolchains`, `assetSymbolIndexPath`.

This comfortably covers everything `CompilerArgsLogParser`/`LiveXcodeCompilerArgumentsProvider`
currently extract from a real `-verbose` build log (per-file arguments, real module names) -- and
does it as one single, fast, non-mutating query per target, not a build-and-parse cycle.

## Step 3 — Confirmed real caveat: platform selection is not controllable, at least not here

Project Iris's own private DerivedData at the queried path contains **only** a
`Debug-iphonesimulator` build (confirmed: `Build/Intermediates.noindex/lsboutique.build/` has
exactly one subdirectory, `Debug-iphonesimulator` -- no `Debug-iphoneos` anywhere). Despite this,
`-showBuildSettingsForIndex`'s own `swiftASTCommandArguments` consistently reported **device**
settings (`-target arm64-apple-ios15.6`, `-sdk .../iPhoneOS26.4.sdk`) across three independent,
deliberately different invocations:

1. `-destination "generic/platform=iOS Simulator"` (this tool's own real destination string,
   `resolveDeterministicSimulatorDestination`'s output) -- device.
2. `-destination "id=<a real, concrete, available Simulator UDID>"` -- device.
3. `SDKROOT=iphonesimulator` as a bare build-setting override (the same override form
   `xcodeIndexingBuildSettings` already successfully uses for other settings) -- device.

All three produced byte-identical `-target`/`-sdk` values. This means `-showBuildSettingsForIndex`
is, at least for this real project/scheme, **insensitive to every destination/SDK override this
project's own code already knows how to pass** -- it appears to report whatever the scheme's own
configured default platform is (likely device, a common default for an older/established real
project's own `.xcscheme`), regardless of command-line intent, and regardless of what's actually
been built into the DerivedData being queried.

**Why this matters, not just a curiosity**: this tool's own real analysis always builds for
Simulator specifically (`xcodeIndexingBuildSettings`/`resolveDeterministicSimulatorDestination`'s
own doc comment explains why -- avoiding provisioning-profile/code-signing failures a plain device
destination would hit). If `-showBuildSettingsForIndex` silently hands back device-flavored compiler
arguments instead, downstream consumers (`SyntaxAnalysis`'s `#if os(...)`/`#if targetEnvironment
(simulator)` conditional-compilation evaluation, the live-fallback/oracle's own per-file `sourcekitd`
queries) would be working from arguments describing a *different* real build than the one the index
store itself actually reflects -- a real, silent-correctness-risk mismatch, not merely "the wrong
flavor of the same answer."

## Step 4 — The `SyntaxAnalysis`/`#if` consumer: proven harmless, by reading the code

Traced every `BuildConfiguration` method `PlatformBuildConfiguration`
(`Sources/SyntaxAnalysis/PlatformBuildConfiguration.swift`) implements, since this is what
`detectTargetPlatform`'s resolved `TargetPlatform` actually feeds:

- `TargetPlatform` itself (`iOS`/`macOS`/`tvOS`/`watchOS`/`unknown`) has **no case for
  device-vs-simulator at all** -- structurally incapable of representing that distinction.
- `Self.platform(fromTargetTriple:)` (`SwiftIsolationMap.swift`) extracts only the OS-family
  component right after `-apple-` (stops at the first non-letter character) -- `arm64-apple-
  ios15.6-simulator` and `arm64-apple-ios15.6` both parse to the identical `.iOS` case.
- `isActiveTargetEnvironment(name:)` -- the one `BuildConfiguration` method that would matter for
  a real `#if targetEnvironment(simulator)` guard -- is hardcoded `{ true }` unconditionally
  (deliberately permissive by design, per this same file's own doc comment), **never consulting
  the real platform at all**.

Net: whatever `-target` a compiler-args source reports, this tool's own `#if os(...)`/`#if
targetEnvironment(...)` evaluation for `SyntaxAnalysis` extraction is **already** blind to the
device/simulator distinction, by a pre-existing design choice unrelated to this spike. Feeding it
device-flavored args instead of simulator-flavored ones changes nothing here.

## Step 5 — The live-`sourcekitd`-query consumer: proven real, concrete harm

Live-fallback/the external-isolation oracle don't go through `PlatformBuildConfiguration` at all --
they hand the raw compiler-argument array straight to `sourcekitd` via `SourceKitDClient.cursorInfo`
(`CursorInfoRequest(sourceFile:byteOffset:compilerArguments:)`), which builds a real AST using
*exactly* the arguments given. Tested this directly, not theorized: found a real file with a real
`#if targetEnvironment(simulator)` guard in Project Iris (`Common/AppGroupFetcher.swift:18-23`),
extracted the *real* simulator arguments for its target from an actual `-verbose` build's own log
(byte-for-byte what `LiveXcodeCompilerArgumentsProvider` itself would produce, including proper
backslash-unescaping of the response-file's own space-containing paths), and ran real
`cursorInfo` queries with **both** the real simulator args and the device args
`-showBuildSettingsForIndex` returned, against the identical already-built private DerivedData
(which, confirmed directly, contains **only** a `Debug-iphonesimulator` build -- no `Debug-
iphoneos` directory exists anywhere in it).

**Device args produced real, structural sourcekitd compile failures**, not a subtly-different
answer:

```
module map file '.../GeneratedModuleMaps-iphoneos/AppMetricaAdSupport.modulemap' not found
module map file '.../GeneratedModuleMaps-iphoneos/KSCrashRecordingCore.modulemap' not found
  ... (20 real CocoaPods/dependency module maps, all -iphoneos, none of which exist -- this
  DerivedData only ever generated the -iphonesimulator variants)
error opening input file '.../Debug-iphoneos/.../DerivedSources/GeneratedAssetSymbols.swift'
stat cache file '...iphoneos26.4-...sdkstatcache' not found
Lsboutique-BridgingHeader.h:4:9: error: 'RFIPay.h' file not found
AwardsListItemCell.swift:2:8: error: no such module 'SVGKit'
```

Every one of these is a real artifact that only exists for whichever platform was *actually built*
into this DerivedData (generated module maps, generated asset symbols, SDK stat caches) -- device
args ask `sourcekitd` to assemble a compilation context for a platform variant that was simply never
built here. Since `Ls_net_ru`'s own `-import-objc-header`/full sibling-file-list apply to *every*
file in the target uniformly, this isn't confined to one query location -- a cursor-info query
anywhere in this target's own source, under device args, hits the same broken context. The **one**
successful device-args query in this test (`fatalError(_:file:line:)` inside the file's own `#else`
branch) succeeded only because it resolves to a pure Swift-standard-library symbol, which needs none
of the missing project-specific generated artifacts -- not evidence the mismatch is safe, the
opposite: it's the one case degenerate enough not to depend on what's actually missing.

## Step 5b — Re-verified directly on line 19 itself, with a non-degenerate positive result

Re-ran the same comparison later, this time scoped exactly to line 19 (`return ""`, the body of
the `#if targetEnvironment(simulator)` branch at `AppGroupFetcher.swift:18-23` -- the directive
itself is on line 18) -- against a **freshly re-captured** clean `-verbose` simulator build and a
**freshly re-queried** `-showBuildSettingsForIndex` device-args JSON, both against the same real
private DerivedData (still simulator-only). Probed every single byte offset across line 19 (22
offsets), both argument sets, using the project's own real parsing code paths directly
(`CompilerArgsLogParser.parseXcodeSwiftCompileInvocations` + `LiveXcodeCompilerArgumentsProvider
.unescaped` + `CompilerArgumentsSanitizing.sanitized`, not hand-rolled parsing) so the probe can't
diverge from what production actually does.

**Result: device args failed at every single one of the 22 offsets** (`malformedResponse("cursor-
info result had no key.usr")`) -- **simulator args failed at 20 of them (no queryable symbol at
those positions, expected for whitespace/`return` keyword) but succeeded at the 2 offsets landing
on the `""` string literal itself**, correctly resolving it as `String` (`usr=s:SS`). This is a
clean, non-degenerate result (unlike Step 5's own `fatalError` case, which succeeded under device
args only because it happens not to depend on anything missing) -- a real, ordinary symbol on the
exact line the user asked about, resolved correctly under simulator args and unconditionally
broken under device args, on every probed offset. Confirms Step 5's finding was not an artifact of
which offset happened to be picked.

## Step 6a — Nuance sweep: no invocation variant fixes the platform mismatch

Before accepting Step 5/5b as final, tried every plausible flag-level workaround, empirically, on
Project Iris:

1. **No `-destination`/`-sdk` at all** -- matches how real-world consumers of this flag actually
   invoke it (`k-ymmt/xcode-build-server`, `khlopko/xcode-bsp`: neither ever passes a destination
   to `-showBuildSettingsForIndex`, only to a real `build`). Still device.
2. **Trailing `build` action appended** (`-showBuildSettingsForIndex ... build`) -- motivated by
   `rdar://26950139` (`xcodebuild -showBuildSettings` ignoring a scheme's per-action
   `CONFIGURATION`, unfixed since 2016; the repro there depends on which build-action verb is
   appended). Output byte-identical to the no-action case -- still device.
3. **Explicit `-configuration Debug`** -- same motivating radar, testing whether it's actually the
   *configuration* axis (not destination) that's misrouted here. Byte-identical -- still device.
4. **`-sdk iphonesimulator` as a real, first-class `xcodebuild` CLI flag** (distinct from the
   `SDKROOT=` build-setting override tried in Step 3) -- still device, byte-identical.

None of the four real open-source Xcode/BSP wrappers found via GitHub code search
(`k-ymmt/xcode-build-server`, `khlopko/xcode-bsp`, `aelam/sourcekit-bsp`) pass a destination to
`-showBuildSettingsForIndex` either -- and `khlopko/xcode-bsp`'s own `warmupBuild` does a real,
destination-less `xcodebuild ... build` first, then queries settings with no destination override,
same pattern tried and confirmed still-broken above. No known invocation makes this command
respect the actually-built platform.

### Root cause, found directly (not inferred)

Cross-referenced two things: `swiftlang/swift-build` (Apple's real 2024 open-sourcing of
`SWBBuildService`, the engine `xcodebuild` talks to under the hood -- confirmed via this project's
own real build logs, `xcodebuild -> SWBBuildService -> clang`) and the real
`Build/Intermediates.noindex/XCBuildData/*.xcbuilddata/build-request.json` files SWBBuildService
itself caches inside our own private DerivedData -- one real, inspectable JSON file per distinct
build description it has ever planned there, containing the exact `BuildRequest` parameters used.

`swift-build`'s indexing-info handler (`Sources/SWBBuildService/Messages.swift`,
`handleIndexingInfoRequest`) is destination-aware on its own terms: it plans a fresh
`BuildDescription` from whatever `BuildRequest` it's handed (`TargetBuildGraph` +
`BuildPlanRequest`, using the request's own `activeRunDestination`) unless the client already
supplies a `buildDescriptionID` for a cache-only lookup. So the engine itself isn't hardcoding
device -- it faithfully builds whatever destination it's told.

The real `build-request.json` files prove exactly where the destination gets lost. Three cached
build descriptions existed in our private DerivedData at once, from different real invocations:

| cached description | when | `activeRunDestination.platform` | how it was produced |
|---|---|---|---|
| `21896e8d...` | 10:29 | `iphonesimulator` | the real `xcodebuild ... build` with `-destination "generic/platform=iOS Simulator"` |
| `3db1dc32...` | 10:41 | `iphoneos` | `xcodebuild ... -showBuildSettingsForIndex` (no destination) |
| `07d9c6de...` | 10:58 | `iphoneos` | `xcodebuild ... -sdk iphonesimulator -showBuildSettingsForIndex` |

The real `build` action, given `-destination`, correctly produces a build description with
`activeRunDestination.platform: iphonesimulator` -- proof `-destination` isn't broken in general,
and proof `SWBBuildService`'s own planning logic (open source, read above) is destination-faithful.
The **same DerivedData**, queried with `-showBuildSettingsForIndex` and an explicit
`-sdk iphonesimulator`, still produces a *fresh* build description (a different hash, genuinely
re-planned, not a stale cache hit) with `activeRunDestination.platform: iphoneos` -- meaning
`xcodebuild`'s own request-construction code, specifically for `-showBuildSettingsForIndex`,
builds a `BuildRequestMessagePayload` with a hardcoded/defaulted device `activeRunDestination`,
discarding `-destination`/`-sdk` before that request ever reaches `SWBBuildService`.

**This settles it precisely**: the bug is not in the open-source `swift-build` engine (confirmed
destination-faithful), not in `.xcscheme` (confirmed no platform field exists there to misread --
checked directly, `ls.net.ru.xcscheme`'s `LaunchAction`/`TestAction`/`ProfileAction`/`AnalyzeAction`
carry only `buildConfiguration`), and not caused by this project's own `xcodeIndexingBuildSettings`
overrides (checked, only sets `CODE_SIGNING_*`/`COMPILER_INDEX_STORE_ENABLE`, never
`TARGET_DEVICE_PLATFORM_NAME`). It's specifically inside `xcodebuild`'s own closed-source CLI
argument-to-`BuildRequest` translation for the `-showBuildSettingsForIndex` flag -- invisible to
us, and (per the empirical sweep above) not steerable by any flag combination tried. Conclusion
stands: not a flag problem, and now proven structural rather than merely presumed so.

## Step 7 — Real end-to-end comparison: two full runs against Project Iris

Rather than stop at the single-query probe (Step 5b), wired the exact broken mechanism into the
real pipeline as a throwaway spike (`ShowBuildSettingsForIndexCompilerArgumentsProvider`, gated by
an undocumented `SWIFT_ISOLATION_MAP_SPIKE_SBSFI` env var in `makeCompilerArgumentsProvider` --
never a real CLI flag, removed again immediately after this comparison) and ran the full tool
twice against the same warm private DerivedData, same corpus (`~/ios`, 2226 files), same
`--oracle-workers 8`:

| metric | Run A (honest rebuild) | Run B (`-showBuildSettingsForIndex` spike) | Δ |
|---|---|---|---|
| `crossActorBoundaries` (edge count) | 1790 | 5103 | **+185%** |
| `highRiskBoundaries` | 1472 | 1478 | ~flat |
| `unspecifiedIsolation` | 114 | 764 | **+570%** |
| live-fallback resolved | 8638/10180 (85%) | 6048/10180 (59%) | -2590 |
| external oracle resolved | 3788 | 3109 | -679 |
| external oracle "unknown" | 1472 | 2693 | +1221 |
| edges with `isUnknown=true` | 28 | 3367 | +3339 |
| total wall time | ~12.6 min | 7:34 (tool-reported) | -5 min |

Edge-level diff (keyed by `callerUSR`/`calleeUSR`/file/line): **1721 edges shared** between both
runs, **30 edges present only under the honest run** (lost), **3311 edges present only under the
spike** -- of which **3296 (99.5%)** carry `isUnknown=true`, `risk=medium`,
`calleeIsolation="unspecified"`. Mechanism confirmed directly from the data, not inferred: when a
live query fails (the Step 5b failure mode, now firing across most of the project instead of one
line), the tool doesn't silently drop the edge -- it conservatively reports an unresolved-isolation
cross-actor boundary instead, exactly the shape `AnalysisReportBuilder`'s conservative-on-
uncertainty design is supposed to produce. Run B's own real, unprompted stderr output confirms the
same conclusion from inside the tool itself: `"Warning: 3584/5103 cross-isolation edges (70%) have
unresolved isolation on at least one side. This usually means the external-isolation oracle didn't
get real compiler arguments for most of the project this run"`.

**Conclusion**: the ~5-minute speed win is real, but the accuracy cost is not a minor degradation
-- `crossActorBoundaries` nearly triples and `unspecifiedIsolation` grows 6.7x, almost entirely
spurious unresolved-isolation noise, not new genuine findings. Confirms Step 6's conclusion at full
pipeline scale, not just a single query: `-showBuildSettingsForIndex` cannot replace the current
clean-rebuild-based compiler-argument resolution for Project Iris. Spike code removed from the tree
after this comparison; not shipped, not to be revived without first solving the platform-selection
problem for real (Step 6a: no known flag does this).

## Step 8 — Final conclusion

**The platform-selection caveat is real, disqualifying harm, confirmed at every level: a single
query (Step 5b), and the full real pipeline end-to-end (Step 7).** Wiring `-showBuildSettingsForIndex`
into the real pipeline as-is (replacing or supplementing the clean-rebuild-retry logic in
`LiveXcodeCompilerArgumentsProvider`) doesn't just theoretically risk breaking live-fallback/the
external-isolation oracle -- Step 7's real, measured run shows it nearly triples
`crossActorBoundaries` (1790 -> 5103) and inflates `unspecifiedIsolation` 6.7x (114 -> 764), almost
entirely spurious unresolved-isolation edges, not new genuine findings, while masquerading as a
working, faster alternative (the *tool itself* doesn't crash; queries just fail and fall back to
`unknown`, exactly the silent-degradation shape `docs/task-sourcekitd-cooperative-pool-starvation.md`'s
own `-skipMacroValidation`/`Macro ... must be enabled` precedent already warns about for this
codebase). Step 6a additionally confirms this isn't a solvable invocation nuance -- no destination/
configuration/action-verb combination tried changes the outcome, and no real-world Xcode/BSP
wrapper found in the wild works around it either.

**Not resolved (open for a future session, narrower than it used to be):** Step 6a already
localized the bug precisely -- it's inside `xcodebuild`'s own closed-source CLI-to-`BuildRequest`
translation, specifically for `-showBuildSettingsForIndex`, not in the open-source engine and not
in `.xcscheme`. So the real open question is no longer "is this a bug at all" -- it's **which
project-level input, if any, that closed-source translation is actually keying its device default
off of**, since it's provably not `-destination`/`-sdk`/`-configuration`/the scheme file itself.
Candidates worth checking on a second real project before assuming this is universal: the target's
own `SUPPORTED_PLATFORMS` build setting, whether a device destination is even present among the
scheme's *valid* destinations (`-showdestinations`) at all, or some other project-level default
unrelated to anything tried so far. This is a narrower, lower-urgency question than "is
`-showBuildSettingsForIndex` usable here" (Step 7/8 already answered that conclusively for Project
Iris) -- it only matters if `swift-build`'s own `prepareForIndexing` API (Step 9) turns out not to
be a viable replacement, since that path sidesteps the buggy CLI translation entirely rather than
depending on understanding it.
