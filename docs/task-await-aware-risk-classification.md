# `riskLevel`/`crossIsolationEdges` are blind to `await`

Tracks [issue #46](https://github.com/btctcn/swift-isolation-map/issues/46).

**Status: shipped as a new, purely informational `isAwaited` field on `AnalysisEdge` -- `risk`
itself is deliberately left unchanged. The issue's own originally-proposed fix (downgrade an
awaited `.high` edge to `.low`) was implemented, measured against this project's own real
golden-fixture test suite, found to directly contradict an existing, deliberately-designed ground
truth, and reverted in favor of this scoped-down design. See Step 2.**

## Step 1 — Hypothesis

`AnalysisReportBuilder.riskLevel(caller:callee:)` classifies a call purely from the *declared*
(or closure-substituted) isolation of the caller and callee -- it has no notion of `await` at all.
A `nonisolated async` function that legitimately `await`s a call into `@MainActor`-isolated state
is 100% safe, real, compiling code -- but was classified identically to a `nonisolated`
*synchronous* function making the same call, which is a genuine, unconditional risk (`await` is
syntactically illegal there). Filed as a structural design question raised auditing whether this
tool's own high-risk boundaries were themselves correctly classified, not a symptom found in real
data at the time (Project Iris's current app-code high-risk edges all had plain synchronous
callers, confirmed by reading each one -- the gap cost nothing on that specific corpus, but any
codebase using `async`/`await` more broadly in its UI-adjacent code could see real false positives).

## Step 2 — Spike

Two separate facts were missing, not one, per the issue's own analysis:
1. Is the *declaration* `async`.
2. Is *this specific call site* preceded by `await` -- the one that actually matters, since being
   inside an `async` function is necessary but not sufficient (a synchronous call written without
   `await` inside an `async` nonisolated function is still a real compile error).

The issue's own suggested simplification made fact 1 unnecessary: **"if this call site is
`await`-prefixed at all, never classify it `.high`, regardless of declared caller isolation"** --
simpler, and correct by construction, since `await` at a call site is only legal to write at all
when it's doing a real, compiler-checked hop.

Confirmed the exact `SwiftSyntax` shape needed: `AwaitExprSyntax` wraps the awaited expression
directly (`await foo.bar()` parses as an `AwaitExprSyntax` whose `expression` is the
`FunctionCallExprSyntax`). Confirmed, the same way `docs/task-closure-isolation-attribution.md`'s
closure ranges already do for Rule A/B, that a call-graph edge's own location (`IndexStoreDB`'s
`.call`-role occurrence, at the referenced symbol's own token) always falls inside the *source
range* of the `AwaitExprSyntax` wrapping it -- so range containment, not an exact token match, is
the right test, reusing the exact same geometry `ClassifiedClosure.contains(line:column:)` already
uses.

**Implemented the issue's literal proposal first, and it broke a real, pre-existing, deliberately-
designed ground-truth test.** `Tests/swift-isolation-mapTests/CompiledDependencyCLITests.swift`'s
golden-fixture matrix includes `MechanismA.swift`:

```swift
final class ProjectCell: NSCell { func touch() { title = "x" } }  // NSCell: real, ObjC-bridged @MainActor SDK type
nonisolated func callMechanismA() async {
    let cell = await ProjectCell()
    await cell.touch()
}
```

