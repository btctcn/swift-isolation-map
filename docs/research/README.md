# Research thread — how the compiled-dependency oracle actually got designed

These documents are the real research/review paper trail behind three major efforts: resolving
isolation for symbols from compiled dependencies (the external-isolation oracle), the Gap A/Gap B
linker fixes, extension-of-external-type isolation, and the oracle query-concurrency
investigation. They're kept close to as-written (only redacted for the private validation
project's name — see `../reference-project-corpora.md`), not summarized, because several contain
methodology lessons and source citations that a summary would lose.

Read in order — each responds to the one(s) before it:

1. **`01-solution-compiled-dependency-isolation.md`** — proposed solution for
   `../task-compiled-dependency-isolation.md`, written from `swiftlang/swift` source alone (no
   macOS toolchain access), recommending `symbolgraph-extract` as the primary oracle.
2. **`../compiled-dependency-isolation-sourcekit-lsp-spike.md`** *(already in `docs/`)* — the
   on-machine spike that empirically refuted part of document 1's "inferred-isolation trap" claim.
3. **`02-design-deltas-after-crosscheck.md`** — traces the refutation to its exact compiler
   mechanism (`addAttributesForActorIsolation`), converting an empirical observation into a
   documented, load-bearing compiler contract.
4. **`03-research-phase-closure-usr-matching.md`** — closes the research phase; establishes the
   binding requirement that oracle results must be matched by USR, never by text. Contains a real
   methodology lesson: a grep match was read without its surrounding condition, confirming a wrong
   conclusion as convincingly as the full source would have refuted it.
5. **`04-cursorinfo-oneshot-preverification.md`** — confirms the exact `cursorinfo` one-shot
   request/response shape in SourceKit source before the dlopen spike, including the
   `"::SYNTHESIZED::"` USR-suffix nuance.
6. **`05-task-compiled-dependency-isolation-integration.md`** — the integration task spec that
   became Priority 3, Phases A-F (`../priority-3-phase-a-compiler-args.md` through
   `../priority-3-phase-e-fixtures.md`).
7. **`06-performance-research-response.md`** — reframes the performance problem as query *count*,
   not per-query latency; identifies the `@`-extension symbol-graph-file gap that was silently
   defeating the original motivating bug's own fix.
8. **`07-usr-granularity-research-response.md`** — Gap A (`.accessorOf` index relation) and Gap B's
   ranked hypotheses, both verified against real `indexstore-db`/`swiftlang/indexstore-db` source.
9. **`08-gap-b-research-response.md`** — the `.baseOf`/`occurrences(relatedToUSR:roles:)` index
   primitive that resolves both Gap B's external and local halves at once.
10. **`09-gap-b-plan-review.md`** — four corrections to the Gap B implementation plan, the most
    consequential being that per-member conformance copies (not just the nominal type) must all be
    rewritten, or the fix misses exactly where the corpus's mass is.
11. **`10-external-extension-isolation-research-response.md`** — the relation-chain variant
    (member → extension → extended type, all via index relations) that fixes extension-of-external-
    type isolation with zero `SyntaxAnalysis` changes; also flags the mirror-image false-negative
    risk (extension-level `@MainActor`/`nonisolated` propagation).
12. **`11-external-extension-task-amendments.md`** — closes the verification set; the grouping-step
    amendment (memoize per extension, never per shared bare-name placeholder) is the one that
    guards the fix's core correctness property.
13. **`12-oracle-concurrency-research-response.md`** — **the original source of the finding that
    `sourcekitd` serializes all AST building through one process-wide serial queue
    (`ASTBuildQueue`)**, regardless of client-side concurrency, plus the `cancel_on_subsequent_request`
    implicit-cancellation hazard. Written *before* any spike code, from source citations alone.
    This is the same finding independently re-confirmed against source a second time during the
    2026-07-29 concurrency spike (`../task-oracle-query-concurrency.md` §3/§7) — the decision
    record should (and now does) credit this document as the original source, not the later spike.
14. **`13-oracle-concurrency-task-amendments.md`** — tightens the `source.request.statistics`
    instrument's wording (cumulative counters, snapshot subtraction) and adds a memory-pressure
    measurement.
15. **`14-hypothesis-0-problem-4-investigation-plan.md`** and
    **`15-hypothesis-0-problem-4-closure-plan.md`** — the investigation/closure plans for the two
    real regressions hypothesis 0's own correctness gate surfaced (`MBPersistenceStorage`, a
    baseline bug; `PhotoServiceImpl`, a genuine new-code regression) — both closed, per
    `../priority-3-compiled-dependency-isolation.md` and `../task-oracle-query-concurrency.md`'s
    own decision records.
