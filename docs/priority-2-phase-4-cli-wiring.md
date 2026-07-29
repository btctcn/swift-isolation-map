# Priority 2, Phase 4 — end-to-end CLI wiring (empirical record)

The last phase in the originally-approved Priority 2 plan: every piece Phases 0-3 built
(SwiftSyntax extraction, project/scheme discovery, staleness primitives, IndexStoreDB linking)
existed as a tested library function, but `SwiftIsolationMap.run()` still printed "not yet
implemented." This phase wires all of it together and, for the first time, runs the tool for real
against real projects — including its own codebase.

## Two design gaps resolved before writing code, not assumed

**Swift version detection is two independent axes.** `swift package describe`'s `tools_version`
and `xcodebuild -showBuildSettings`'s `SWIFT_VERSION` are the project's *language mode* (a build
setting a project pins independently of which compiler builds it — confirmed against a real
project, SQLumen: reports `SWIFT_VERSION = 5.0` while being built by a Swift 6.3 toolchain).
Neither setting says which *compiler* is actually compiling; that only comes from the active
toolchain (`swift --version`). Resolution (`SwiftVersionDetection.effectiveVersion`): language
mode major < 6 always selects `Swift5RuleSet`, regardless of compiler version — that decoupling is
the entire point of Swift 6's opt-in migration. Only once the language mode has itself opted into
Swift 6 does the compiler version pick which `Swift6xRuleSet` applies.

Real output formats, confirmed empirically (not assumed from the architecture doc):
- `xcodebuild -showBuildSettings -project SQLumen.xcodeproj -scheme SQLumen` includes both
  `EFFECTIVE_SWIFT_VERSION = 5` and `SWIFT_VERSION = 5.0` on separate, indented lines — a naive
  `contains`/`hasSuffix` match on `"SWIFT_VERSION"` would false-positive on the first line.
  `xcodeLanguageMode` matches the trimmed line's exact key instead.
- `swift --version` prints `Apple Swift version 6.3 (swiftlang-6.3.0.123.5 ...)` on **stdout** and
  `swift-driver version: 1.148.6` on **stderr** — `compilerVersion` searches both streams anyway,
  so it doesn't depend on that split holding across every toolchain distribution.

**Risk heuristic, scoped and documented, not silently approximated.** By the time a project
compiles, every cross-isolation call is already `await`-ed or uses an explicit unsafe escape hatch
(`@unchecked Sendable`/`nonisolated(unsafe)`); detecting the escape-hatch case needs new
SwiftSyntax attribute extraction that doesn't exist yet (a documented v0.2+ gap). What this phase
actually ships (`AnalysisReportBuilder.riskLevel`) is a structural heuristic over already-resolved
`IsolationKind` pairs only: `high` for a `.nonisolated` caller reaching `.actor`/`.globalActor`
state, `low` when both sides are already actor-protected, `medium` for everything else
cross-isolation (e.g. either side `.unspecified`).

## `IndexStoreDB` has no forward file-enumeration API (plan pivot)