This is real, compiling, already-correctly-`await`-ed code -- exactly the shape issue #46 argues
should not be `.high`. But the test explicitly asserts `mechanismAEdges.allSatisfy { $0.risk ==
.high }`, and this is not an oversight: it's the same real-corpus ground truth
`docs/task-compiled-dependency-isolation.md`'s whole research thread was built to get right, and
it directly reflects a decision already written into the root `README.md`'s "An honest caveat
about risk" section -- `.high` is deliberately **not** "an unconditional data race"; it's "a
`nonisolated` declaration has a call edge into isolated state," full stop, tracked as migration
debt *regardless* of whether that specific edge already has a correct `await` protecting it today.
The README's own words: *"by the time your project compiles under Swift 6, every one of these
edges is already `await`-ed or explicitly unsafe *somehow*, so `high` findings are best read today
as 'every place migration debt lives,' not 'every place there's an active bug.'"* Downgrading an
awaited `.high` edge to `.low` would mean the tool stops surfacing exactly the boundaries a
migration effort most wants to see (the ones already handled correctly, worth confirming stay that
way, or worth eventually restructuring so the crossing doesn't need to exist at all).

**Resolution, decided explicitly rather than guessed:** keep `.high`'s existing "migration debt"
semantics completely unchanged; surface `await`-presence as its own new, purely informational
field instead of feeding it into `risk` at all. This still closes the real, useful part of the
original gap (a report reader can now tell "already awaited" apart from "not awaited at all,"
without the tool making an incorrect claim about which shapes are risk-free) without touching the
project's own already-verified classification semantics.

## Step 3 — Documentation (this document)

## Step 4 — Code

New file `Sources/SyntaxAnalysis/AwaitedCallSiteExtractor.swift`: `AwaitedCallSiteExtractor.extract(from:fileName:converter:) -> [AwaitedRange]`,
a per-file pass recording every `AwaitExprSyntax`'s own source range. Unlike
`ClosureIsolationExtractor`/`ClassifiedClosure`, this needs no project-wide classification step
(no accept-list to resolve against) -- extraction produces the final fact directly.

Threaded through the same pipeline shape closures already use:
- `ExtractionResult.awaitedRanges` (`DeclarationExtractor.extractWithContext`).
- `FileAnalysisResult.awaitedRanges` (`ProjectResolution.FileAnalyzer`).
- `LinkedAnalysis.awaitedRangesByFile` (`IndexStoreIntegration.DeclarationLinker.link`) -- a plain
  per-file merge, no classification needed.
- `AnalysisReportBuilder.build(awaitedRangesByFile:)`.

`OutputFormat.AnalysisEdge` gained a new `isAwaited: Bool` field (same defaulted-`Decodable`
pattern as the existing `isUnknown`, so JSON written before this field existed still decodes). In
`build()`'s edge-mapping closure:

```swift
let risk = riskLevel(caller: callerIsolation, callee: calleeIsolation)  // unchanged
let isAwaited = (awaitedRangesByFile[edge.location.file] ?? []).contains {
    $0.contains(line: edge.location.line, column: edge.location.column)
}
```

`isAwaited` is passed straight through to the new `AnalysisEdge`, and nothing else about `risk` or
`explanation()` changes.

One consequence of range-containment worth naming, independent of the risk-vs-informational
question above: for a compound expression like `await process(value: helper())`, `helper()`'s own
call-graph edge (a plain synchronous call, no `await` of its own) also falls inside the `await`
expression's range and would be marked `isAwaited` too. This is a deliberate, documented
over-approximation, not an oversight -- see the extractor's own doc comment and its
`nestedCallInsideAwaitedArgumentIsContained` test. Since `isAwaited` is purely informational now
(never changes `risk`), the practical consequence of this over-approximation is limited to the
field itself reading `true` for a rare nested-nonawaited-call shape, not a risk miscalculation.

## Step 5 — Tests

`Tests/SyntaxAnalysisTests/AwaitedCallSiteExtractorTests.swift`: no-await produces no ranges; an
awaited call produces exactly one range; the range contains the call site's own location (measured
the same way a call-graph edge's location is); ranges carry their own file name; multiple awaits
each produce their own range; a call nested inside an awaited argument is (deliberately) still
contained.

`Tests/swift-isolation-mapTests/AnalysisReportBuilderTests.swift`: a call site inside a real
`await` expression is marked `isAwaited`, but `risk` stays `.high` (confirmed against the
Mechanism A shape above); the identical shape without an `await` is not marked; an awaited range
in a *different* file never marks an edge in this file (ranges are looked up per file, not
globally); `isAwaited` is set for a `.medium` edge too, proving it's a pure syntactic fact
independent of `risk`.

Full `swift test -c release`: 311/311 passing, including the previously-broken
`CompiledDependencyCLITests` golden-fixture suite (confirmed broken by the reverted downgrade
approach, confirmed fixed by this scoped-down design -- not just "tests still green" but the exact
regression traced to its root cause and closed).

## Step 6 — Documenting results

Real-corpus re-run against Project Iris (post-#51/#52/#53/#57/#58/#59):

| | value |
|---|---|
| `highRiskBoundaries` / `crossActorBoundaries` | 1167 / 24852 (both unchanged from the pre-fix baseline, as expected for a purely informational, non-risk-affecting field) |
| Edges with `isAwaited: true` | 14 of 24852 (0.06%) |
| ...of those, `.high` | 7 -- real occurrences of exactly the Mechanism-A shape this document's Step 2 describes |
| ...of those, `.low` | 5 |
| ...of those, `.medium` | 2 |

The 7 real `.high`-and-`isAwaited` edges are a small but genuine correction to this issue's own
Step 1 finding ("every one of Project Iris's current app-code high-risk edges... zero call sites...
have `await`") -- that check was run against an older report, before #51/#57/#58's fixes surfaced
previously-hidden high-risk edges (`highRiskBoundaries` grew 853 → 933 → 1167 across this session).
Confirms the field is measuring something real on this corpus, not a hypothetical shape that never
occurs -- and confirms the decision in Step 2 was correct: these 7 edges are real, and per the
project's own already-established philosophy, correctly still need to show as `.high`.

Not in scope, deliberately: distinguishing `@unchecked Sendable`/`nonisolated(unsafe)` escape
hatches (a separate, already-documented gap, see `AnalysisReportBuilder`'s own doc comment) --
`isAwaited` only answers "is there a real `await` here," not "is this call site provably safe by
every mechanism Swift offers."

## Step 7 — PR

Merged as [#60](https://github.com/btctcn/swift-isolation-map/pull/60).
