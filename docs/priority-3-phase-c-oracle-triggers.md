# Priority 3, Phase C — oracle triggers (decision record)

Per the implementation plan's instruction to record this decision explicitly. Two trigger sources
were specified: edge-level (direct calls into external code) and declaration-level (external
superclass/protocol conformance). Both were required, not alternatives — verified against the
original motivating bug (`docs/task-compiled-dependency-isolation.md` §2.1,
`NewsTableCell`/`UITableViewCell`), which is a pure inheritance-chain failure with no call-graph
edge involved at all.

## A real prerequisite gap, closed

`DeclarationLinker.link(_:)` built `callGraph` by calling `indexStore.callGraphEdges(forUSR:)`
only for USRs already in its own rewrite map — i.e. only project-local USRs. Since
`callGraphEdges(forUSR:)` hardcodes `calleeUSR: usr` (the same USR passed in), the combined call
graph could **structurally never** contain an edge whose callee is external. Closed by a new
`IndexStoreQuerying.callSites(inFile:)` (scans `.call`-role occurrences per file, not by known
USR) and folding its externally-callee'd results into `callGraph` directly — so
`IsolationInferenceEngine.crossIsolationEdges()` (unmodified) picks them up automatically once
backfilled.

## Superclass and protocol conformance need genuinely different backfill mechanisms

Confirmed by reading `IsolationInferenceEngine.resolveInheritedIsolation` directly, not assumed
from the earlier design docs' phrasing (which conflated the two):

- **Superclass**: a real `declarations[superclassUSR]` lookup. Backfilling a new `DeclarationInfo`
  entry there, keyed by the external superclass's own USR, is exactly what this needs.
- **Protocol conformance**: **no such lookup exists**. The engine reads
  `conformance.protocolGlobalActorName` directly off the `ProtocolConformance` value already
  attached to the conforming declaration. Backfilling `declarations[protocolUSR]` for an external
  protocol has zero effect — the fix has to rewrite the conforming declaration's own
  `conformances` array instead (mirroring `DeclarationLinker.relink`'s existing precedent for the
  project-local case). `ExternalIsolationBackfill` produces two separate result maps
  (`backfilledDeclarations` for new external-USR entries, `updatedDeclarations` for rewritten
  project-local entries) for exactly this reason.

## Declaration-level queries: only "safe representative" declarations are queried

Querying a declaration's own effective isolation (the spike's proven "hover the project's own
declaration" shape) is only sound as a stand-in for what its superclass/protocol contributes when
the declaration has **no explicit isolation of its own** to override that inheritance. A
declaration with its own `explicitIsolation` never needs this backfill anyway (the engine checks
`explicitIsolation` before ever consulting inheritance), so skipping it costs nothing and avoids
misattributing the wrong isolation to a shared external superclass/protocol.

## Correction made to the plan during Phase B, load-bearing here

A cursor-info result matched by USR but carrying no isolation-attribute fragment is a genuine
**positive `.nonisolated` fact**, not `unknown` (see `docs/priority-3-phase-b-sourcekitd-client.md`).
`ExternalIsolationBackfill` relies on this directly — most real backfills in practice (see below)
resolve to plain `.nonisolated`, not a global actor.

## `unknown` propagation on declaration-level failure: one level of member propagation

When a declaration-level query fails, the declaration's own USR *and* every other declaration
whose `containingTypeUSR` equals it (its direct members) are marked `unknown` — not just the
declaration itself. This is necessary because `IsolationInferenceEngine`'s member→containing-type
propagation is recursive: a member whose isolation depends on its containing type's unresolved
superclass would otherwise silently fall through to the engine's own default/`.nonisolated`
fallback, reproducing the exact bug this task exists to fix, one level down. **Known, documented
limitation**: only one level of propagation is implemented (a member's own member — e.g. a nested
type inside an affected type — is not walked). Not hit by any fixture or real-world validation so
far; revisit if Phase F's real-world re-run surfaces it.

## A real, unexpected finding from wiring this into the real CLI, not from design review

Making `SwiftIsolationMap` conform to `AsyncParsableCommand` (needed to `await`
`ExternalIsolationBackfill`, an `actor`-based API) broke `swift test` outright: the test process
itself failed immediately with this tool's own `"Missing expected argument '--scheme'"` usage
error, before running a single real test — a real toolchain interaction between `@main` on
`AsyncParsableCommand` and a test target linking the same executable target. **Resolved by keeping
`SwiftIsolationMap` a plain, synchronous `ParsableCommand`** and bridging into the async call with
a one-shot `DispatchSemaphore`-based blocking bridge (`runAsyncBridge`, in `SwiftIsolationMap.swift`)
— the spawned `Task` runs on the default global executor's own thread pool, distinct from the
thread blocking on the semaphore, so this doesn't deadlock. Cheaper and safer than chasing the
`AsyncParsableCommand`/test-target interaction further for one call site.

## A second real finding, from the golden-fixture test regressing and being root-caused, not just fixed

Wiring `callSites(inFile:)` folding (this phase) exposed real call-graph edges from
`Tests/Fixtures/simple-actor`'s `Counter.increment()` into its own **compiler-synthesized property
accessors** (`Counter.value`'s implicit getter/setter) and `Swift.Int.+=` — genuinely real edges
IndexStoreDB's call graph always contained, never surfaced by this tool before this phase. All
three come back `unknown`, not a compiled-dependency case at all: `sourcekitd` cursor-info,
queried at the accessor call's source position, resolves to the **property's own USR**, not the
synthesized getter/setter's distinct USR IndexStoreDB tracks — a real, structural granularity
mismatch between the two systems for implicit accessors specifically. Correctly reported as
`unknown` (a genuine USR-match miss) rather than silently miscounted as a confirmed risk or
silently dropped — exactly the epistemic guarantee this task exists to provide, even though the
specific *cause* here (implicit-accessor USR granularity) is adjacent to, not the same as, the
original compiled-dependency motivation. `CapstoneCLITests.swift`'s assertions were updated to
match this new, more complete picture (`crossActorBoundaries` 1 → 4, `highRiskBoundaries`
unchanged at 1, three edges explicitly asserted `isUnknown` and non-`.high`) — a real improvement
in completeness, not a regression, once understood.

## Status

`Sources/swift-isolation-map/ExternalIsolationBackfill.swift` + `UTF8OffsetLocator.swift`, plus
the `IndexStoreIntegration`/`AnalysisReportBuilder`/`AnalysisReport`/`SwiftIsolationMap` changes
above, built, tested (unit tests for both trigger paths and the "safe representative" skip logic,
plus the real end-to-end capstone CLI test now exercising the real oracle for the first time), full
suite green (173/173, `swift test -c release`), verified non-flaky across three consecutive runs.

**Phase D's report-layer surfacing (`DotWriter`/`MermaidWriter` styling for `isUnknown` edges —
gray, dashed, distinct from the risk-color scheme, plus `AnalysisEdge`'s backward-compatible
`Codable` round-trip) had no open decision to record on its own** — the `isUnknown`
field/`AnalysisReportBuilder` threading/`highRiskBoundaries` exclusion were already built as part
of this phase (required to make the capstone test's new, more complete picture coherent at all).
Only the two writers' visual styling remained, done here: 177/177 passing. `README.md` updated for
the `swift test -c release` requirement, now doubly justified (`sourcekitdInProc` is a second
C-interop dlopen dependency alongside `IndexStoreDB`).