The plan assumed `StalenessOrchestration`'s file list could come from the index store itself
("every file this store covers"). Verified against the real checked-out `indexstore-db` source
(`.build/checkouts/indexstore-db`) before building on that assumption: only reverse lookups exist
(`forEachMainFileContainingFile`, `unitNamesContainingFile(path:)`), both requiring an input path
already known — no forward "list every file" API in the Swift-facing surface. Pivoted to recursive
`.swift` enumeration under the project directory instead (`StalenessOrchestration.swiftFiles`),
skipping `.build`/`.swiftpm`/`.git`/`DerivedData`. This is safe-by-default (over-inclusive — a
stray file outside any indexed target still gets hashed and can trigger a staleness prompt, but
never under-inclusive) and, as a side effect, unifies the "which files do we analyze" question
across SPM and Xcode containers alike — Xcode has no `.pbxproj`-derived source list this tool
parses (deliberately, per the architecture doc's own warning against hand-parsing project files),
so the same recursive walk serves as the extraction input list for both container types, not just
the staleness hash list.

`FileAnalyzer` was extended (not replaced) to call `DeclarationExtractor.extractWithContext`
instead of the older `extract`, and to return `protocolGlobalActorNames` alongside its existing
`declarations`/`contentHash` fields — so `run()` gets everything `DeclarationLinker` needs
(`ExtractionResult`) from the *same* single read per file that also produces the staleness hash,
honoring the single-read discipline from Phase 2.

## Two real bugs found by running the tool against a real project, not by unit tests alone

Both were caught during the plan's own final verification step — running the built CLI against
this project's own codebase — not during unit testing, which had already gone green.

**Prompt message lied about why it was prompting.** `decideIndexAction` deliberately routes two
different situations to the same `.promptUser` decision: a store that's genuinely `.missing`, and
a store that's `.found` but has `.noManifest` (this tool never fingerprinted it, so it can't vouch
for it — architecture spec section 2.6's own reasoning). The first implementation's prompt always
printed "Index store not found," regardless of which case triggered it. Running the CLI against
this project's own `Package.swift` for the first time hit exactly the second case — a real
`.build/debug/index/store` already existed from an earlier plain `swift build` — and the CLI
confidently claimed no index store existed at all. Fixed by branching the prompt text (and the
`[1]` option's meaning: "provide a path" vs. "use it anyway") on which `IndexStoreDiscoveryResult`
actually triggered the prompt.

**Status/prompt messages were corrupting `--output json` on stdout.** The `.rebuildThenProceed`
status line ("Building project to generate a fresh index store...") and the interactive prompt
text were written with plain `print(...)`, landing on stdout ahead of the actual analysis result —
harmless for `mermaid`/`dot` output read by a human, but silently corrupting `--output json` for
any caller piping stdout into a JSON parser (exactly what the capstone test below does). Fixed by
routing every status/prompt line through a dedicated `eprint` helper to stderr; only
`writeOutput`'s final `print(text)` — the actual result — writes to stdout. Also switched
`JSONEncoder.outputFormatting` to include `.withoutEscapingSlashes` (Foundation's default escapes
every `/` in a JSON string as `\/`, which is valid JSON but needlessly noisy for a
machine-readable, human-inspectable contract).

## A third real bug, found on an independent real project after merge

Per [[feedback_verify_against_independent_real_world_cases]]'s lesson (re-testing the same
environment can produce a second wrong "correction" rather than a real fix), this phase's own
merged validation had only exercised the Xcode rebuild path indirectly — `Project Iris` already had a
populated `DerivedData` index store, so `resolveIndexStoreURL`'s `.promptUser` → "use it anyway"
branch was taken, never the real `build()` invocation for an `.xcodeproj`/`.xcworkspace` container.
Running against `SQLumen` (no existing `DerivedData/.../Index.noindex/DataStore`, so `--auto-build`
genuinely had to rebuild) hit it for the first time: `xcodebuild -indexStoreEnable YES build` fails
outright — `xcodebuild: error: invalid option '-indexStoreEnable'` (confirmed against a real
project, Xcode 26.4.0) — there is no such flag. `xcodebuild -showBuildSettings` output for the same
project shows the real, working mechanism: `COMPILER_INDEX_STORE_ENABLE` is a build *setting*
(value `Default` by default), passed the same way any other setting override is — a bare
`KEY=VALUE` argument, not a `-flag`. Fixed by building the argument list as
`-scheme <name> [-project|-workspace <path>] COMPILER_INDEX_STORE_ENABLE=YES build`. This is the
same class of bug Phase 0 found for `swift build --index-store-path` (a plausible-sounding flag
from the architecture doc that doesn't exist on the real, current toolchain) — the Xcode side of
the same rebuild mechanism just hadn't been exercised for real yet.

## Real-world validation

Ran the built CLI against `swift-isolation-map`'s own codebase (61 real `.swift` files):
`swift-isolation-map Package.swift --scheme swift-isolation-map --output json` produced a real
report — 546 types, 1236 linked declarations, 267 call-graph edges, 0 cross-actor boundaries (this
project doesn't use `actor` types itself, so that's the correct answer, not a bug), exit code 0.
`--force-reindex` (the real rebuild path, `swift build -Xswiftc -index-store-path -Xswiftc ...`)
completed in ~23s and produced the same coherent result afterward.

Ran against two independent, unrelated real projects afterward, both under Swift 5 language mode
(so `Swift5RuleSet` applied regardless of the Swift 6.3 toolchain compiling them):
- **Project Iris** (`docs/reference-project-corpora.md`; CocoaPods-based, 2209 `.swift` files
  including dependency sources): 46438 nodes, 1021 cross-isolation edges, **164 high-risk**
  (overwhelmingly `nonisolated` code reaching `@MainActor` state), 4 real actors, 133 `@MainActor`
  types, using the project's existing `DerivedData` index store (accepted via the `.promptUser`
  "use it anyway" path, no rebuild needed).
- **`~/SQLumen`**: 1457 nodes, 216 cross-isolation edges, **38 high-risk**, 8 real actors (including
  a `PostgreSQLDriver` actor), 19 `@MainActor` types — via a genuine `--auto-build` rebuild (the
  path that surfaced the `COMPILER_INDEX_STORE_ENABLE` bug above), confirming the fix end to end.

## Capstone golden-fixture test

`Tests/Fixtures/simple-actor/` is a real, minimal SPM package (`actor Counter` with one instance
method, a `nonisolated` free function that `await`s a call into it) — deliberately single-file,
since this test is about CLI wiring, not linking correctness (Phase 3's `cross-file-witness`
fixture already covers that). `CapstoneCLITests` invokes the *actual built binary* as a real
subprocess (not internal Swift calls) with `--force-reindex --output json`, decodes the real
stdout as `AnalysisReport`, and asserts on it: exactly one `high`-risk edge
(`nonisolated` → `actor(Counter)`), exit code 1 (the documented exit-code contract — section
3.5.3: exit 1 iff any high-risk boundary exists), and that a staleness manifest was written
afterward. This is the first test in the project that exercises every phase composed together for
real, through the same binary a real user would run.
