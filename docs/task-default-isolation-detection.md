# Task: thread the real, configured `-default-isolation` value into the analyzed project's rule set

**Status: closed** — fixed and shipped, PR #31. Tracks
[issue #30](https://github.com/btctcn/swift-isolation-map/issues/30). Confirmed real bug,
not a hypothesis: `Swift62RuleSet`/`Swift63RuleSet` fully implement SE-0466's opt-in
module-default-isolation model (12 tested rules, `docs/isolation-rules.md`), but in production
can never resolve to anything other than `.nonisolated` — the tool silently reports every
module-default-eligible declaration as `nonisolated` even when the real analyzed project actually
configured `-default-isolation MainActor`.

## Root cause

`IsolationRuleSetRegistry.ruleSet(forSwiftVersion:defaultIsolation:)`
(`Sources/IsolationCore/IsolationRuleSetRegistry.swift:6-9`) defaults `defaultIsolation` to
`.nonisolated`. Its one production call site, `resolveRuleSet` in
`Sources/swift-isolation-map/SwiftIsolationMap.swift:225-236`, never passes the parameter.
Confirmed via `grep -rn "IsolationRuleSetRegistry.ruleSet" Sources/ Tests/`: every other call site
is a test passing it explicitly. Confirmed via `grep -rn -- "-default-isolation" Sources/`: nothing
in this codebase ever reads the real flag from actual build arguments — the string only appears in
doc comments. No CLI override flag exists either.

## Step 1 — Hypothesis

The real configured value is discoverable from the same compiler-argument extraction pipeline
already used for the external-isolation oracle (`CompilerArgumentsProviding`,
`Sources/ProjectResolution/`) — no new mechanism needed, just read the already-collected per-file
compiler args for one project file and look for `-default-isolation <value>`. This should hold
uniformly for both SwiftPM and Xcode projects, since both `SwiftPMCompilerArgumentsProvider` and
`XcodeBuildLogCompilerArgumentsProvider` already parse *real, invoked* `swiftc`/`swift-frontend`
command lines into `[String]`, regardless of what manifest/project setting produced them.

## Step 2 — Spike (confirmed)

Built a real, throwaway SPM package (`swift-tools-version: 6.2`) with:

```swift
.target(
    name: "DefaultIsolationSpike",
    swiftSettings: [.defaultIsolation(MainActor.self)]
)
```

Ran `swift build -v` for real, captured the log, and ran this project's actual
`CompilerArgsLogParser.parse(buildLog:)` against it via a throwaway test (added, run, then
deleted — never committed). Result:

```
SPIKE: FILE=.../Spike.swift hasFlag=true value=MainActor
```

**Confirmed end-to-end for the SwiftPM path**: `-default-isolation MainActor` survives from the
real manifest setting, through the real `swift build -v` invocation, through this project's own
parser, into the final per-file argument array, unmodified. Also confirmed via
`swiftc --help-hidden`: the real flag syntax is `-default-isolation MainActor|nonisolated`
(defaults to `nonisolated`), matching this project's existing assumption about the untouched case.
Also confirmed via the real, local `PackageDescription.swiftinterface`
(`.../ManifestAPI/PackageDescription.swiftmodule/arm64-apple-macos.swiftinterface:88`): the real
manifest API is `SwiftSetting.defaultIsolation(_ isolation: MainActor.Type?, _ condition:
BuildSettingCondition? = nil) -> SwiftSetting`.

**Not yet spiked**: the Xcode path (`XcodeBuildLogCompilerArgumentsProvider` /
`CompilerArgsLogParser.parseXcodeSwiftCompileInvocations`) — would need a real `.xcodeproj` target
with the equivalent build setting. Lower risk than the SwiftPM path was before spiking, since the
parser works by capturing the real, already-resolved `swiftc` invocation rather than
re-interpreting any named setting itself — but "lower risk" is not "confirmed," so this should be
spiked for real before being treated as settled, not assumed from the SwiftPM result alone.

## Step 3 — Design question this doc exists to settle before writing code

`resolveRuleSet` (`SwiftIsolationMap.swift:96`) runs **before** any `CompilerArgumentsProviding` is
constructed — that happens later, inside `resolveExternalIsolation` (~line 138, provider built at
~line 408-426). Constructing the provider is expensive (a real `swift build -v` /
`xcodebuild -verbose` invocation), so this is a real ordering conflict, not a cosmetic one. Two
shapes:

1. **Construct the provider once, earlier** (before `resolveRuleSet`), and pass it down to both
   the rule-set resolution and `resolveExternalIsolation` — a single construction, reused. Requires
   moving/restructuring `resolveExternalIsolation`'s existing `switch container` provider-selection
   logic (lines 410-426) up into `run()`, or extracting it into its own small function callable from
   both places.
2. **Resolve the rule set lazily / later**, after external isolation resolution has already built
   its provider, then thread that same provider backward into `IsolationInferenceEngine`
   construction. Needs checking how early `ruleSet` is otherwise consumed in `run()` before
   settling on this shape.

Shape 1 looks like less rework (one relocation, one shared construction) but hasn't been checked
against every other current use of `ruleSet`/`compilerArguments` in `run()` — that check is part of
implementation, not this doc.

Whichever shape is picked, resolving the actual value only needs **one** representative
project-local Swift file's compiler args (the flag is per-target, not per-file) — any file already
known to belong to the analyzed target/module works; no need to query every file.

## Step 4 — Code (done)

Shape 1 implemented. `makeCompilerArgumentsProvider(container:processRunning:fileSystem:)` (new,
`SwiftIsolationMap.swift`) extracts the existing `switch container` provider-selection logic;
`run()` now constructs it once, before `resolveRuleSet`, and both the new default-isolation
detection and `resolveExternalIsolation` (now taking `compilerArguments:` as a parameter instead of
building its own) share that single instance. `sourceFiles` moved up to before rule-set resolution
too (it didn't depend on anything computed after its old position). `resolveRuleSet` and
`IsolationRuleSetRegistry.ruleSet` both now take the real, detected `defaultIsolation` instead of
relying on the implicit `.nonisolated` default.

New: `detectConfiguredDefaultIsolation(compilerArguments:sourceFiles:)` — searches real per-file
compiler args for the first genuine target-source file for `-default-isolation <value>`.

## Step 4.5 — A real bug the first live run caught (return to step 1, briefly)

**A pure unit-level spike (step 2) was not enough — the first full, real, end-to-end run against
the actual CLI caught a live bug the isolated spike test couldn't have.** First live run against
the spike package printed `Configured default isolation: nonisolated` — wrong, the package has
`.defaultIsolation(MainActor.self)` configured. Root cause: `StalenessOrchestration.swiftFiles`
includes `Package.swift` itself as a project source file (correct, pre-existing, intentional
behavior for staleness/syntactic-analysis purposes) — and SwiftPM's own real `swift build -v`
compiles the manifest as its *own* `-primary-file` invocation, carrying
`-package-description-version` but never `-default-isolation`. `detectConfiguredDefaultIsolation`'s
original "first file `compilerArguments` can resolve" logic resolved `Package.swift` first (it's
listed before `Sources/.../Spike.swift` in `sourceFiles`' walk order), found no flag on the
manifest's own args, and returned `.nonisolated` immediately — never reaching the real target file
that actually carried the flag.

**Fixed** by explicitly skipping any file named `Package.swift` in the search (a manifest is never
a genuine compiled-target source file for this purpose, regardless of walk order). Re-ran the exact
same live test after the fix: `Configured default isolation: globalActor(name: "MainActor")`,
`SomeType`/`doWork` both resolve `globalActor(MainActor)`, `mainActorTypes: 1` in the summary.

This is exactly the project's own recurring lesson (see `docs/retrospective-oracle-query-location.md`):
a passing unit-level check against captured data is not the same claim as "works end-to-end" —
only the real CLI run against a real, fully-built project surfaced this one.

## Step 5 — Tests and verification

**Real, live, end-to-end verification (not mocked)**, both directions, against real throwaway SPM
packages built for this purpose:

- **Positive**: package with `.defaultIsolation(MainActor.self)` → `Configured default isolation:
  globalActor(name: "MainActor")`; `SomeType`/`doWork` resolve `globalActor(MainActor)`;
  `mainActorTypes: 1`.
- **Negative control**: an otherwise-identical package with no `defaultIsolation` setting at all →
  `Configured default isolation: nonisolated`; both declarations resolve `nonisolated` — confirming
  the common, unconfigured case is unaffected by this change.

**New permanent regression test**: `Tests/Fixtures/default-isolation/` (a real `swift-tools-version:
6.2` SPM package with `.defaultIsolation(MainActor.self)` on its one target) and
`Tests/swift-isolation-mapTests/DefaultIsolationCLITests.swift` — a real CLI invocation end to end
(same style as `CapstoneCLITests`), asserting: the module-default-eligible type/method resolve
`globalActor(MainActor)`; an explicitly `nonisolated`-attributed type still resolves `nonisolated`
(confirms rule 1 still beats rule 4, not regressed by this fix); `summary.mainActorTypes == 1`.

Full `swift test -c release` suite: 247/247 passing (246 pre-existing + this new test), confirming
no regression anywhere else in the suite.

## Step 6 — Documenting results

Done — this document (steps 4-5 above) is the record: root cause, the fix's shape, the real bug
the first live run caught and its fix, and the final real/unit test results. `docs/README.md`'s
index and issue #30 both point here.

## Step 7 — PR

Next: commit (`Sources/swift-isolation-map/SwiftIsolationMap.swift`, this doc, the new fixture +
test), open a PR referencing issue #30, wait for CI, merge.
