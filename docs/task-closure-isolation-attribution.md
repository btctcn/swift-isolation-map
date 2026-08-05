# Closure-level isolation attribution: a known gap in `swift-isolation-map`'s call-graph analysis

**Status: investigated, root-caused, design proposed — not yet implemented.** Tracks
[issue #33](https://github.com/btctcn/swift-isolation-map/issues/33). Written for a reader with no
prior context on this project: what the problem is, why it happens, what's been empirically
confirmed about its exact boundaries, and the fix design currently awaiting approval before any
code is written.

## 1. The problem, with a real example

`swift-isolation-map` flags a call as a "high-risk boundary" when a `nonisolated` declaration calls
into `@MainActor`-isolated code with no `await`/actor hop — a real signal for code that will fail
to compile under Swift 6's strict concurrency checking. It does this by resolving, for every call
site in the project's call graph, the *declared* isolation of the enclosing declaration and the
isolation of the callee, then comparing the two.

Real code found during a full audit against a private ~2,250-file production iOS app (see
`docs/reference-project-corpora.md`, "Project Iris"):

```swift
final class Cart {
    private func updateCartCounter(showWhisper: Bool = true) {
        let counter = items.count
        Cart.saveCounterToDefaults(count: counter)

        Task { @MainActor in
            guard let topController = UIApplication.topViewController() else { return }
            topController.setCartCount(count: counter)

            if showWhisper {
                CartFinalizeView.show()
            }
        }
    }
}
```

`updateCartCounter` is a plain, `nonisolated` method (`Cart` has no isolation attribute). The tool
correctly determines this. It then flags the call to `CartFinalizeView.show()` (a `UIView`
subclass's static method, `@MainActor` by inheritance) as a high-risk `nonisolated -> @MainActor`
boundary — **incorrectly**. The call is physically inside `Task { @MainActor in ... }`, which really
does hop onto the main actor before executing its body. A minimal, faithful reduction of this exact
shape compiles with **zero diagnostics** under both `-swift-version 6` and
`-swift-version 5 -strict-concurrency=complete` — the real Swift compiler agrees this is safe. Four
more real instances of the same class of false positive were found in the same audit (three via
`Task { @MainActor in }`, one via `DispatchQueue.main.async { }` — see §3).

## 2. Root cause

The tool's call graph comes from `IndexStoreDB`, the same indexing infrastructure `sourcekit-lsp`
uses. A `.call`-role occurrence's `.calledBy` relation names the occurrence's enclosing declaration
— but that relation only ever names a real, *declared* symbol (a function, method, or closure that
is itself indexed as a named entity). Anonymous closure literals — `Task { @MainActor in ... }`,
`DispatchQueue.main.async { ... }` — are not separately indexed symbols in `IndexStoreDB`'s data
model. A call physically written inside one is attributed, in the index, to the nearest *named*
enclosing declaration (here, `updateCartCounter` itself), with no signal anywhere in the index that
the call is textually inside a closure that changes its effective isolation.

This means the gap is a genuine, structural limitation of the data source this tool is built on
(confirmed by direct inspection of `IndexStoreDB`'s query surface,
`Sources/IndexStoreIntegration/IndexStoreClient.swift`), not a logic bug in the isolation-inference
engine (`IsolationInferenceEngine`) itself, which correctly applies the declared-isolation rules to
whatever caller/callee facts it's handed.

## 3. What's confirmed empirically about which closure forms trigger this

Three forms are **confirmed, real, live compiler results** — not assumptions — each checked with a
minimal, faithful reduction against a real Swift toolchain (Xcode 26.4, Swift 6.3), targeting a real
iOS SDK, under both `-swift-version 6` and `-swift-version 5 -strict-concurrency=complete`:

| Form | Suppresses the diagnostic? | How confirmed |
|---|---|---|
| `Task { @MainActor in ... }` | **Yes** | Zero diagnostics on a faithful reduction of the real `Cart.swift` case |
| `DispatchQueue.main.async { ... }` | **Yes** | Zero diagnostics; contrasted directly against `DispatchQueue.global().async { }` on the identical shape, which *does* produce the real `call to main actor-isolated instance method ... in a synchronous nonisolated context` diagnostic — confirming the SDK overlay's special-case is specific to `.main` |
| `DispatchQueue.main.asyncAfter(deadline:execute:)` | **Yes** | Same test, same result |

One form was checked and found **not** to apply, and one custom wrapper was checked and found to
**not** share the SDK's special-casing:

- **`MainActor.run { ... }`** is itself an `async` function. Calling it bare from a synchronous
  `nonisolated` context is a **hard compile error** (`'async' call in a function that does not
  support concurrency`), not a warning — a categorically different usage shape from the other three
  (which are fire-and-forget, no `await` needed). No real occurrence of this pattern causing a false
  positive was found in the audited codebase, so it's out of scope for now rather than guessed at.
- **A custom `DispatchQueue.toMain(_:)` wrapper** (a real helper found in the same audited codebase,
  `static func toMain(_ work: @escaping () -> Void) { ... main.async(execute: work) ... }`) does
  **not** suppress the diagnostic, even though it internally calls `DispatchQueue.main.async`. The
  SDK's special-casing is a property of the *exact* declaration `DispatchQueue.main`'s own
  `async(execute:)`/`asyncAfter(deadline:execute:)` — it does not propagate through an intermediate
  wrapper whose own parameter type is a plain `@escaping () -> Void`, not an `@MainActor`-attributed
  closure type. Confirmed by compiling the wrapper's exact real shape and observing the diagnostic
  still fires.

## 4. Real-world scale of the problem

A full audit of every one of 247 high-risk boundaries found in the app-code-only subset of a real,
full-project run classified 240 as genuinely real (confirmed against the compiler, matching one of
several other confirmed-real patterns not related to this gap) and exactly 7 as false positives of
this specific class — all five real occurrences above, one wrapping three separate call-graph
edges. **Roughly 3% of that run's real findings**, concentrated in a handful of idiomatic
"hop-to-main-actor-and-update-UI" call sites, not spread evenly across the codebase.

## 5. Why this cannot affect compiled dependencies (SPM, binary Pods, XCFrameworks)

See `docs/external-dependency-boundaries.md` for the full explanation; summarized here because it
directly bounds this task's scope. `swift-isolation-map` has exactly two resolution mechanisms:
direct `SyntaxAnalysis` of source files the project's own directory walk finds (which is what
builds the call graph this bug affects), and an external oracle that asks a *compiled* module's
real, declared isolation directly via `sourcekitd` (no source, no call graph, no closures to
misattribute — it's asking a fact, not inferring one). `IndexStoreDB`'s call graph is built from
the *analyzed project's own indexed build* — a real precompiled dependency (an SPM package, a
binary Pod, an XCFramework) was never compiled as part of that indexed build, so no call-graph edge
with a caller inside it can exist in the first place. **The fix this document proposes is
structurally scoped to source this tool already parses itself** — the project's own code, and (per
this project's current inclusive-by-default behavior) Pod source with real `.swift` files — never
SPM or binary dependencies, not by a choice that needs making, but because the bug's precondition
cannot arise there.

## 6. Proposed fix design (not yet implemented — pending approval)

The isolation-inference engine (`IsolationInferenceEngine`) is a deliberately unmodified,
foundational component elsewhere in this project (`AnalysisReportBuilder`'s own header comment
calls it "Priority 1, unmodified"). The proposed design preserves that boundary entirely: it never
changes what isolation a *declaration* is reported as having (the enclosing method genuinely is
`nonisolated`, and should keep being reported as such everywhere else). It only changes which
isolation is used when classifying the *risk* of one specific call-graph edge.

1. **New extraction pass** (`SyntaxAnalysis`, alongside the existing declaration-extraction
   `SyntaxVisitor`s already in this codebase): recognize the three confirmed forms above as
   closure literals, and record each one's exact source range (start/end **line and column**, not
   just line — to avoid falsely covering unrelated code sharing a line) together with the
   `IsolationKind` it establishes (`.globalActor(name: "MainActor")` for all three confirmed forms
   today).
