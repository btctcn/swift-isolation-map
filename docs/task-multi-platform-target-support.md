# Investigation: issue #124 — multi-platform target support

**Status: the core gap is fixed.** `SwiftBuildCompilerArgumentsProvider` (this project's main
`CompilerArgumentsProviding` conformer for Xcode projects) was unconditionally hardcoded to iOS
Simulator at three separate points, silently discarding every real tvOS/watchOS/visionOS target's
own compiler arguments regardless of which scheme the user asked to analyze. Generalized to any of
the four real Simulator-based Apple platforms; a pure macOS/host scheme's behavior is deliberately
left exactly as it was (no real corpus evidence to generalize that case yet).

## Investigation

Issue #124 was filed as a deliberate scoping placeholder, motivated by "a Swiftfin tvOS target is
currently ignored." A real, local Swiftfin checkout (`~/corpora/Swiftfin`, two real, separate
schemes: `Swiftfin` (iOS) and `Swiftfin tvOS`) was used to find the real, current behavior directly
rather than reason about it abstractly.

First attempt (`--scheme "Swiftfin tvOS" --auto-build`) failed immediately: `xcodebuild: error:
Could not configure request to show build settings: Found no destinations for the scheme 'Swiftfin
tvOS'`. Root cause: no tvOS Simulator runtime was installed on this machine at all (`xcrun simctl
list runtimes` showed only iOS). Installed tvOS/watchOS/visionOS platforms via `xcodebuild
-downloadPlatform <name>` -- a real, pure environment gap, not a code issue, closed first before any
of this project's own code was in question.

With the runtime installed, a second real attempt surfaced the actual code bug: the verbose log
showed `[verbose] Using private DerivedData at .../Swiftfin_tvOS/generic_platform_tvOS_Simulator/
default` (correct -- `resolveDeterministicSimulatorDestination` already picks the right destination
per scheme, no fix needed there) immediately followed by `[verbose] Target platform: iOS` (wrong).

## Root cause: `SwiftBuildCompilerArgumentsProvider` hardcoded to iOS Simulator at three points

- `params.activeRunDestination` unconditionally set `platform: "iphonesimulator"`, `sdk:
  "iphonesimulator<version>"`, `sdkVariant: "iphonesimulator"`, regardless of the scheme's own real
  platform.
- `matchesSimulatorPlatform(_:)` unconditionally checked the returned `-sdk` value for the substring
  `"iphonesimulator"`. Per that function's own pre-existing doc comment, `generateIndexingFileSettings`
  doesn't actually honor `activeRunDestination` for a target whose own `SUPPORTED_PLATFORMS` doesn't
  include it -- it silently returns that target's own real, natively-appropriate args instead (e.g.
  `Swiftfin tvOS`'s own real `AppleTVSimulator` args). This filter's job is exactly to drop those
  "wrong platform, but not an error" responses -- but hardcoded to iOS, it dropped the *tvOS*
  target's own correct response even when *tvOS itself* was the platform being requested, and (for
  the 127 of 152 real Swiftfin files that live in the shared `Swiftfin/` directory, compiled by
  *both* targets) let the *iOS* sibling target's own always-succeeding `iphonesimulator` response
  win by default, regardless of which scheme was actually being analyzed.
- `simulatorSDKVersion()` unconditionally queried `xcrun --sdk iphonesimulator --show-sdk-version`.

Confirmed directly (`xcodebuild -showsdks`) the real SDK-family identifiers for all four platforms:
`iphonesimulator`, `appletvsimulator`, `watchsimulator`, `xrsimulator`.

## Why `preferredArguments` (PR #106) didn't need changing

`preferredArguments`'s own path-component-matching heuristic (added for a real WordPress-iOS shape:
two *same-platform* extension targets sharing files) was suspected as a second contributing cause,
since Swiftfin's own targets are named `Swiftfin iOS`/`Swiftfin tvOS` while their shared source
directory is just `Swiftfin` -- neither target name is a literal path component of a shared file's
location, so the existing heuristic could never disambiguate them by name. In practice this turned
out not to matter: once `matchesSimulatorPlatform` correctly filters by the *requested* platform's
own SDK family, a shared file compiled by both `Swiftfin iOS` and `Swiftfin tvOS` only ever has *one*
candidate left in `candidatesByPath` for any single run (the other target's own response, correctly
recognized as a different, incompatible platform, is filtered out before `preferredArguments` is
ever called) -- there is no ambiguity left for `preferredArguments` to resolve in this specific
shape. Left unchanged; still handles its own original same-platform, multiple-target case exactly as
before.

## The fix

