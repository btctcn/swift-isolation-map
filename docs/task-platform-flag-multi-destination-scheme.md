# --platform: selecting a destination for a multi-platform scheme (issue #140)

**Status: CLOSED — fixed and real-corpus verified.** Closes
[issue #140](https://github.com/btctcn/swift-isolation-map/issues/140).

## Background

Issue #124's own fix (`SimulatorSDKFamily`) generalized `SwiftBuildCompilerArgumentsProvider` to
resolve compiler arguments for whichever Simulator platform `resolveDeterministicSimulatorDestination`
already picks -- confirmed on two real corpora with a *separate scheme per platform* (Swiftfin's
`Swiftfin tvOS`, home-assistant/iOS's `WatchApp`). A modern multiplatform SwiftUI target commonly
adds a new platform (visionOS) as an *additional destination on the same scheme* instead --
confirmed real on `IceCubesApp`: its single `IceCubesApp` scheme lists iOS Simulator, Mac Catalyst,
and visionOS Simulator as simultaneously-valid destinations. `resolveDeterministicSimulatorDestination`
always picked the first Simulator line (iOS), with no way for a user to ask for visionOS instead.

## Fix

Added `--platform <name>` (`SwiftIsolationMap.platform: String?`, default `nil` -- unchanged
behavior). Threaded as `preferredPlatform` through all three real call sites of
`resolveDeterministicSimulatorDestination` (the early destination/private-DerivedData resolution in
`run()`, the index-store-populating `build()`, and `LiveXcodeBulkExtractionEnvironmentProvider`'s own
`-showBuildSettings` call) -- all three needed updating consistently, or a `--platform visionOS`
run could resolve compiler arguments for visionOS while still bulk-extracting symbol-graph data for
iOS, a real, silent inconsistency worse than not having the flag at all.

`resolveDeterministicSimulatorDestination` now collects every real Simulator-flavored destination
line instead of stopping at the first one, and when `preferredPlatform` is given, matches it
case-insensitively by substring against each candidate. A name that doesn't match anything the
scheme actually offers throws `DestinationResolutionError.requestedPlatformNotAvailable` (listing
what *is* available) rather than silently falling back to a platform the user didn't ask for --
matching this project's own guiding principle that a wrong answer is worse than no answer.

## A second, real gap found verifying this against IceCubesApp: TargetPlatform had no visionOS case

Running `--platform visionOS` against `IceCubesApp` showed the destination *and* compiler-argument
resolution correctly reaching visionOS (`Using private DerivedData at
.../generic_platform_visionOS_Simulator/...`, 1844 files resolved across 184/184 targets) -- but
`Target platform: unknown`, not `visionOS`. `TargetPlatform` (`SyntaxAnalysis/
PlatformBuildConfiguration.swift`) had no `.visionOS` case at all, so `SwiftIsolationMap.platform
(fromTargetTriple:)` fell through to `.unknown` for any visionOS triple -- silently reverting
declaration extraction to platform-blind mode (`PlatformAwareSyntaxVisitor`'s own `.unknown`
fallback: every `#if`/`#elseif` branch extracted unconditionally), reintroducing exactly the
phantom-declaration failure class `docs/task-bulk-extraction-wrong-platform.md` exists to prevent.

**Confirmed real, not guessed**: a from-scratch `swiftc -target arm64-apple-xros1.0-simulator`
compile against the real visionOS Simulator SDK succeeded, confirming visionOS's real target-triple
OS component is `"xros"` (Apple's long-standing internal platform name, distinct from the public
`"visionOS"` name `#if os(visionOS)` and `SimulatorSDKFamily`'s own destination-string matching both
already use). Added `.visionOS` to `TargetPlatform`, `"xros"` to `platform(fromTargetTriple:)`, and
`.visionOS` to both `PlatformBuildConfiguration.osAliases` and `isActiveTargetEnvironment`'s own
Simulator-platform switch case (issue #139's `macCatalyst`-always-inactive reasoning applies
identically to visionOS, confirmed by the same architecture).

## Verification

- New unit tests: `resolveDeterministicSimulatorDestination`'s own preferred-platform matching
  (default unchanged, visionOS reached past iOS, case-insensitive matching, Mac Catalyst never even
  a candidate, an unavailable platform throws with the real available list, a single-platform scheme
  unaffected), `platform(fromTargetTriple:)`'s new `"xros"` case, and `isActiveTargetEnvironment`
  extended to cover `.visionOS`.
- `swift test -c release`: full suite passing (see PROJECT-HISTORY.md entry for the exact count).
- **Real-corpus verification against `IceCubesApp`** (the issue's own motivating project):
  `--platform visionOS` now correctly resolves `Target platform: visionOS` (was `unknown`), with
  destination/compiler-argument resolution confirmed reaching the real visionOS Simulator SDK for
  1844 files across 184/184 targets. The full index-store-populating build fails downstream on a
  missing `IceCubesApp.xcconfig` -- a pre-existing, environment-specific gap in this local checkout
  (a private/gitignored config file), unrelated to this fix and outside this project's control.
- **Real-corpus A/B on Project Iris** (default, no `--platform`), controlled (`git stash`, identical
  index store, identical corpus state): byte-identical summary and a full set-based node diff of
  zero added/removed/changed -- confirms the new opt-in flag and the `.visionOS` case addition have
  zero effect on existing iOS-platform analysis.
