# Contributing

This is a plain Swift package — there's no `.xcodeproj` checked into the repo, and none is
needed.

## Building and running

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

Xcode opens `Package.swift` directly as a SwiftPM project:

```
xed .
```

or from Xcode itself: **File → Open…**, then select the repository folder (or `Package.swift`
inside it) — not a `.xcodeproj`, there isn't one.

Xcode indexes the package and creates a scheme per target automatically. Pick the
`swift-isolation-map` scheme to build/run the CLI, or a `*Tests` scheme to run a specific test
target. Since this is a command-line tool, pass arguments via **Product → Scheme → Edit Scheme…
→ Run → Arguments Passed On Launch** (e.g. `./SomeProject.xcodeproj --scheme SomeScheme`) before
hitting Run — otherwise it runs with no arguments and just prints the usage error.

## Where to start reading

- [`docs/README.md`](docs/README.md) — the full docs index: what the tool does, the pipeline and
  oracle diagrams, and an accurate current-status table for every other doc.
- [`docs/architecture.md`](docs/architecture.md) — the original project specification (concept,
  principles, roadmap) plus a preface noting where real implementation has since diverged from it.
- [`docs/isolation-rules.md`](docs/isolation-rules.md) — every isolation-inference rule
  `IsolationInferenceEngine` implements, and the runbook for reviewing/adding support for a new
  Swift language version.
- [`docs/reference-project-corpora.md`](docs/reference-project-corpora.md) — the two real
  projects every non-trivial claim in these docs is checked against.

## Guiding principle

A tool that gives an incorrect concurrency-safety result is worse than no tool at all. Every
isolation-inference rule ships with an explicit test referencing the exact compiler behavior it
verifies, and the tool refuses to run rather than silently produce a result it isn't confident in.
See the root [`README.md`](README.md#guiding-principle) for the full statement of this — it governs
every design decision in this repository, not just the ones documented here.
