# swift-isolation-map

A static analysis CLI for Swift actor isolation and data-race risk — a whole-project isolation map, not a single runtime trace.

> **Status: early scaffold.** The core analysis engine is not implemented yet. See [Roadmap](#roadmap) below.

## The problem

Swift 6's strict concurrency checking turned actor isolation violations into hard compiler errors. Developers migrating legacy codebases hit opaque errors like `Sending value risks data race` with no architectural context for *why* the boundary is unsafe, and no tool that shows the isolation structure of the whole project at once.

Xcode Instruments visualizes actor hops, but only as a **runtime trace of one specific run** — it doesn't cover the whole codebase statically, and it requires exercising the relevant code path first. Compiler diagnostics are bare, with no architectural framing. `swift-isolation-map` aims to fill that gap:

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

## Approach

A hybrid of `IndexStoreDB` (semantic call graph, resolved through protocols/generics) and `SwiftSyntax` (lexical isolation attributes), combined by a version-aware inference engine. See the architecture notes in this repository for full technical detail.

## Guiding principle

A tool that gives an incorrect concurrency-safety result is worse than no tool at all. Every isolation-inference rule is expected to ship with an explicit test referencing the exact compiler behavior it verifies, and the tool will refuse to run rather than silently produce a result it isn't confident in (stale index store, unrecognized Swift version).

## Roadmap

- **v0.1** — project/scheme resolution, index store discovery and staleness detection, the hybrid inference engine, `mermaid`/`dot`/`json` output.
- **v0.2** — `diff` subcommand, a GitHub Action that comments on PRs when a new cross-actor boundary appears, a migration-debt map.
- **v0.3** — revisit staleness-detection strategy, deeper cross-module accuracy, possibly rewrite suggestions.

A demo Mermaid graph generated against a real project will be added here once analysis is implemented.

## License

MIT — see [LICENSE](LICENSE).
