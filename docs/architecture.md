# swift-isolation-map — Project Architecture Specification

## What's changed since this was written

This is the original, pre-implementation specification — kept as-written, as the record of
original intent (see `docs/README.md`'s own note on this). Real implementation has since
diverged from or gone beyond it in six places worth knowing before treating any single section
below as current:

1. **§2.4's `IsolationInferenceEngine` model is missing its largest subsystem.** The engine
   itself still only ever sees `attributes` (SwiftSyntax) + `callGraph` (IndexStoreDB), exactly as
   specified — but a call reaching into a *compiled* dependency (a CocoaPod, an XCFramework, an
   SDK framework) needs a fact neither source has. An external-isolation oracle
   (`ExternalIsolationBackfill`, `BulkSymbolGraphExtractor`, live `sourcekitd` queries via
   `SourceKitDIntegration`) backfills that fact *before* the engine runs, so §2.4's own "engine
   untouched" invariant holds — but the oracle itself, arguably the most heavily-researched part
   of the whole project, isn't mentioned anywhere in this document. See `docs/README.md`'s oracle
   diagram and `docs/research/` for the real design history.
2. **§3.5.2's JSON schema is missing a field**: real output also carries `isUnknown` on every
   edge (set when the oracle couldn't resolve one side — `risk` is still present but must not be
   read as confirmed in that case). See the root `README.md`'s "Understanding the output" section
   for a real, captured example.
3. **§5 Distribution is entirely aspirational still** — no Homebrew formula, no SPM build-tool
   plugin, no distribution automation exists yet. Treat this section as an unstarted plan, not a
   settled decision.
4. **§6 Roadmap predates Priority 3 entirely** — the compiled-dependency oracle (correctness,
   performance, Gap A/B linker fixes) and the query-ordering optimization (~33% faster, zero
   semantic change) aren't reflected here. See `docs/README.md`'s status table for what's actually
   shipped.
5. **§2.8's CI job is no longer a proposal** — `.github/workflows/swift-version-watch.yml` exists,
   is active, and (after a real permission-scope bug found and fixed) has completed successfully.
6. **§4's "regression baseline against real open-source code" isn't an automated nightly job** —
   in practice this has been manual, ad-hoc validation against two real projects
   (`docs/reference-project-corpora.md`) at the end of each work session, not a scheduled CI run.
7. **§2.2's `IndexStoreDB` is no longer the index reader item 1 above's `callGraph` actually comes
   from.** A real, reproduced `IndexStoreDB` gap (`symbolOccurrences(inFilePath:)` silently
   dropping occurrences for a file compiled into more than one target — filed upstream as
   [swiftlang/indexstore-db#292](https://github.com/swiftlang/indexstore-db/issues/292)) motivated
   bypassing `IndexStoreDB`'s async/LMDB layer entirely in favor of `libIndexStore`'s raw C API,
   read directly (`RawIndexStoreClient`, `Sources/CIndexStoreRaw/` + `Sources/IndexStoreIntegration/
   RawIndexStoreClient.swift`) — this is the default index reader today, not the `IndexStoreDB`
   package this section's own sample code shows. See `docs/task-raw-indexstore-spike.md` for the
   full decision record. The `IndexStoreDB` package dependency itself is still present (kept for
   `IndexStoreClient`, retained specifically as an A/B correctness comparison against
   `RawIndexStoreClient` in the test suite), so don't read its continued presence in `Package.swift`
   as evidence it's still the production path.

## ⚠️ IMPORTANT: This is a reputation-sensitive tool

This is an open-source CLI tool for the Swift developer community. One principle should govern **every** implementation decision: **a tool that gives an incorrect concurrency-safety result is worse than no tool at all.**

A false positive or false negative isolation/data-race report destroys trust immediately and, most likely, irreversibly — a developer who gets a wrong graph once will stop using the tool and quite possibly write about it publicly. This is not a typical side project where "good enough" is acceptable. Elevated standards apply here:

- **Quality and reliability outweigh development speed.** It's better not to ship a feature than to ship one that produces inaccurate results.
- **Honesty about the tool's limitations is mandatory.** If the tool is uncertain (unknown Swift version, unsupported code pattern, stale index store), it must say so explicitly rather than staying silent or guessing.
- **Community usefulness is the primary goal**, not a portfolio piece or monetization vehicle. This should be reflected in feature prioritization: real developer pain (Swift 6 strict concurrency migration) comes first, not whatever is technically more interesting to build.
- **Testing is not a formality — it's the primary trust mechanism.** Every isolation-inference rule must be covered by an explicit test referencing the exact compiler behavior it verifies.

Any architectural decision made during implementation should be checked against this principle.

---

## 1. Concept and motivation

**The problem:** Swift 6 made strict concurrency checking a mandatory part of compilation (a hard error, not just a warning as before). Developers are migrating legacy codebases en masse and running into opaque compiler errors (`Sending value risks data race`) with no clear explanation of "why," and no tools that give an architectural overview of the whole project.

**Existing solutions and their limits:**
- Xcode Instruments visualizes actor hops, but only as a **runtime** trace of one specific run — it doesn't cover the whole codebase statically and requires exercising the relevant code path first.
- The compiler gives bare errors with no architectural context.
- Educational content (courses, articles) is abundant; tooling is not.

**The empty niche:** static, architecture-level analysis of the whole project — an isolation graph, an explanation of "why" a given boundary is risky, CI integration to track migration debt over time.

**Format:** not a course, not a learning app — a standalone open-source developer tool (a linter/visualizer for actor isolation and data races).

**Differentiation from Xcode Instruments (5 points):**
1. Static analysis of the whole project vs. a runtime trace of one run
2. An architectural map (the full isolation-domain graph) vs. a single-run timeline
3. Explaining "why" an error arises in architectural context, not just "what happened"
4. CI-suitability — can be embedded as a pipeline gate, which Instruments cannot do
5. Migration debt map — a prioritized map of migration debt, trackable over time via git history

---

## 1.5 The isolation rule system is the product

**This section exists because of a structural mistake in how this document was originally organized, and it's worth naming explicitly.** The tool was designed bottom-up — starting from mechanics (how to get an AST, how to get a call graph, how to link them via USR) and only later arriving at what that mechanics *serves*. As a result, the isolation rule system — the actual logic that decides what isolation a piece of code has — ended up documented as a configuration detail (a `ruleSet` parameter passed into `IsolationInferenceEngine`, see section 2.8) rather than as the center of the entire project.

**It should have been front and center from the start.** IndexStoreDB and SwiftSyntax are just how raw data gets fetched. The rule system — the logic that turns that raw data into a correct isolation judgment — *is the product*. Every other component (CLI ergonomics, discovery, staleness detection, distribution, governance) can be implemented flawlessly, and the tool still fails completely if the rules themselves are wrong or out of date. This is not one bug category among many — per the reputation-sensitivity principle in the introduction, it's the single class of error that destroys trust immediately and irreversibly.

**Practical consequence for how this project is built:** the rule system and its test suite should be prioritized *earlier* in implementation than CLI plumbing (discovery, staleness, auto-build), not alongside or after it. It's possible to develop and validate rule logic against hardcoded/fixture input before the discovery and staleness machinery exists — but it is not acceptable to ship a working CLI around unreliable rules and call it an MVP. See the revised roadmap in section 6.

### 1.5.1 Sources of truth for isolation rules, in order of authority

Given how central this is, the sourcing process must be explicit and prioritized, not ad hoc:

1. **Swift Evolution proposals — the primary source of intent.** Every change to isolation semantics goes through the formal `swift-evolution` process (the same repository already tracked for version-monitoring purposes — see section 2.8). Relevant proposals shaping the current model include: SE-0306 (Actors — the base actor isolation model), SE-0316 (Global actors), SE-0338/related clarifications on main actor semantics, SE-0401 (removes actor isolation inference caused by property wrappers), SE-0420 (inheritance of actor isolation), SE-0466 (control default actor isolation — the Swift 6.2 default-MainActor behavior), SE-0478 (file-level defaults — accepted but confirmed empirically not yet shipped as of the local Swift 6.3 toolchain). **Limitation:** proposals are written for reviewers deciding "accept or reject," not as a formal spec for a rule-parser implementer — edge cases are often scattered across "Detailed design" and "Alternatives considered" prose, and nuances are easy to miss.

2. **The Swift compiler's own source code — the ground truth when a proposal is ambiguous.** When a proposal is unclear (this happens), actual behavior is determined by the type-checker code in `apple/swift`, notably `lib/Sema/TypeCheckConcurrency.cpp` and related files. If documentation and actual compiler behavior disagree, compiler behavior wins for this tool's purposes — otherwise the graph would be technically "per spec" but would not match what `swiftc` actually reports.

3. **The official Swift 6 Concurrency Migration Guide (swift.org/migration)** — a reworked, practitioner-facing explanation of the rules, not raw proposals. Good source for writing clear, user-facing explanation strings (the "why this is risky" text from the output contract in section 3.5.1), but not authoritative for the inference logic itself — it simplifies for readability.

4. **Official release notes for specific Swift/Xcode versions** — often explicitly state version boundaries ("starting in Swift X.Y, default isolation behavior changes to..."), which gives a clean `SwiftVersionRange` cutoff.

5. **Empirical testing against the real compiler — mandatory, not optional.** The most reliable method in practice: write small test Swift files targeting a specific language mode (`-swift-version 6`, flags like `-default-isolation MainActor`), compile them with the real `swiftc`, observe the diagnostics, and use that to write golden-file fixtures (already part of the testing strategy in section 4). This closes the real risk: documentation can lag or be imprecise, but the actual compiler cannot. Golden-file fixtures should ideally be generated or validated against real `swiftc` behavior, not just against what a proposal document says.

**Practical priority order:** Evolution proposals establish the *intent* of a rule → compiler source resolves ambiguity → real compilation of test snippets is the final validation before a rule is locked into a specific `IsolationRuleSet`. Documentation and release notes are a supporting layer for user-facing explanation text, not for the inference logic itself.

### 2.1 Analysis approach — hybrid

**Decision:** IndexStoreDB for the semantic call graph + SwiftSyntax for isolation attributes.

**Rationale:**
- SwiftSyntax without type semantics cannot reliably resolve isolation through protocols/generics/type-erasure — only explicit, lexical attributes (`actor`, `@MainActor`, `nonisolated`).
- IndexStoreDB provides a resolved semantic call graph (including calls through protocol witness tables, resolved by the compiler at indexing time), but does **not** directly expose isolation information — that's type-checker-level semantics, not indexing.
- Therefore: there is no clean path to ask IndexStoreDB directly about isolation — a hybrid is required.

**Division of responsibility:**
- **IndexStoreDB** → semantic call graph (who calls whom, robust across abstractions)
- **SwiftSyntax** → isolation attributes on declarations (lexically reliable — an attribute is either written or it isn't)
- **Custom inference layer** → combines both sources and resolves final isolation for each symbol

### 2.2 IndexStoreDB — API details

```swift
import IndexStoreDB

let indexStoreDB = try IndexStoreDB(
    storePath: indexStorePath,
    databasePath: cachedDatabasePath,   // cache across CLI runs!
    library: try IndexStoreLibrary(dylibPath: toolchainLibIndexStorePath)
)
```

**Important:** `databasePath` is IndexStoreDB's internal database, built on top of the compiler's binary unit files the first time it's accessed. It must be cached between CLI runs (e.g. under `.build/index-db`), otherwise every run rebuilds it from scratch — slow on large projects.

**Enumerating symbols:**
```swift
indexStoreDB.forEachCanonicalSymbolOccurrence(
    containing: "", anchorStart: true, anchorEnd: false,
    subsequence: true, ignoreCase: true
) { occurrence in
    // occurrence.symbol.kind: .class, .struct, .protocol, .instanceMethod, ...
    // occurrence.location: file + line + column
    return true
}
```

**Call graph:**
```swift
indexStoreDB.occurrences(ofUSR: methodUSR, roles: [.call]) -> [SymbolOccurrence]
```
Returns all real call sites for a given method (by USR), semantically resolved, including calls through a protocol.

```swift
struct CallGraphEdge {
    let callerUSR: String
    let calleeUSR: String
    let location: SymbolLocation
}
```
Building the graph: for each function/method declaration → `occurrences(ofUSR:roles:[.call])` → for each occurrence, find the containing symbol (via `.childOf` relations, walking up) → that's the caller.

### 2.3 USR as the linking key between IndexStoreDB and SwiftSyntax

SwiftSyntax has no concept of USR (that's a SourceKit/compiler-level concept). The link is established via **location matching**: SwiftSyntax gives the exact position of a declaration (line/column via `SourceLocationConverter`), and we look up the IndexStoreDB symbol with `.definition` role in the same file at the same line (via `symbols(inFilePath:)`), matching by location rather than name (names can be non-unique under overloading).

```swift
struct IsolationAttribute {
    let usr: String
    let kind: IsolationKind   // .actor, .globalActor(name), .nonisolated, .unspecified
    let location: SymbolLocation
}
```

### 2.4 IsolationInferenceEngine

```swift
final class IsolationInferenceEngine {
    let attributes: [String: IsolationAttribute]   // usr -> attribute (from SwiftSyntax)
    let callGraph: [CallGraphEdge]                  // from IndexStoreDB
    let ruleSet: IsolationRuleSet                   // versioned rule set (see 2.8)

    func resolveIsolation(for usr: String) -> IsolationKind {
        // Priority:
        // 1. Explicit attribute on the declaration
        // 2. Inheritance from the containing type
        // 3. Default actor isolation (depends on Swift version / rule set)
        // 4. Protocol conformance isolation
    }

    func crossIsolationEdges() -> [CallGraphEdge] {
        callGraph.filter { edge in
            resolveIsolation(for: edge.callerUSR) != resolveIsolation(for: edge.calleeUSR)
        }
    }
}
```

**Critical:** rules 2-4 must precisely mirror Swift's documented compiler semantics (containing type isolation, default actor isolation, protocol inheritance) — this is a separate, heavily tested module. Any mistake here produces a false data-race report, which directly damages the tool's reputation.

### 2.5 Project and schemes — resolution pipeline

**Container types:**
```swift
enum ProjectContainer {
    case xcodeproj(URL)
    case xcworkspace(URL)
    case swiftPackage(URL)   // Package.swift
}
```

**SchemeResolver (shared protocol for Xcode and SPM):**
```swift
protocol SchemeResolver {
    func discoverSchemes(in container: ProjectContainer) throws -> [XcodeScheme]
    func resolve(named: String, in container: ProjectContainer) throws -> XcodeScheme
}

protocol SchemeLike {
    var name: String { get }
    var buildTargets: [BuildTarget] { get }
}

struct XcodeScheme: SchemeLike {
    let name: String
    let path: URL
    let isShared: Bool
    let buildTargets: [BuildTarget]
}

struct SPMResolvedScheme: SchemeLike {
    let name: String
    let buildTargets: [BuildTarget]
    let sourcePaths: [String]
}

struct BuildTarget {
    let targetName: String
    let projectPath: URL
}
```

**Xcode branch (`.xcodeproj` / `.xcworkspace`):**
- Schemes physically live as XML: `MyProject.xcodeproj/xcshareddata/xcschemes/*.xcscheme` (shared, committed to the repo) — only these are used, not user-specific schemes under `~/Library/Developer/Xcode/UserData/`.
- For `.xcworkspace` — first parse `contents.xcworkspacedata` (XML with a list of `<FileRef location="...">`), recursively find nested `.xcodeproj` files, then read their schemes.
- From `.xcscheme` we extract: `BuildAction` → the list of targets actually included in the build (needed for analysis scope); `LaunchAction`/`TestAction` → build configuration (Debug/Release) for the `xcodebuild` invocation.

**SPM branch (`Package.swift`):**
- **Do not manually parse `Package.swift` as Swift code** (it can contain arbitrary computation/conditional logic — a nightmare to parse). Instead use `swift package describe --type json`, which executes the manifest and returns a ready-made JSON.
```swift
struct SPMPackageDescription: Decodable {
    let name: String
    let targets: [SPMTarget]
    let products: [SPMProduct]
}
struct SPMTarget: Decodable {
    let name: String
    let type: String   // "executable" | "library" | "test" | ...
    let path: String
    let sources: [String]
}
struct SPMProduct: Decodable {
    let name: String
    let type: ProductType
    let targets: [String]
}
```
- SPM has no schemes — `--scheme` is matched first against **products**, then against **targets** as a fallback.
- On no match: show available products/targets as a list.

**`.xcscheme` XML parsing — technology choice:**
- Chosen: **`XMLParser`** (Foundation, zero-dependency).
- Rejected: `SWXMLHash` (appears unmaintained on GitHub) and `XMLDocument`/DOM-style API (unreliable on Linux under `swift-corelibs-foundation`, which matters for a future Linux-based GitHub Action).
- `.xcscheme` is a simple, shallow, predictable XML with a fixed Apple-defined structure, so an external dependency for navigation convenience isn't justified.

### 2.6 Index store discovery

- **SPM:** the path is predictable and local — `.build/index-store` relative to `Package.swift`. This simplifies auto-detection (no fuzzy search across system directories needed): if the store is missing, we know exactly which command builds it (`swift build --index-store-path .build/index-store`).
- **Xcode:** the path is less predictable — usually under `~/Library/Developer/Xcode/DerivedData/<Project>-<hash>/Index.noindex/DataStore`. Requires search/matching by project or scheme name.

**CLI behavior when the store is missing:**
- Without flags — interactive prompt:
  ```
  Index store not found.
  [1] Provide a path manually
  [2] Build the project now
  [q] Cancel
  ```
- `--index-store-path <path>` — explicit path, auto-detection is skipped.
- `--auto-build` — the CLI builds the project itself (`xcodebuild -indexStoreEnable YES` / `swift build --index-store-path ...`) without an interactive prompt. Intended for CI/scripts.
- `--force-reindex` — forces a rebuild, ignoring any existing (even fresh) index store.

### 2.7 Staleness detection (outdated index store)

**The problem:** if the user edited code (introducing an isolation bug) and runs the tool without rebuilding, the index store will reflect the old, incorrect state. Silently using stale data is unacceptable — it creates a false sense of safety ("the tool checked, all clear," even though the old version of the code was checked).

**Detection method:** **raw byte content-hash** of each `.swift` file (NOT an AST-normalized hash — see below for why).

**Why not an AST-normalized hash:**
- An AST-normalization approach was initially considered (discarding whitespace/comments by stripping `leadingTrivia`/`trailingTrivia` from tokens), so that stylistic edits wouldn't count as "changes."
- Important technical nuance: SwiftSyntax is a full-fidelity tree — it **deliberately** preserves all trivia (whitespace, line breaks, comments) as part of every token, because it's designed for lossless round-trip editing (this is what `swift-format` relies on). This means `tree.description` or a raw serialization of the tree **includes** trivia, and normalization requires an explicit separate step (walking `tokens(viewMode: .sourceAccurate)` and concatenating only `token.text`, without trivia).
- **Final decision:** drop AST-based normalization as unnecessarily complex. Go with **raw byte hashing** — simpler, more reliable, less risk of getting the normalizer logic wrong. Whitespace/comment edits are treated as breaking the correspondence between the index store and the sources on disk — an acceptable tradeoff (extra rebuilds aren't a safety problem, unlike a missed staleness case).
- **TODO for v0.3:** revisit the content-hashing approach (normalized AST vs. raw vs. alternatives) — left as an open question for a future iteration, in case raw hashing turns out too noisy in practice.

**CLI behavior on staleness:**
- If the store is stale — **warning + hard stop**. There is no "continue anyway" option — working with known-stale data is not allowed.
- If `--auto-build` or `--force-reindex` is passed — a message is printed stating the store will be rebuilt, and work continues after the rebuild.

**Pipeline (order of operations):**
1. CLI starts, resolves the project/scheme.
2. **A single pass** over all `.swift` files: simultaneously parse the SwiftSyntax AST (for isolation attributes) and compute the raw content-hash (from the same bytes read) — no need to read the file twice.
3. Compare the hash manifest against the last known indexed state.
4. If stale → warning + stop (or rebuild if `--auto-build`/`--force-reindex`).
5. Important: if a rebuild is triggered, **sources are not touched**, so the AST already parsed in step 2 remains valid and does **not** need reparsing. Only the hash manifest needs updating after the rebuild.
6. If fresh (or after rebuild) → fetch the call graph from IndexStoreDB.
7. `IsolationInferenceEngine` combines the AST attributes (step 2) with the call graph (step 6).

**Hash manifest storage:** a separate file next to the index store (e.g. `.build/index-store-manifest.json` for SPM), format `{filePath: hash}`, rewritten after every successful (re)build.

### 2.8 Resilience to Swift language updates

**Note:** this section covers the *mechanics* of versioning and monitoring. For where the rules themselves come from and why the rule system is the central piece of this entire project, see section 1.5.

**The problem:** concurrency isolation rules change between Swift versions (e.g. default actor isolation arrived in Swift 6.2). Hardcoded logic will eventually produce incorrect results for newer language versions.

**Solution — versioned rules:**
```swift
protocol IsolationRuleSet {
    var swiftVersion: SwiftVersionRange { get }
    func resolveDefaultIsolation(for context: TypeContext) -> IsolationKind
}

struct Swift5RuleSet: IsolationRuleSet { ... }    // no default MainActor
struct Swift6RuleSet: IsolationRuleSet { ... }     // opt-in strict checking
struct Swift62RuleSet: IsolationRuleSet { ... }    // default MainActor isolation
```

- The Swift language mode/version **must** be extracted from `swift-tools-version` (SPM) or build settings (Xcode) and passed into `IsolationInferenceEngine` at initialization — the engine must not run without knowing the target version.
- Golden-file fixtures are **pinned to a specific rule set** — this guards against regressions: adding a new rule set must not break old fixtures running against their original rule set.
- **If a project's Swift version has no matching rule set yet** (a new minor language version not yet supported) — the CLI **must** explicitly warn the user rather than silently applying the nearest known rule set:
  ```
  ⚠️ Swift 6.4 language mode detected, but support goes up to 6.3.
  Results may be inaccurate for new isolation rules introduced in 6.4.
  ```

**Process for tracking new language versions (to avoid falling behind):**
- **GitHub watch on releases** for two repositories: `apple/swift` and `apple/swift-evolution` (not the full activity feed — just releases/PRs labeled Concurrency).
- **Scheduled GitHub Actions CI job** (weekly, cron) checks via the GitHub API for a new Swift release and **automatically opens an issue** in the tool's repository if one is found — this is not left to memory/discipline, it's fully automated.
- The same mechanism (Search API filtered by the `Concurrency` label) can also be used to monitor swift-evolution proposals, not just releases.
- **WWDC** as a forced checkpoint: right after WWDC, a fixed task to review Swift concurrency sessions/evolution roadmap through the lens of this tool.
- **Community bug reports** — a safety net in case something slips through, but NOT the primary detection mechanism (by the time a user complains, they've already gotten an inaccurate result).

**Scheduled CI job implementation on GitHub Actions (confirmed — natively implementable):**
```yaml
name: Check Swift Version Updates
on:
  schedule:
    - cron: '0 9 * * 1'   # every Monday
  workflow_dispatch:

jobs:
  check-swift-release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Get latest Swift release
        id: latest
        run: |
          LATEST=$(curl -s https://api.github.com/repos/apple/swift/releases/latest | jq -r '.tag_name')
          echo "version=$LATEST" >> "$GITHUB_OUTPUT"
      - name: Compare with known versions
        id: compare
        run: |
          KNOWN=$(cat SUPPORTED_SWIFT_VERSIONS.md | tail -1)
          if [ "${{ steps.latest.outputs.version }}" != "$KNOWN" ]; then
            echo "new_version=true" >> "$GITHUB_OUTPUT"
          fi
      - name: Open issue if new version found
        if: steps.compare.outputs.new_version == 'true'
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.create({
              owner: context.repo.owner,
              repo: context.repo.repo,
              title: `New Swift release detected: ${{ steps.latest.outputs.version }}`,
              body: 'Needs RuleSet review for isolation semantics changes.',
              labels: ['swift-version-watch']
            });
```
Notes: `GITHUB_TOKEN` is provided automatically (no secrets needed); cron timing isn't guaranteed to be exact (fine for a weekly check); deduplication is needed — check whether an issue with the same label is already open before creating a new one.

---

## 3. CLI — command structure

```
swift-isolation-map <path-to-project> [OPTIONS]

ARGUMENTS:
  <path-to-project>          Path to a .xcodeproj, .xcworkspace, or Package.swift

OPTIONS:
  --scheme <name>              REQUIRED. Build scheme (Xcode) or
                                product/target (SPM).

  --index-store-path <path>    Explicit path to the index store. If provided,
                                auto-detection is skipped.

  --auto-build                 If the index store is missing or stale, the CLI
                                builds the project itself without an interactive
                                prompt. Prints a message about the rebuild.

  --force-reindex              Forces a rebuild, ignoring any existing (even
                                fresh) index store.

  --output <format>             Output format: mermaid | dot | json
                                (default: mermaid)

  --out-file <path>             Where to write the result (default: stdout)

  --verbose                     Verbose logging: what was searched, where the
                                index store was found, how many types were
                                processed.
```

**`--scheme` is required** for projects with multiple schemes (no auto-detect-first-found fallback).

**Behavior when the index store is missing/stale (interactive mode, no flags):**
```
$ swift-isolation-map ./MyProject.xcodeproj --scheme MyApp

⚠️  Index store is stale: 3 files changed since the last indexing:
    - Sources/UserSession.swift
    - Sources/OrderProcessor.swift
    - Sources/Networking.swift

What would you like to do?
  [1] Rebuild the project now
  [2] Continue with stale data (UNAVAILABLE — hard stop)
  [q] Cancel
```
Important: the "continue with stale data" option is **not offered** — this was explicitly decided as unacceptable behavior. On detecting staleness without `--auto-build`/`--force-reindex`, the CLI **must** stop.

**Scheme validation:** on a name mismatch — show the list of available schemes/products/targets with a fuzzy "did you mean" suggestion (Levenshtein-based).

**Planned `diff` subcommand (v0.2, NOT in v0.1):**
```
swift-isolation-map diff <rev1> <rev2>
```
Compares the isolation graph between two git revisions.

---

## 3.5 Output contract

This is a formal, standalone contract — the tool must work both as a human-readable report and as a machine-readable API for CI/other tools. These are two different consumers with different needs, not the same data with a different serialization bolted on.

### 3.5.1 Human-readable output

Three layers of detail, because a developer opens the output in different contexts:

**Summary (always shown first, even in mermaid/dot mode):**
```
Isolation Analysis Summary
──────────────────────────
Types analyzed:        47
Actors:                3
@MainActor types:      12
Unspecified isolation:  8
Cross-actor boundaries: 5  ⚠️  2 flagged as high-risk
```

**Graph (Mermaid/DOT):** a visual structure, but with **risk annotations**, not just plain nodes/edges. Edge color/style must distinguish a normal `await` transition from a potentially unsafe synchronous access through `@unchecked Sendable`. Without this distinction, the graph turns into an unreadable wall on a medium-sized project.

**Explanations attached to each flagged edge:** not just "here's a boundary," but a short, human-readable explanation, e.g.:
> *"UserSession (actor) called synchronously from OrderProcessor (nonisolated) — potential data race on `currentUser`"*

This is a direct continuation of the tool's core value proposition: explaining "why," not just "where."

### 3.5.2 Machine-readable output (JSON)

A stable, versioned JSON contract — required because consumers differ from the human case: GitHub Actions, the future `diff` subcommand (v0.2), third-party linters, dashboards.

```json
{
  "schemaVersion": "1.0",
  "toolVersion": "0.1.0",
  "swiftVersion": "6.2",
  "ruleSetUsed": "Swift62RuleSet",
  "summary": {
    "typesAnalyzed": 47,
    "actors": 3,
    "mainActorTypes": 12,
    "unspecifiedIsolation": 8,
    "crossActorBoundaries": 5,
    "highRiskBoundaries": 2
  },
  "nodes": [
    { "usr": "s:4Demo11UserSessionC", "name": "UserSession", "isolation": "actor", "location": {"file": "Sources/UserSession.swift", "line": 12} }
  ],
  "edges": [
    {
      "callerUSR": "s:...", "calleeUSR": "s:...",
      "callerIsolation": "nonisolated", "calleeIsolation": "actor(UserSession)",
      "risk": "high",
      "explanation": "Synchronous access to actor-isolated state without await",
      "location": {"file": "Sources/OrderProcessor.swift", "line": 34}
    }
  ]
}
```

**Key architectural requirements for this contract:**

- **`schemaVersion` is mandatory** and versioned independently from the tool's own version (`toolVersion`). Third-party tools (e.g. the v0.2 GitHub Action, the future `diff` subcommand) must parse against `schemaVersion`, not guess based on `toolVersion` — these are different lifecycles: analysis logic can be updated more often than the output format.
- **USR as the stable node identifier** — this was already baked into the architecture (section 2.3), and it pays off here: USR (not the type name, which can be non-unique) must be the key an external tool (`diff` in v0.2) uses to match the same symbol across two runs/revisions.
- **A mandatory `risk` field on every edge** (not just a boolean `crossActor: true/false`) — needs graduated levels (`low`/`medium`/`high`), because not every cross-actor boundary is equally dangerous (an `await` transition through a proxy is not the same as synchronous access to `@unchecked Sendable`). Without graduation, a CI gate (the v0.2 GitHub Action) can't decide what should block a PR and what shouldn't.

### 3.5.3 Exit codes

Since the tool is meant to be CI-gate-capable, it needs predictable exit codes, not just text/JSON on stdout:

```
0  — analysis completed, no high-risk boundaries found
1  — analysis completed, high-risk boundaries found (CI should fail the build)
2  — execution error (index store not found, staleness hard-stop, invalid scheme, etc.)
```

This is standard Unix convention, and it's how CI decides whether to break the pipeline without needing to parse JSON just to determine success/failure.

### 3.5.4 JSON schema backward compatibility — a governance decision, not just a technical one

Given the reputation and community-tool framing, the policy must be fixed in advance: **breaking changes to the JSON schema require a major bump to `schemaVersion` plus a CHANGELOG entry**, because third-party integrations (like the GitHub Action) would silently break if the format changed quietly between minor tool releases.

---

## 4. Testing

**Principle:** a mistake here is not a bug — it's a direct loss of trust in the tool. Testing is the primary mechanism for earning and keeping that trust.

**Test pyramid (bottom to top, by speed/run frequency):**

1. **Unit tests for inference rules** (run on every commit, seconds)
   - One Swift concurrency rule = one test, with an explicit reference to the compiler behavior it verifies.
   - Required coverage: explicit attribute priority, containing type inheritance, default actor isolation (per version), protocol conformance isolation, extension isolation override, `@preconcurrency`, nested types.
   - Maintain a checklist table of isolation rules (from swift-evolution proposals) and track line-by-line test coverage against it.

2. **CLI logic with mocked side-effects** (every commit, seconds)
   - Extract protocols for side-effects: `ProcessRunning`, `FileSystemQuerying`.
   - Test argument validation, auto-build/ask-user branching, staleness handling — without an actual `xcodebuild` invocation.

3. **Golden-file / snapshot tests on fixtures** (every PR, minutes — requires real compilation)
   ```
   Tests/Fixtures/
     simple-actor/
       Package.swift
       Sources/Foo.swift
       expected-graph.json
     mainactor-protocol/
       ...
     legacy-unchecked-sendable/
       ...
   ```
   - Process: actually build (`swift build --index-store-path`) → run the analyzer → compare against `expected-graph.json`.
   - Must include fixtures for hard cases: generic constraints with Sendable, calls through protocol witnesses (the case where plain SwiftSyntax would get it wrong), cross-module boundaries.
   - Fixtures are pinned to a specific rule set (Swift version) — newer versions must not break older fixtures.

4. **Regression baseline against real open-source code** (nightly/weekly, does not block PRs)
   - Run against 2-3 well-known, large open-source Swift repositories.
   - Record a baseline (e.g. "N cross-actor boundaries for this repository version").
   - When inference logic changes, show a diff against the baseline for manual review rather than a plain pass/fail (the baseline can legitimately shift as rules improve).

5. **Property-based / fuzz testing of the SwiftSyntax layer** (separate job, less frequent)
   - Generate random but syntactically valid attribute combinations (via the SwiftSyntax builder API).
   - Verify parser robustness against nested extensions, macros, conditional compilation (`#if os(...)`) — the parser must not crash or return nil where an attribute is clearly present.

---

## 5. Distribution

**Primary channel:** a standalone CLI binary via Swift Package Manager (`swift build -c release`), distributed via a **Homebrew formula** (`brew install swift-isolation-map`) — the standard for Swift dev tooling (this is how `swiftlint`, `swift-format`, and `periphery` are distributed), and what users expect.

**Additional (after the core stabilizes):**
- **GitHub Action** — a thin wrapper around the CLI binary for CI diff mode (v0.2), not tied to a local install.
- **SPM Build Tool Plugin** — an opt-in integration into the user's `Package.swift` (more native, no separate binary in PATH needed), but added **later**, not in v0.1: Apple's build-tool plugin API has changed over time, and there are sandboxing pitfalls (a plugin can't perform arbitrary network/file-system operations without explicit permissions).

**Repository name:** neutral, immediately understandable — working name `swift-isolation-map` (avoid committing to a brand too early).

**README:** should lead with a Mermaid graph example — value should be visible within a 10-second scroll. The demo example should run against a real project (the author's own SQLumen), not a toy example.

**License:** MIT/Apache 2.0 — the standard for tooling in the Swift community.

---

## 6. Roadmap

### v0.1 (detailed scope, reordered by priority — rule system first)

Per section 1.5, the rule system is the product; everything else is plumbing around it. Priority order below reflects that — not necessarily the order features ship, but the order they should be *built and trusted* before the rest is allowed to depend on them.

**Priority 1 — the rule system and its trust mechanism (build and validate first, against fixture/hardcoded input if needed, before the surrounding CLI mechanics exist):**
- `IsolationRuleSet` protocol + concrete versioned rule sets (Swift5RuleSet/Swift6RuleSet/Swift62RuleSet), sourced per the hierarchy in 1.5.1 (evolution proposals → compiler source → empirical compilation)
- `IsolationInferenceEngine` core resolution logic (explicit attribute → containing type → default actor isolation → protocol conformance)
- Unit tests for every inference rule, each referencing the specific compiler behavior it verifies
- Golden-file fixtures validated against real `swiftc` output (not just against proposal text), pinned per rule set
- Explicit "unsupported Swift version" disclaimer behavior

**Priority 2 — data acquisition mechanics (only once the rule system has something reliable to consume):**
- Hybrid SwiftSyntax (attributes) + IndexStoreDB (call graph) via USR-based location matching
- Resolution & discovery: container type detection (.xcodeproj/.xcworkspace/Package.swift), SchemeResolver (XMLParser for .xcscheme, `swift package describe --type json` for SPM), mandatory `--scheme`, fuzzy suggestions on typos
- Index store: explicit path or auto-detection, interactive prompt when missing, `--auto-build`, `--force-reindex`
- Staleness: raw byte content-hash, hash manifest next to the store, warning+stop by default, rebuild via flags

**Priority 3 — surface and delivery:**
- Output: `--output mermaid|dot|json`, text summary
- CLI logic tests with mocked side-effects
- Distribution: SPM + Homebrew, README with a SQLumen demo

### v0.2 (high level)
- `diff` subcommand — compares the isolation graph between git revisions
- GitHub Action — comments on PRs when a new cross-actor boundary appears
- Migration debt map — a risk-prioritized list of `@unchecked Sendable` sites for planning legacy migrations
- Possibly: an SPM build tool plugin as an opt-in alternative to the standalone CLI

### v0.3 (high level)
- Revisit the content-hashing approach (AST-normalized vs. raw vs. alternatives) — an open question left intentionally
- Deeper cross-module analysis accuracy
- Possibly: rewrite suggestions (not just detection, but suggested fixes for common migration patterns)

---

## 7. Author context (for understanding code level and style)

- Senior mobile engineer, the sole mobile developer at an e-commerce company (iOS + Android)
- 19+ years of software development experience, 10+ years in mobile
- Deep expertise: Swift/SwiftUI, Swift Concurrency (actors, Sendable, structured concurrency — at a code-review level, not surface knowledge), NetworkExtension, WireGuard internals, Secure Enclave, KMP/CMP
- The project is intended as community-first: the main goal is genuine usefulness to the Swift community, not a portfolio piece or monetization.

---

## 8. Contribution & Governance

**Goal:** retain control over the direction and quality of the project as it grows beyond a solo maintainer, without discouraging community contribution. Given the reputation-sensitivity principle in the introduction, an incorrect merge is not just a bug — it's a trust incident, so review control matters more here than in a typical project.

**Current state (solo maintainer):**
- Repository: https://github.com/btctcn/swift-isolation-map (personal account, not an organization)
- Branch protection on `main`: PR required for everyone including the owner (`enforce_admins: true`), required status check (`build-and-test`) must be green and up to date (`strict: true`), no force-push, no branch deletion, 0 required approving reviews
- Only collaborator is the owner (checked via `gh api repos/.../collaborators`, role: admin)
- Public repo: anyone can open Issues and PRs from a fork — no restriction needed for that, and this alone is already a full control mechanism (no write access required to contribute)

**Known platform limitation:** GitHub's `restrictions` field (an explicit allow-list of who can push/merge to a protected branch) only works on organization-owned repositories, not personal ones. On a personal repo, "only I can merge" is enforced simply by not granting write access to anyone else — there's no separate lock beyond that.

**Staged governance plan as the project grows:**

1. **No contributors yet (current stage):** no changes needed. Fork + PR from the community is already the correct model — contributors don't need write access to propose changes, and the maintainer reviews and merges everything.

2. **First contributors arrive:** do **not** grant write access by default. Continue accepting PRs from forks. This keeps 100% merge control with the maintainer without needing any GitHub-side restriction, and matches standard open-source practice (contributor ≠ committer).

3. **A few contributors become trusted (multiple solid PRs, consistent quality):** raise `required approving reviews` from 0 to 1 in branch protection, even for the maintainer's own PRs (self-review discipline, or a second trusted reviewer if one exists by then). This creates a review gate independent of who technically has write access.

4. **Considering write access for trusted people:** add a `.github/CODEOWNERS` file mapping specific paths (e.g. `IsolationCore/` — the inference engine — vs. `ProjectResolution/` or `OutputFormat/`) to specific reviewers. This allows delegating less risk-sensitive modules to trusted contributors while keeping mandatory maintainer review on the core inference logic, where an incorrect merge directly produces false data-race reports.

5. **If strict, GitHub-enforced merge restrictions become necessary** (e.g. you want a technical guarantee beyond "I chose not to grant access," or multiple people end up with write access for other reasons): move the repository to a GitHub organization. Only organization-owned repos support the `restrictions` field (explicit allow-list of who can push/merge to a protected branch). This is a bigger step and should be considered deliberately, not reactively — but it's easiest to do early, before the repo accumulates issues/PR history and external forks that reference the current URL.

**Guiding principle for all of the above:** review gates (required approvals, CODEOWNERS) provide control regardless of who has write access, and are preferable to relying purely on withholding access — they scale better as the project grows and don't require an all-or-nothing trust decision for each new contributor.
