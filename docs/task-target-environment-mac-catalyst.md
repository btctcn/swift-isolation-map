# PlatformBuildConfiguration.isActiveTargetEnvironment always answered true (issue #139)

**Status: CLOSED — fixed and real-corpus verified.** Closes
[issue #139](https://github.com/btctcn/swift-isolation-map/issues/139).

## Background

`PlatformBuildConfiguration.isActiveTargetEnvironment(name:)` unconditionally answered `true` for
any queried name (`"simulator"`, `"macCatalyst"`, anything else), matching this file's own
documented, deliberate policy for every `BuildConfiguration` axis beyond `os(...)`/`canImport(...)`/
custom `-D` conditions: permissive until real evidence justifies doing better. At the time issue
#139 was filed, a check against Project Iris and SQLumen found `targetEnvironment(simulator)`
exactly once, gating a plain statement inside a function body -- never a declaration -- so there was
no real evidence yet either way.

## Real-corpus sweep (this session)

Re-swept every corpus available to this project, this time **including CocoaPods dependencies**
(the original 2026-08-30 sweep this file's own doc comment references excluded `Pods/`, which turned
out to matter): Project Iris still has exactly one occurrence, statement-only, no declaration
impact. But two independent, actively-maintained real open-source apps
(`~/corpora/IceCubesApp`, `~/corpora/home-assistant-iOS`) have many real occurrences, several
gating **whole files** of declarations -- `LiveActivitySettingsView.swift:1`,
`YAMLSyntaxHighlighter.swift:1`, `HealthSensorListViewModel.swift:1`,
`HealthSensorListView.swift:1`, all starting `#if os(iOS) && !targetEnvironment(macCatalyst)`.

**Why the old unconditional `true` answered this shape backwards**: `!true == false`. Every one of
those real, active-on-a-Simulator-destination files would have had its declarations silently
excluded from extraction entirely -- the exact class of failure (a real declaration dropped) this
project's own guiding principle treats as strictly worse than a phantom one.

## Fix: a real, architecture-confirmed answer, not corpus-inferred

Unlike `isCustomConditionSet`'s own fix (issue #121, corpus-inferred from Project Iris's real
compiler arguments), this fix is confirmed by **this tool's own destination-resolution code**,
independent of any corpus:

- `resolveDeterministicSimulatorDestination` (`ProjectResolution/XcodeIndexingBuildSettings.swift`)
  only ever returns `nil` or a destination whose own platform string contains `"Simulator"` -- it
  structurally can never select a Mac Catalyst destination.
- `SwiftBuildCompilerArgumentsProvider`'s own `nil`-destination fallback is `.iphonesimulator`
  (docs/task-multi-platform-target-support.md) -- Simulator-flavored either way.

So, for an Xcode container targeting `.iOS`/`.tvOS`/`.watchOS`, `"macCatalyst"` is confirmed always
inactive. `isActiveTargetEnvironment` now returns `false` specifically for that name on those three
platforms, and stays permissive (`true`) for every other name and for `.macOS`/`.unknown` (which
have no Simulator-destination concept in this tool's own model at all).

**Acknowledged residual gap, documented rather than assumed away**: this reasoning is specifically
about the Xcode-container destination path. A `Package.swift` container cross-compiled for iOS via a
custom SPM destination bundle would not go through `resolveDeterministicSimulatorDestination` at
all, so the same certainty wouldn't hold there -- never observed in any real corpus available to
this project, and `platform` alone carries no container-kind information to distinguish the two
cases if it ever did occur.

## Verification

- 7 new unit tests (`Tests/SyntaxAnalysisTests/PlatformBuildConfigurationTests.swift`): `macCatalyst`
  confirmed inactive (case-insensitively) for all three Simulator-destination platforms, every other
  name stays permissive, `.macOS`/`.unknown` stay permissive even for `macCatalyst`, plus an
  end-to-end `DeclarationExtractor` test reproducing the real
  `#if os(iOS) && !targetEnvironment(macCatalyst)` shape directly.
- `swift test -c release`: 620/620 passing.
- **Real-corpus A/B on Project Iris**, controlled (`git stash`, identical index store, identical
  corpus state, `--oracle-workers 8` both sides): a proper set-based diff (by USR, not a fragile
  positional list compare) found exactly 14 added nodes and 2 changed nodes, zero removed. All 14
  additions are real: `Pods/Kingfisher/Sources/Extensions/CPListItem+Kingfisher.swift` (a real
  CarPlay-list-item Kingfisher extension, gated `#if canImport(CarPlay) &&
  !targetEnvironment(macCatalyst)`) was silently excluded entirely before this fix -- every recovered
  declaration correctly resolves `globalActor(MainActor)` (CarPlay's own UI-thread requirement). The
  2 changed nodes are two Kingfisher declarations that previously had no real `location` (known only
  via external-oracle resolution, since the extractor never saw the guarding file as active) and now
  correctly carry their real file/line, one of them improving from `unspecified` to
  `globalActor(MainActor)`. `highRiskBoundaries` unchanged (1486/1486) -- zero regression;
  `crossActorBoundaries` -1, `unspecifiedIsolation` -6 (real, previously-hidden facts surfacing, not
  noise).