New `SimulatorSDKFamily` enum (`iphonesimulator`/`appletvsimulator`/`watchsimulator`/`xrsimulator`),
with `SimulatorSDKFamily.parsing(destination:)` parsing `resolveDeterministicSimulatorDestination`'s
own real return-value shape (`"generic/platform=<Name> Simulator"`) directly -- no new query, no new
dependency, reusing a destination this project's own pipeline already computes before constructing
this provider. `SwiftBuildCompilerArgumentsProvider` now takes an optional `destination: String?` at
construction (threaded from `SwiftIsolationMap.swift`'s own already-computed `destination` local),
falls back to `.iphonesimulator` for `nil`/unrecognized (a pure macOS/host scheme, or any other case
without real evidence yet -- this project's own unchanged, pre-existing behavior for that case), and
uses the resolved `sdkFamily` for `activeRunDestination`, `matchesSimulatorPlatform`, and
`simulatorSDKVersion`.

## A separate, confirmed-independent real Swiftfin/environment issue

A full end-to-end analysis run for either Swiftfin scheme currently fails during index-store
generation with `ComputeTargetDependencyGraph` failing -- confirmed real and **entirely independent
of this project's own code** by reproducing it with a plain, manual `xcodebuild build -scheme
"Swiftfin tvOS" -destination "generic/platform=tvOS Simulator"` invocation with no involvement of
this tool at all, and confirming the *iOS* scheme (`Swiftfin`) fails identically. Not filed as a
swift-isolation-map issue -- it's a real defect/environment mismatch in Swiftfin's own SPM dependency
graph under this machine's Xcode 26.4, outside this project's control, not something this codebase
can fix.

## Verification

- `swift test`: 600/600 passing (including 7 new/updated tests: `SimulatorSDKFamily.parsing`, and
  `matchesSimulatorPlatform` across all four platforms).
- **Zero regression, Project Iris (iOS)**: a real, controlled A/B (`git stash`, identical corpus
  state) between the pre-fix and post-fix binaries produced byte-identical
  `crossActorBoundaries`/`highRiskBoundaries`/`unspecifiedIsolation` (1555/1486/113 -- the corpus's
  own numbers shifted from this project's earlier-established 1537/1462/231 baseline for unrelated
  reasons, confirmed by the *pre-fix* binary reproducing the exact same new numbers on the same,
  current corpus state).
- **Zero regression, Swiftfin (iOS)**: `Target platform: iOS` still correctly detected for the
  `Swiftfin` scheme.
- **The real fix, confirmed directly**: `Target platform: tvOS` now correctly detected for the
  `Swiftfin tvOS` scheme (previously `iOS`), with a genuinely different resolved-file count (3656
  files across 481 targets, vs. 3772 for the iOS scheme) -- not just a relabeled identical run.
- No full before/after edge-count comparison for Swiftfin tvOS itself -- blocked by the separate,
  confirmed-independent `ComputeTargetDependencyGraph` environment issue above, which prevents index
  store generation for *either* Swiftfin scheme in this environment today.

## watchOS and visionOS: verified against two more real, independent corpora

Per explicit instruction, found and verified against two more real, actively-maintained open-source
GitHub projects (`~/corpora/home-assistant-iOS`, `~/corpora/IceCubesApp`) -- not left as an
unverified claim.

**watchOS -- confirmed working, real, complete run.** `home-assistant/iOS`
(`github.com/home-assistant/iOS`) is structured the same way as Swiftfin: a real, separate `WatchApp`
scheme (plus `WatchApp (Complication)`/`WatchApp (Notification)`/`WatchWidgetsExtension`), distinct
from the main app's `App-Debug`/`App-Release`. `--scheme "WatchApp" --auto-build` ran to full
completion (unlike Swiftfin's tvOS scheme, not blocked by any external issue this time):
`[verbose] Target platform: watchOS` (confirmed correct), `SwiftBuild direct: resolved compiler
arguments for 2458 file(s) across 606/606 target(s)` (every target succeeded), and a complete report
(`crossActorBoundaries: 786`, `highRiskBoundaries: 21`). A real, unrelated compile error surfaced
during index-store generation (`no such module 'CoreMediaIO'` in a handful of `Shared` files that
import a macOS/iOS-only framework with no watchOS guard) -- a genuine incompatibility in *this*
corpus's own shared code under watchOS, not a defect in this fix; the resulting high overall
unresolved-edge percentage reflects that real compile failure cascading, not a platform-detection
regression (confirmed separately: all 606 targets resolved their own compiler arguments without
error at the `SwiftBuildCompilerArgumentsProvider` level).

**visionOS -- a real, different, *not yet handled* shape found.** `Dimillian/IceCubesApp`
(`github.com/Dimillian/IceCubesApp`) has no separate visionOS scheme at all -- it's a single scheme
(`IceCubesApp`) whose real `-showdestinations` output lists iOS Simulator, macOS (Catalyst), *and*
visionOS Simulator as separate, simultaneously-valid destinations for the *same* scheme (a modern
multiplatform SwiftUI target, unlike Swiftfin/home-assistant's one-platform-per-scheme convention).
`resolveDeterministicSimulatorDestination`'s own "first destination line whose platform contains
Simulator wins" logic picks whichever platform `xcodebuild -showdestinations` happens to list first
-- confirmed directly, that's iOS Simulator for this real project, before visionOS Simulator ever
appears in the list. Running `--scheme "IceCubesApp"` against this real project confirmed exactly
that: `[verbose] Target platform: iOS`, not visionOS -- this fix's own `SimulatorSDKFamily`
generalization is necessary but not sufficient for this shape, since the *destination selection*
itself never reaches visionOS in the first place. This is a real, distinct gap from what issue #124's
own real evidence (Swiftfin) motivated and this fix closes -- **not fixed here**: doing so would need
a way to choose *which* of several simultaneously-valid platform destinations for one scheme to
analyze (e.g. a new `--platform` flag), a materially different, additional feature than generalizing
which SDK family a *given*, already-resolved destination maps to. Left as a known, confirmed-real
follow-up, not silently expanded into this fix's own scope.
- A pure macOS Xcode scheme: deliberately left exactly as before this fix (falls back to
  `.iphonesimulator`), since no real macOS-Xcode-scheme corpus has confirmed whether that case was
  already broken in the same way -- a distinct question from what this issue's own real evidence
  (Swiftfin tvOS) could confirm.
- Issue #139 (filed during this investigation, in response to a direct question about simulator/
  device compile-time branching): `PlatformBuildConfiguration.isActiveTargetEnvironment` answers
  `true` unconditionally for any name, never verified against a real corpus -- a separate, narrower
  gap from this one.