2. **New field on the per-file extraction result**: a list of these `(range, isolation)` pairs,
   threaded alongside the declarations/conformances this pass already produces.
3. **Applied at exactly one point**: `AnalysisReportBuilder.build`'s edge-mapping step
   (`Sources/swift-isolation-map/AnalysisReportBuilder.swift`, where `callerIsolation` is computed
   per edge from `engine.resolveIsolation(for: edge.callerUSR)`). If a given edge's own call-site
   location falls inside one of the recorded ranges for that file, the range's isolation is used
   for *that edge's* risk computation instead — the declaration's own resolved isolation, used
   everywhere else in the report (its own node entry, other edges from the same declaration outside
   the closure), is untouched.
4. **Explicit, deliberate scope limit**: no recursion into a further, plain (non-isolated) closure
   nested inside a recognized isolated one. Only the immediate statement list of the recognized
   outer closure counts as protected. All five real occurrences found in this audit are single-level
   (no further nesting), so this limit doesn't cause any known real false negative; it exists to
   avoid the much harder, unbounded problem of proving what isolation an arbitrarily nested closure
   passed to an arbitrary function actually runs under.

## 7. Open questions before implementation

- Whether additional closure forms (e.g. explicit `Task(priority:operation:)` with an
  `@MainActor`-attributed operation closure, or other actor's `.run { }`-style APIs) should be
  recognized now or added only when a real occurrence is found — current design leans toward the
  latter, matching this project's "confirm before generalizing" discipline.
- Exact new-type/field naming and where in the pipeline the per-file ranges get merged across files
  before reaching `AnalysisReportBuilder` (a small design detail, not yet finalized).
