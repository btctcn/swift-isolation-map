# How isolation resolution actually treats Pods, SPM, and linked libraries

Written to answer a recurring question directly: this tool has exactly **two** resolution
mechanisms (`docs/README.md`'s pipeline/oracle diagrams cover both already), and which one applies
to a given piece of code depends on **whether we have its source and whether that source falls
inside the directory walk** — not on what *kind* of dependency it is. "Pods," "SPM," and "linked
libraries" are not three separate code paths; they're three different answers to that one
question. Understanding this precisely also settles a real scoping question for
[issue #33](https://github.com/btctcn/swift-isolation-map/issues/33) (closure-attribution false
positives) — see the end of this document.

## The two mechanisms, restated precisely

**Mechanism 1 — direct syntax analysis.** Applies to every `.swift` file
`StalenessOrchestration.swiftFiles` finds walking the project root. The only directories excluded
(`Sources/swift-isolation-map/StalenessOrchestration.swift:40`):

```swift
private static let skippedDirectoryNames: Set<String> = [".build", ".swiftpm", ".git", "DerivedData"]
```

`Pods` and `Carthage` are **not** in this list — a real, deliberate, but still-open product
decision (`docs/task-pods-in-scope-research.md`). Every file this walk finds gets full
`SyntaxAnalysis` extraction, real `DeclarationLinker` USR resolution against the project's own
index store, and its isolation is inferred the same way the app's own code is — no different
treatment at all.

**Mechanism 2 — the external oracle** (`ExternalIsolationBackfill`, diagrammed in
`docs/README.md`). Applies to everything the walk above doesn't reach: a bulk
`swift symbolgraph-extract` pass for well-known modules first
(`BulkSymbolGraphExtractor.defaultModules = ["UIKit", "AppKit", "SwiftUI", "Foundation",
"ObjectiveC", "CoreGraphics", "Dispatch", "Swift", "CoreFoundation"]`, plus whatever
`BulkExtractionEnvironmentProviding` discovers as this project's own real dependency modules —
`FrameworkModuleDiscovery` for Xcode's `FRAMEWORK_SEARCH_PATHS`, or the `Modules` directory under
SwiftPM's own build output), then a live `sourcekitd` `cursorInfo` query per USR the bulk cache
didn't cover. Both paths ask the *real, compiled* module directly — no source needed, no
guessing, ground truth from the compiler itself.

## The three cases

**Project code ↔ Pods.** Genuinely mixed, and easy to get wrong by assuming "Pod = external":

- A Pod with real source under `Pods/` (the common case) goes through **Mechanism 1** — it is
  extracted, linked, and isolation-inferred exactly like the app's own code. From this tool's
  perspective there is no boundary here at all.
- A binary-only Pod (a `.framework`/`.xcframework` with no source) has no files for the walk to
  find, so it necessarily goes through **Mechanism 2**, same as any other compiled dependency.

**Project code ↔ SPM.** Always **Mechanism 2**. SwiftPM checkouts live under
`DerivedData/.../SourcePackages/checkouts/`, outside the project root the walk ever looks at —
even though real `.swift` source exists on disk, this tool never parses it. Isolation is resolved
by asking the real, built `.swiftmodule` via the oracle, the same as asking about UIKit.

**Project code ↔ linked libraries** (XCFrameworks, system frameworks, any other compiled
dependency). Always **Mechanism 2** as well — the same path as SPM and binary Pods.

## "What if the code is inside a compiled framework?" — why this doesn't need a third mechanism

This question matters specifically because of issue #33 (`Task { @MainActor in }`/
`DispatchQueue.main.async` closures hiding a real MainActor hop from the call graph, causing a
false-positive high-risk boundary). Splitting the question by which side of the call is inside
the compiled framework:

- **As the callee** (project code calls into the framework): no problem, by construction.
  Mechanism 2 asks the real compiled module directly for its own declared isolation — the same
  ground-truth answer a human reading the framework's own `.swiftinterface` would get. There's no
  closure to misattribute here at all; the oracle isn't inferring anything from source, it's
  reading a fact.
- **As the caller** (a closure *inside* the framework's own implementation calls back into
  something, and that closure's real isolation should protect the call): this can only ever be a
  problem for code this tool actually parses with `SyntaxAnalysis` — i.e., Mechanism 1's territory.
  The call graph -- read via `RawIndexStoreClient`'s raw `libIndexStore` API today
  (`docs/task-raw-indexstore-spike.md`; the same argument held for `IndexStoreDB` before that
  migration too, since both read the identical on-disk index) -- is built from the *analyzed
  project's own* index store; a genuinely
  precompiled dependency was never compiled as part of this workspace's own indexed build, so no
  call-graph edge with a caller inside it can exist in the graph in the first place. There's
  nothing to fix here because the bug's precondition (a real call-graph edge whose caller is a
  closure we can't see into) never arises for true binary dependencies.

**Conclusion**: issue #33's fix only ever needs to run over the same file set Mechanism 1 already
covers — the project's own source, and (per today's inclusive-by-default behavior) Pod source with
real `.swift` files. SPM and binary/linked dependencies are structurally out of scope for that bug,
not by a deliberate exclusion that needs deciding, but because the failure mode cannot occur there.
