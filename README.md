# swift-isolation-map

A static analysis CLI for Swift actor isolation and data-race risk — a whole-project isolation
map, not a single runtime trace.

> **Status: working.** The full pipeline is implemented and tested — project/scheme resolution,
> index-store discovery and staleness detection, a hybrid `IndexStoreDB` + `SwiftSyntax`
> inference engine, and an external-isolation oracle that resolves compiled-dependency symbols
> (CocoaPods, XCFrameworks, SDK frameworks) via bulk `symbolgraph-extract` and, as a fallback, live
> `sourcekitd` queries. 246 tests passing (`swift test`), continuously validated against two real,
> independent projects (one private, ~1450 source files across 42 CocoaPods + 9 SPM dependencies;
> one public), not just fixtures. `mermaid`/`dot`/`json` output all ship. Not yet built: the `v0.2`
> items below (`diff` subcommand, GitHub Action, migration-debt map).

## The problem

Swift 6's strict concurrency checking turned actor isolation violations into hard compiler errors. Developers migrating legacy codebases hit opaque errors like `Sending value risks data race` with no architectural context for *why* the boundary is unsafe, and no tool that shows the isolation structure of the whole project at once.

Xcode Instruments visualizes actor hops, but only as a **runtime trace of one specific run** — it doesn't cover the whole codebase statically, and it requires exercising the relevant code path first. Compiler diagnostics are bare, with no architectural framing. `swift-isolation-map` fills that gap:

1. Static analysis of the whole project, not a runtime trace of one run
2. An architectural map (the full isolation-domain graph), not a single-run timeline
3. Explains *why* an isolation boundary is risky, in architectural context — not just *what* happened
4. CI-suitable — can be embedded as a pipeline gate, which a runtime trace cannot
5. A migration-debt map, trackable over time via git history

## Compiler diagnostics: a concrete look

It's easy to assert that `Sending value risks data races` is uninformative;
here's what actually happens when you compile three progressively-realistic
reproductions under Swift 6.3 strict concurrency. The diagnostic is precise
when the unsafe access is in the same function as the `send` — it names the
exact conflicting line. The moment the `send` crosses a function boundary
(a helper call, a `Task { }` closure), the diagnostic still correctly fires,
but stops pointing at the access it actually conflicts with, and can't rank
which of several candidate mutations is the real one. See
[`docs/motivation.md`](docs/motivation.md) for the full reproductions and
unedited compiler output.

## How it works

A hybrid of `IndexStoreDB` (semantic call graph, resolved through protocols/generics/witnesses)
and `SwiftSyntax` (lexical isolation attributes), combined by a version-aware inference engine.
Where a call reaches into a *compiled* dependency the index alone can't explain (a CocoaPod, an
XCFramework, an SDK framework), an external-isolation oracle backfills the missing fact — a bulk
`swift symbolgraph-extract` cache first, a live, sequential `sourcekitd` query only for what the
cache misses. See [`docs/README.md`](docs/README.md) for the full pipeline and oracle diagrams,
[`docs/architecture.md`](docs/architecture.md) for the original project specification, and
[`docs/research/`](docs/research/README.md) for the real research/review trail behind the oracle's
design.

## Usage

```
swift-isolation-map <path> --scheme <scheme> [OPTIONS]

ARGUMENTS:
  <path>                      Path to a .xcodeproj, .xcworkspace, or Package.swift

OPTIONS:
  --scheme <scheme>           Build scheme (Xcode) or product/target (SPM). Required.
  --index-store-path <path>   Explicit path to the index store. If provided, auto-detection
                              is skipped.
  --auto-build                If the index store is missing or stale, build the project
                              without an interactive prompt.
  --force-reindex             Forces a rebuild, ignoring any existing (even fresh) index store.
  --output <format>           mermaid | dot | json (default: mermaid)
  --out-file <path>           Where to write the result (default: stdout)
  --verbose                   What was searched, where the index store was found, how many
                              types were processed.
```

Example:

```
swift-isolation-map ./MyApp.xcworkspace --scheme MyApp --auto-build --output json --out-file report.json
```

Exit codes: `0` — no high-risk boundaries found; `1` — high-risk boundaries found (fail a CI
gate on this); a thrown error otherwise (bad scheme, unreachable index store, etc.).

## Building and running (development)

### 1. From the terminal

```
swift build              # debug build
swift build -c release   # release build
swift test -c release    # run the test suite -- release, not debug: once IndexStoreDB and
                          # sourcekitdInProc (both C/C++-interop dependencies) are linked into
                          # the test bundle, a plain debug-config `swift test` has reproduced an
                          # intermittent segfault inside the swift-testing runtime itself
                          # (unrelated to this project's own code; release builds are unaffected,
                          # and CI always uses release). See docs/priority-2-phase-3-linking.md
                          # and docs/priority-3-phase-b-sourcekitd-client.md. Debug-config runs
                          # have also completed cleanly on this same machine — the crash is real
                          # but not deterministic, so a clean debug run is not evidence it's gone;
                          # -c release stays the safe default until it's root-caused further.
swift run swift-isolation-map --help
```

### 2. From Xcode

This is a plain Swift package — there's no `.xcodeproj` checked into the repo, and none is needed. Xcode opens `Package.swift` directly as a SwiftPM project:

```
xed .
```

or from Xcode itself: **File → Open…**, then select the repository folder (or `Package.swift` inside it) — not a `.xcodeproj`, there isn't one.

Xcode indexes the package and creates a scheme per target automatically. Pick the `swift-isolation-map` scheme to build/run the CLI, or a `*Tests` scheme to run a specific test target. Since this is a command-line tool, pass arguments via **Product → Scheme → Edit Scheme… → Run → Arguments Passed On Launch** (e.g. `./SomeProject.xcodeproj --scheme SomeScheme`) before hitting Run — otherwise it runs with no arguments and just prints the usage error.

## Guiding principle

A tool that gives an incorrect concurrency-safety result is worse than no tool at all. Every isolation-inference rule ships with an explicit test referencing the exact compiler behavior it verifies (tracked in [`docs/isolation-rules.md`](docs/isolation-rules.md)), and the tool refuses to run rather than silently produce a result it isn't confident in (stale index store, unrecognized Swift version, an oracle query that failed outright reports `unknown`, never a guessed `nonisolated`).

## Language-mode contract

This tool reports actor isolation **as the code actually compiles today** — using each module's own real `-swift-version` from its real build arguments, never a hardcoded or assumed language mode. This matters because isolation semantics genuinely differ between language modes for some constructs (e.g. whether a class's synthesized zero-argument `init()` inherits its type's global-actor isolation depends on the language mode in effect — see SE-0411 — confirmed empirically, not assumed, against a real project's own build). Analysis results describe the project as it is built right now; they are **not** a prediction of what a future migration to a newer Swift language mode would report. If your build mixes modules on different `-swift-version` settings, each module's isolation is computed in its own mode, matching how the real build itself behaves.

## Roadmap

- **v0.1 — shipped.** Project/scheme resolution, index-store discovery and staleness detection, the hybrid inference engine, the external-isolation oracle (bulk + live), `mermaid`/`dot`/`json` output, a file-sorted query-ordering optimization (~33% faster oracle phase on a real ~2200-file project, zero semantic change).
- **v0.2** — `diff` subcommand, a GitHub Action that comments on PRs when a new cross-actor boundary appears, a migration-debt map.
- **v0.3** — revisit staleness-detection strategy, deeper cross-module accuracy, possibly rewrite suggestions.

A demo Mermaid graph generated against a real project will be added here.

## License

MIT — see [LICENSE](LICENSE).
