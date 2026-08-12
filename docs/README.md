# Docs index

This directory accumulated a long, real research history (spikes, decision records, closed and
still-open tasks) with no single place tying it together. This file is that place: what the tool
actually does, how its pieces fit, and an accurate status for every other doc here — several of
those docs' own `**Status:**` headers are stale (written mid-task, never updated after the work
that closed them landed elsewhere), so treat the table below, not each doc's own header, as
current.

## What this tool does

`swift-isolation-map` statically analyzes a Swift project (Xcode project/workspace or SPM
package) for actor-isolation correctness: which types/functions are isolated to which actor, and
which cross-actor call sites are a real data-race risk under Swift's strict concurrency checking.
See `motivation.md` for why this can't just be "read the compiler's own diagnostics," and
`architecture.md` for the full original project specification (concept, differentiation from
Xcode Instruments, the rule-system-is-the-product principle, distribution, governance) — written
before implementation began and still the reference for "why this shape" on anything not covered
by a later decision record.

Every non-trivial claim in these docs was checked against real code, not synthetic fixtures —
mainly two real projects, described once in `reference-project-corpora.md` rather than repeated
(or leaked, in the private one's case) inline.

## The pipeline, end to end

```mermaid
flowchart TD
    A["CLI entry (SwiftIsolationMap.swift)<br/>resolve container: .xcodeproj / .xcworkspace / Package.swift"] --> B
    B["StalenessOrchestration<br/>find every Swift source file, check content-hash manifest"] --> C
    C["FileAnalyzer + SyntaxAnalysis<br/>per file: extract declarations, conformances,<br/>protocolGlobalActorNames, content hash"] --> E
    B --> D["IndexStoreLocator<br/>discover/build the real index store<br/>(xcodebuild / swift build under the hood)"]
    D --> DB["RawIndexStoreClient<br/>reads libIndexStore's raw C API directly over the built index"]
    DB --> E["DeclarationLinker (IndexStoreIntegration)<br/>links syntax facts to real USRs + builds the call graph"]
    E --> F["ExternalIsolationBackfill — 'the oracle'<br/>(see diagram below)"]
    F --> G["Merge: oracle results folded into the linked declarations"]
    G --> H["IsolationInferenceEngine<br/>(unmodified — a binding project constraint)<br/>rule-based isolation inference over declarations + call graph"]
    H --> I["AnalysisReportBuilder → OutputFormat<br/>mermaid / dot / json"]
```

`IsolationInferenceEngine` is deliberately never modified by any of the work in these docs — every
fix here works by giving it *better input facts* (via `DeclarationLinker` or the oracle), never by
changing its rules. See `isolation-rules.md` for the rule checklist itself.

## The oracle (`ExternalIsolationBackfill.resolve`)

`DeclarationLinker` can only resolve what the index store + syntax analysis already know. Two
real gaps remain after linking: a call into a type from a *compiled, external* dependency (a
CocoaPod, an XCFramework, an SPM binary target — no source, no index entry with useful isolation
info), and a project-local type's own superclass/protocol conformance pointing at such an external
type. The oracle backfills both, real query at a time, only when the fast paths can't already
answer:

```mermaid
flowchart TD
    T1["Edge-level trigger:<br/>a call site whose callee resolves into external code"] --> M
    T2["Declaration-level trigger:<br/>an unresolved syntactic: superclass/conformance placeholder"] --> M
    M["Merge + deterministically sort<br/>(file-adjacent order — hypothesis 0;<br/>USR tie-break for same-location edges)"] --> BC
    BC{"Bulk symbol-graph cache hit?<br/>(BulkSymbolGraphExtractor,<br/>one swift symbolgraph-extract<br/>per external module, cached)"}
    BC -- yes --> AP["Apply outcome directly, no live query"]
    BC -- no --> LQ["Live query: SourceKitDClient.cursorInfo<br/>against sourcekitdInProc, one real AST build<br/>(sequential — see hypothesis 1 below)"]
    LQ --> AP
    AP --> R["Backfilled/updated declarations + conformance pairs,<br/>fed back into the merge step in the pipeline diagram above"]
```

The file-adjacent sort order (hypothesis 0 — `hypothesis-0-file-sorted-oracle-queries.md`) and the
sequential-only issuance decision (hypothesis 1) are both real, measured findings — not
assumptions — see the status table below for where each is written up.

## Status of every other doc here

| Doc | What it is | Real current status |
|---|---|---|
| `architecture.md` | The original, pre-implementation project specification | Foundational, kept as-written. Its own "What's changed since this was written" preface (added after a 2026-07-29 audit) lists six concrete gaps — most notably, the external-isolation oracle (arguably the project's largest subsystem) isn't in it at all |
| `motivation.md` | Why this tool exists at all | Foundational, not a task — always current |
| `isolation-rules.md` | Checklist of every isolation-inference rule `IsolationInferenceEngine` implements, plus the runbook for reviewing and adding support for a new Swift version (triggered by `swift-version-watch.yml`) | Living document, updated as rules/versions are added — always current |
| `reference-project-corpora.md` | The two real validation projects (Project Iris, private; SQLumen, public) | Reference doc, added this session |
| `external-dependency-boundaries.md` | How isolation resolution actually treats Pods, SPM, and linked libraries — two mechanisms, not three, and which one applies depends on source availability, not dependency type. Also settles why issue #33 is structurally scoped to source we parse ourselves | Foundational reference doc — always current, cross-references the pipeline/oracle diagrams above rather than duplicating them |
| `research/` | The real research/review paper trail behind the compiled-dependency oracle, Gap A/B, extension-of-external-type isolation, and oracle concurrency — 15 documents, chronological, see `research/README.md` | Historical record, kept close to as-written (redacted for the private project's name only) |
| `priority-2-phase-0-spike.md` | IndexStoreDB dependency de-risking spike | **Closed** — shipped, part of Priority 2 |
| `priority-2-phase-3-linking.md` | USR/location linking decision record | **Closed** — shipped, part of Priority 2 |
| `priority-2-phase-4-cli-wiring.md` | End-to-end CLI wiring, closing Priority 2 | **Closed** — Priority 2 fully shipped |
| `task-compiled-dependency-isolation.md` | Original correctness task (Phases A-F) | **Closed** — own header says "not started," stale; superseded by `priority-3-compiled-dependency-isolation.md` |
| `priority-3-phase-a-compiler-args.md` | Real per-file compiler args, decision record | **Closed** — folded into Priority 3 |
| `priority-3-phase-b-sourcekitd-client.md` | `sourcekitdInProc` client concurrency-model decision | **Closed** — folded into Priority 3 (superseded/re-litigated by hypothesis 1, `task-oracle-query-concurrency.md`) |
| `priority-3-phase-c-oracle-triggers.md` | Oracle trigger sources, decision record | **Closed** — folded into Priority 3 |
| `priority-3-phase-e-fixtures.md` | Golden fixture matrix, decision record | **Closed** — folded into Priority 3 |
| `compiled-dependency-isolation-sourcekit-lsp-spike.md` | `sourcekit-lsp`-as-alternative de-risking spike | **Closed** — de-risking done, informed Phase B's decision |
| `task-compiled-dependency-isolation-performance.md` | Performance task spec (Phases G1-G6) | **Closed** — own header says "not started," stale; superseded by `priority-3-compiled-dependency-isolation.md` |
| `task-compiled-dependency-isolation-usr-granularity.md` | Gap A (accessor USR mismatch) fix + Gap B scoping | **Closed** — Gap A shipped; Gap B superseded by the two docs below, then closed |
| `task-gap-b-implementation-plan.md` | Gap B implementation plan | **Closed** — own header says "plan for review," stale; implemented, result in `priority-3-compiled-dependency-isolation.md`'s Gap B section |
| `task-gap-b-declaration-linker-real-scale.md` | Gap B problem statement | **Closed** — same as above |
| `priority-3-compiled-dependency-isolation.md` | Master closing doc for all of Priority 3 (correctness, performance, Gap A, Gap B) | **Closed** — the authoritative final status for everything it references |
| `task-pods-in-scope-research.md` | Should `Pods`/`Carthage` sources stay in scope? | **Open** — genuinely deferred, a product decision, not yet made |
| `task-external-type-extension-isolation.md` | Extensions of external `@MainActor` types falsely flagged | **Closed** — shipped this session, own header accurate |
| `task-cross-file-type-entry-collision.md` | Cross-file type-entry collision bug | **Closed** — shipped this session, own header accurate |
| `task-oracle-query-concurrency.md` | Hypothesis 0 (query ordering) + hypothesis 1 (concurrent issuance) — the full task + exhaustive decision record | **Closed** — own header says "not yet designed," stale. Hypothesis 0 shipped (PR #15, ~33% faster; see `hypothesis-0-file-sorted-oracle-queries.md` for the readable summary). Hypothesis 1 closed (§7.7) as "don't build": `sourcekitd`'s own `ASTBuildQueue` serializes all AST building process-wide regardless of client concurrency — originally established in `research/12-oracle-concurrency-research-response.md` *before* any spike code, independently reconfirmed against source during closure. `cancel_on_subsequent_request:0` reverted out of production code (only ever needed for the rejected concurrent path) |
| `hypothesis-0-file-sorted-oracle-queries.md` | Standalone summary of hypothesis 0 — what shipped, why, the numbers | **Closed** — shipped, PR #15. Added 2026-07-30 so every other mention of "hypothesis 0" has one clear place to link to instead of the full decision record |
| `retrospective-oracle-query-location.md` | Retrospective on hypothesis 0's own query-location bugs | Closed narrative — always current as a record of what happened |
| `task-default-isolation-detection.md` | SE-0466's `-default-isolation` value is never read from the real project — always resolves `nonisolated` ([issue #30](https://github.com/btctcn/swift-isolation-map/issues/30)) | **Closed** — fixed and shipped (PR #31), verified end-to-end for the SwiftPM path with a real fixture + regression test. The Xcode path uses the same detection code and provider abstraction but was never separately live-spiked against a real `.xcodeproj` — a real, acknowledged residual gap, not assumed equivalent |
| `task-baseof-duplicate-occurrence-collision.md` | Real-world audit against Project Iris: a `DeclarationLinker` bug (duplicate `.baseOf` occurrence wrongly treated as a name collision, silently under-reporting risk) and a known closure-attribution false-positive gap | Bug **fixed**, verified against Project Iris's own real index store + new unit test. Closure-attribution gap documented, **not fixed** — real feature work, out of scope for this pass |
| `task-process-tree-optimization.md` | Parallelize the external-oracle live-query phase (97.6% of real oracle wall-clock) across processes via a new opt-in `--oracle-workers <N>` flag | **Closed** — shipped. Real full-scale Project Iris run: ~1.84× speedup with 4 workers, byte-identical results to sequential (51,087/51,087 nodes, 55,042/55,042 edges). Along the way, found and fixed two real, pre-existing-infrastructure deadlocks in `LiveProcessRunner` (a `Process`/`Pipe` buffer deadlock, then a `DispatchQueue.global()` cooperative-pool-exhaustion deadlock in the first fix's own fix) — both benefit every caller of `ProcessRunning`, not just oracle workers |
| `task-oracle-chunk-balancing.md` | Oracle worker chunks were balanced by item count, not real cost — 5.08× distinct-file-count spread across 8 chunks on Project Iris ([issue #35](https://github.com/btctcn/swift-isolation-map/issues/35)) | **Closed** — shipped. Balancing by distinct file count instead cut the spread to 1.02×; real live-query phase improved 240.1s → 211.5s (~12%, more modest than the balance numbers alone suggest — item count is uneven by design, and each query still carries real fixed per-item cost). Byte-identical to the sequential baseline |
| `task-closure-isolation-attribution.md` | A call inside an isolated closure literal (`Task { @MainActor in }`, `DispatchQueue.main.async`) was misattributed to its enclosing declaration's own isolation, a real false-positive source first found auditing Project Iris ([issue #33](https://github.com/btctcn/swift-isolation-map/issues/33)) | **Closed** — Rules A (accept-list-validated closure-signature attributes) and B (the `DispatchQueue.main` SDK special case) shipped; real-corpus gate against Project Iris: exactly 7 app-code high-risk false positives disappeared, 0 appeared, every retained edge byte-identical. Rule C (the mirror, de-isolating direction) deferred to [issue #41](https://github.com/btctcn/swift-isolation-map/issues/41) (zero measured real-corpus occurrences); resolving accept-list names declared in compiled dependencies deferred to [issue #40](https://github.com/btctcn/swift-isolation-map/issues/40) (same reason) |
| `task-bulk-symbolgraph-inherited-isolation.md` | The external oracle's bulk symbol-graph cache silently resolved any UIKit/AppKit member whose only isolation source is class inheritance as `.nonisolated` -- `symbolgraph-extract` never restates a class's isolation on each inherited member, unlike a live per-declaration query ([issue #44](https://github.com/btctcn/swift-isolation-map/issues/44)) | **Closed** — shipped. Found auditing #33's own real-corpus gate results, unrelated to that fix. Real-corpus re-run against Project Iris: app-code high-risk boundaries went from 228 to 792 (+564), zero disappeared -- the single largest real-world-impact fix found this session |
| `task-indexstore-declaration-completeness.md` | `IndexStoreDB` silently drops a real fraction (803 declarations measured) of a large project's own declarations under full-project load -- resolves correctly in isolation, absent from the final linked result at full scale ([issue #51](https://github.com/btctcn/swift-isolation-map/issues/51)) | **Closed** — mitigation shipped. Root cause not fully isolated (traced to `IndexStoreDB`'s own async/eventually-consistent initialization design, not this project's code); 5 minimal-reproduction attempts all failed, so no upstream report was filed. Extended the existing bulk-then-live-fallback pattern to the project's own declarations (`DeclarationLinker.unresolvedPlaceholders`/`link(_:usrRewriteMapOverrides:)`, `LocalDeclarationLiveFallback`), parallelized across `--oracle-workers` processes (10954 real unresolved placeholders made the sequential path impractical -- 15+ minutes and still running). Real-corpus re-run against Project Iris: the 803 missing declarations dropped to 401, `highRiskBoundaries` rose 853 → 933 (+80) — previously-hidden real risk surfaced, not new noise. The remaining 401 split into two distinct causes, see `task-protocol-requirement-usr-collision.md` below for one of them |
| `task-protocol-requirement-usr-collision.md` | Protocol requirement placeholder USRs collide across unrelated files -- `DeclarationVisitor` has no type-scope for `protocol`, so a requirement's USR discriminator is a bare byte offset, unique only within one file ([issue #53](https://github.com/btctcn/swift-isolation-map/issues/53)) | **Closed** — shipped. Found continuing #51's "401 remaining" follow-up; not `IndexStoreDB` instability at all, a real deterministic bug in this project's own `SyntaxAnalysis` extraction, common with copy-pasted VIPER-style router/view-input protocols (identical boilerplate headers put same-named requirements at identical byte offsets). Real-corpus re-run against Project Iris: total linked declarations 46873 → 47126 (+253), the 401 missing declarations dropped to 361 (-40) |
| `task-implicit-synthesized-declarations.md` | 84% of the remaining 361 missing declarations (default `init()`, `deinit`, `rawValue`/`allCases` accessors) are compiler-synthesized -- no `SwiftSyntax` node exists for them in source text at all ([issue #55](https://github.com/btctcn/swift-isolation-map/issues/55)) | **Documented as a structural limitation, not fixed.** A real fix would mean independently re-deriving the compiler's own synthesis-eligibility rules inside this tool -- judged not worth the false-positive/negative risk for a declaration class that measured zero would-be-high-risk edges on Project Iris. Call sites into these declarations degrade safely to `unspecified` isolation. Also documents a related-but-distinct, still-open sub-finding: bare protocol names (e.g. `Disposable`) extract with `location: nil` for a third, separate reason |
| `task-protocol-own-declaration-location.md` | A protocol's own type-level declaration gets `location: nil` when a same-file default-implementation extension is the only thing that ever creates its `typeIndex` entry -- `TypeIndexBuilder.Visitor` never called `recordPrimaryDeclaration` for `protocol` ([issue #57](https://github.com/btctcn/swift-isolation-map/issues/57)) | **Closed** — shipped. Found continuing #55's Step 6; a third, distinct consequence of the same "protocol has no type-scope" root fact #53 documented, but this one had a real fix (the location was always present in source, just never read). `TypeIndexBuilder.Visitor.visit(_ node: ProtocolDeclSyntax)` now also calls `recordPrimaryDeclaration`, mirroring struct/enum |
| `task-low-risk-same-domain-explanation.md` | `.low` risk explanation always claims "compiler-enforced via await", even for two endpoints in the exact same isolation domain that need no suspension at all ([issue #47](https://github.com/btctcn/swift-isolation-map/issues/47)) | **Closed** — shipped. All 16 real `.low` app-code edges with identical caller/callee isolation are `globalActor(MainActor) -> globalActor(MainActor)`, verified to have no `await` at their call sites. Fix scoped to `.globalActor` only (singleton semantics guarantee "same name = same domain"); `.actor` pairs keep the existing wording since this tool has no actor-instance-identity tracking. Presentation-only -- no risk level or edge count changes |
| `task-await-aware-risk-classification.md` | `riskLevel`/`crossIsolationEdges` are blind to `await` -- a correctly-`await`ed `nonisolated`-caller call into isolated state was classified identically to the same call with no `await` at all ([issue #46](https://github.com/btctcn/swift-isolation-map/issues/46)) | **Closed** — shipped as a new, purely informational `isAwaited` field on `AnalysisEdge`, *not* a `risk` change. The issue's own original proposal (downgrade an awaited `.high` edge to `.low`) was implemented first, found to directly contradict this project's own real golden-fixture ground truth (`CompiledDependencyCLITests.swift`'s Mechanism A: a real, compiling, already-awaited call is deliberately still `.high` -- it tracks migration debt, not just unguarded races), and reverted in favor of the scoped-down design |
| `task-deinit-extraction-gap.md` | An explicit `deinit` was never extracted as a declaration at all -- `DeclarationVisitor` had no `visit(_ node: DeinitializerDeclSyntax)` override, so every deinit's caller isolation silently resolved `unspecified` ([issue #48](https://github.com/btctcn/swift-isolation-map/issues/48)) | **Closed** — shipped. The issue's own original hypothesis (`IndexStoreDB` reporting two different USRs for the same `@objc`-visible override) was disproven by a direct probe against the real index store -- definition and call-site agreed on the identical USR. Real root cause: a plain missing `SwiftSyntax` visitor override, the same category as #53 but for `deinit`. Real-corpus re-run: `crossActorBoundaries` 24852 → 24801 (-51), `unspecifiedIsolation` 1501 → 1458 (-43), `highRiskBoundaries` unchanged (real noise removed, not risk hidden) |
| `task-raw-indexstore-spike.md` | Scoped spike (issue #51): does bypassing `IndexStoreDB`'s async/LMDB layer via `libIndexStore`'s raw C API fix the declaration-loss root cause? | **Shipped, but not for the original reason.** The hypothesis didn't hold (295 vs. 296 missing declarations in a controlled A/B -- noise). Investigating a real ~13% call-graph edge disagreement instead surfaced a bigger, separate `IndexStoreDB` gap: `symbolOccurrences(inFilePath:)` silently drops occurrences from every target but one, for a file compiled into more than one (an app + its extensions -- Project Iris's own real shape; one file alone: 72 → 216 declarations). Confirmed with a minimal, two-`swiftc`-invocation, project-independent reproduction, filed as [swiftlang/indexstore-db#292](https://github.com/swiftlang/indexstore-db/issues/292). `RawIndexStoreClient` (`Sources/CIndexStoreRaw/`, `Sources/IndexStoreIntegration/RawIndexStoreClient.swift`) now replaces `IndexStoreClient` as the default index reader -- a real regression (an ObjC property/setter USR canonicated incorrectly) was found and fixed along the way, caught by the existing golden-fixture test suite. **Bonus finding**: re-running issue #49's own dirty-vs-clean-DerivedData experiment with the new client found *zero* edge-set difference (was 8588/5736 out of ~44-48k with `IndexStoreDB`) -- see #49's own follow-up comment |
