# Task: bulk symbol-graph cache silently missed class-inherited isolation

Tracks [issue #44](https://github.com/btctcn/swift-isolation-map/issues/44). Found while auditing
whether the high-risk boundaries reported against Project Iris (`docs/reference-project-corpora.md`)
were themselves correctly classified -- a sanity pass following #33's own real-corpus gate, not a
planned task.

**Status: shipped.**

## Step 1 -- Hypothesis

While spot-checking why `BlogArticleDetailRouter.swift`'s `openArticle(_:)` (a plain, synchronous
`navigationController.pushViewController(...)` call, structurally identical to dozens of other
correctly-flagged Router calls elsewhere in the same file) produced **no edge at all** in the
report -- not high-risk, not medium, not even `isUnknown` -- traced it to
`IsolationInferenceEngine.resolveIsolation(for:)` resolving the raw callee USR
(`c:objc(cs)UINavigationController(im)pushViewController:animated:`) to `.nonisolated`, matching
the (also `nonisolated`) caller, so the engine's own `crossIsolationEdges()` filter correctly
excluded it as "not crossing" -- except `UINavigationController.pushViewController(_:animated:)`
is genuinely `@MainActor` (confirmed directly by compilation). Hypothesis: the external oracle's
bulk symbol-graph cache resolved this specific callee wrong, and a bulk-cache hit is never
re-checked against a live query.

## Step 2 -- Spike

**Traced precisely, not guessed**, using this project's own `IndexStoreClient` and a temporarily
instrumented `ExternalIsolationBackfill.query` (removed before shipping) against the real Project
Iris index store:

1. `linked.declarations[targetUSR]` was `nil` after linking (expected -- an SDK symbol) and
   `linked.callGraph` had 37 real edges with this exact callee. After the external oracle ran,
   `externalResolution.backfilledDeclarations[targetUSR]` held `.nonisolated` -- confirming the
   oracle itself produced the wrong answer, not a linking bug.
2. Forcing a live `cursorinfo` query for the *same* USR (bypassing the bulk-cache short-circuit)
   at its real, canonical call site returned `declarationFragments` that *do* include `@MainActor`
   -- proving the live path resolves this correctly. The bulk path and the live path disagreed on
   the identical fact.
3. Ran the real `swift symbolgraph-extract -module-name UIKit` command directly and inspected its
   JSON output: `pushViewController(_:animated:)`'s own `declarationFragments` carry no attribute
   at all, while `UINavigationController`'s own entry in the same file *does* state
   `@ MainActor class UINavigationController` explicitly. Root cause confirmed: `symbolgraph-
   extract` never restates a class's isolation on each inherited member's own fragments; a live,
   per-declaration `cursorinfo` query performs real semantic resolution and does.
4. Measured real-world scope before committing to a fix: this is not a one-method problem.
   `c:objc(cs)UINavigationController(im)pushViewController:animated:` alone has 40 real call sites
   project-wide, and the underlying mechanism (bulk fragments never restate class-inherited
   isolation) applies to any UIKit/AppKit member reached by a raw call, not an app-specific
   wrapper -- structurally the default, most common way `@MainActor` is applied across UIKit.

## Step 3 -- Documentation (this document)

## Step 4 -- Code

`Sources/SourceKitDIntegration/SymbolGraphIsolationParser.swift`: added
`hasConfirmedIsolationSignal(_:)`, distinguishing "found an explicit `nonisolated`/global-actor
attribute" from "found nothing" -- a distinction `isolation(fromFragments:)` itself doesn't need to
make (a live query's own "no attribute" is already a confirmed fact) but a bulk-cache caller does.

`Sources/SourceKitDIntegration/BulkSymbolGraphExtractor.swift`: `extract(...)` now also parses each
module's `memberOf`/`inheritsFrom` relationships (already present in `symbolgraph-extract`'s own
output, previously unused) and classifies each symbol with no confirmed signal of its own:
- **Not anyone's member** (a top-level type, a free function) -- nothing to have inherited from;
  cache the fragment-based `.nonisolated` result exactly as before.
- **A member of a container that itself resolves to `.nonisolated`** (walked recursively up the
  container's own `inheritsFrom` chain, mirroring `IsolationInferenceEngine.
  resolveInheritedIsolation`'s existing SE-0316 rule, memoized with a cycle guard) -- nothing to
  have inherited either; cache as before.
- **A member of a container that resolves to a global actor, or that can't be confirmed either
  way** -- ambiguous; omit the USR from the bulk cache entirely rather than cache a possibly-wrong
  fact a bulk-cache hit would never let a live query correct. Falls through to a live query
  instead, exactly as if the module weren't bulk-covered.

Two real regressions found and fixed during this work, both from this project's own existing golden
fixtures, not hypothesized in advance:
- A first, over-broad version (treat *every* member with no attribute as ambiguous) broke `Int.+=`
  and everything shaped like it, in `CapstoneCLITests`'s real end-to-end fixture -- a member of a
  genuinely nonisolated container has nothing to have inherited, so trusting its own absence is
  still correct. Fixed by checking the container's own resolved isolation, not just "is this a
  member at all."
- A shallow, one-level-only container check would miss isolation inherited two or more
  `inheritsFrom` hops away -- fixed by making the walk recursive.

## Step 5 -- Tests

- `Tests/SourceKitDIntegrationTests/SymbolGraphIsolationParserTests.swift`: `hasConfirmedIsolationSignal`
  against real captured fragment shapes, including the exact real bulk-extracted (no-attribute)
  `pushViewController(_:animated:)` fragments alongside the exact real live-queried (with-attribute)
  ones, side by side.
- `Tests/SourceKitDIntegrationTests/BulkSymbolGraphExtractorTests.swift`: a member with no signal is
  omitted; a non-member with no signal is still cached; a member of a nonisolated container (the
  `Int.+=` regression) is still cached; a two-hop `inheritsFrom` chain is still walked correctly and
  the member omitted.
- Full `swift test -c release`: 286/286 passing.
- **Real-corpus re-run against Project Iris**, before vs. after: app-code (excluding vendored Pods
  and the test target) high-risk boundaries went from **228 to 792 (+564), zero disappeared**.
  Spot-checked a fresh sample outside the original investigation
  (`CartListAssembly.swift`'s `storyboard.instantiateViewController(withIdentifier:)`,
  `NewsRouter.swift`'s `popViewControllerAnimated:`) -- all genuinely real, previously-silent risk.

## Step 6 -- Documenting results

This was the single largest real-world-impact fix found this session: not a narrow edge case, but
a systematic under-reporting of the tool's own core value proposition (real Swift 6 migration risk)
for any project whose code calls UIKit/AppKit methods directly rather than through app-specific
wrappers -- which is the common case, not the exception. The bug predates issue #33's own work and
was unrelated to it; found only because #33's real-corpus gate prompted a line-by-line audit of
what the tool was (and wasn't) reporting.

## Step 7 -- PR

Merged as [#45](https://github.com/btctcn/swift-isolation-map/pull/45).
