# Amendments to `task-oracle-query-concurrency.md` (revised version, post-§2.5 review)

Status: three small, non-blocking amendments to the revised task, offered after reading its §2.5
review of `oracle-concurrency-research-response.md`. None of them changes the task's hard
constraint, its hypothesis ranking, or any correctness gate — they tighten the instrument's
wording and add two nearly-free measurements the review's own `strings -a` findings made possible.
The rest of the revised task stands as written; in particular, the re-ranking (hypothesis 0 ships
first unconditionally), the adopted `key.cancel_on_subsequent_request: 0` hard rule, the
subprocess-only shape of hypothesis 2, and DoD 3's split between *running* the spike
(unconditional) and *acting* on it (conditional on the instrument) are all endorsed without
change.

---

## Amendment 1 — DoD 2 wording: the statistics counters are cumulative; the instrument is a subtraction of snapshots

`source.statistic.num-ast-builds` / `num-ast-cache-hits` (and the rest of the
`source.statistic.*` family the §2.5 strings pass confirmed) are session-lifetime cumulative
counters, not per-phase ones. DoD 2 currently says the instrument "captures
`source.statistic.num-ast-builds` / `num-ast-cache-hits` before and after the oracle phase" —
correct in spirit, but worth making the arithmetic explicit so the diagnostic run can't be
misread:

> The instrument is **(snapshot after oracle phase) − (snapshot before oracle phase)**, per
> counter, from two `source.request.statistics` requests issued through the same session the
> oracle uses. Absolute counter values are meaningless in isolation.

One supporting fact worth recording alongside it, because it's what makes the subtraction clean:
**the external-isolation oracle is the sole in-process consumer of sourcekitd in this codebase** —
the bulk symbol-graph extraction phase runs as `swift-symbolgraph-extract` subprocesses
(`BulkSymbolGraphExtractor`), not through the dlopen'd `sourcekitdInProc` session. So the deltas
measured between the two snapshots are attributable to oracle queries alone, with no
cross-contamination from any other phase. If that ever changes (some future phase starts issuing
in-process sourcekitd requests), this attribution assumption breaks and the instrument's wording
should be revisited — one sentence in the decision record guards against that silently rotting.

## Amendment 2 — §3.5 hazard 4 gets its own confirmed instrument: log `max-asts-in-memory` in the same snapshots

The §2.5 strings pass confirmed two UIDs the original response did not name:
`source.statistic.num-asts-in-memory` and `source.statistic.max-asts-in-memory`. The second one
is a direct, zero-cost instrument for exactly the memory-pressure hazard §3.5 item 4 describes
(cost-based `ASTCache` eviction making more workers/threads net-slower). Amend the instrument
step (§2.5 adopted step 4 / DoD 2) to include it in the same before/after snapshots:

- **If `max-asts-in-memory` comes back small (low single digits) on the real `Project Iris` run**,
  eviction pressure is already high under today's *sequential* load: ordering (hypothesis 0)
  matters even more than the base case suggests (evicted ASTs are being rebuilt for files the run
  will revisit), and any hypothesis-2 worker count must start small — each worker's private cache
  will be at least as pressured as today's single one, times K on total RSS.
- **If it comes back comfortably large**, the cache is holding what it's asked to hold, and the
  `num-ast-builds` vs distinct-file-count ratio from Amendment 1 becomes the sole deciding signal
  for hypothesis 0's expected payoff, uncomplicated by eviction.

Either way the number goes into the decision record next to the K-sweep curve §3.5 item 4 already
mandates, so the "more workers was slower" outcome — if it occurs — arrives with its explanation
attached instead of as a mystery.

## Amendment 3 — a smoke test pins the statistics response shape before the diagnostic run depends on it

The strings pass proves the UIDs exist in the binary; it does not prove the response dictionary's
shape (which keys arrive, under what nesting, as what value types) — that's the same
strings-vs-control-flow epistemic line §2.5 itself draws, applied to the instrument rather than
the AST queue. Before the diagnostic `Project Iris` run is built on top of `source.request.statistics`,
add one trivial unit-level smoke test through the existing `SourceKitDClient`:

> Issue a single `source.request.statistics` request against the live session; assert the
> response contains entries for (at minimum) `source.statistic.num-ast-builds` and
> `source.statistic.num-ast-cache-hits` with integer values; log the full response once so the
> actual shape is captured in the test output.

Cost is minutes; it de-risks the diagnostic run's parsing code the same way the fourth-addendum
harness de-risked live queries (and, per that precedent, is exactly where a surprise like the
index `-1` array rule would surface — in a disposable test, not mid-way through a 30-minute real
run). If the smoke test reveals the statistics request needs anything unexpected (a semantic
editor precondition, a different key spelling on this toolchain), that's a cheap finding now
versus a confusing one later.

---

## Closing note (not an amendment): the spike already contains the control-flow falsifier

§2.5 correctly observes that string presence cannot confirm the response's control-flow narrative
("every build, regardless of file, runs on the one serial queue"). For the record: the
micro-spike's own prediction P1 already includes the live falsification instrument for exactly
that claim — a `sample` capture **during concurrent issuance**. If genuinely concurrent cross-file
load ever shows two `sourcekit.swift.ASTBuilding`-labeled threads building simultaneously, the
§1.1 narrative is falsified on the spot, with no swift-repo checkout required; if it shows one,
the narrative is confirmed against the real binary under the real load pattern this task cares
about. No task text change needed — DoD 3 already mandates the spike — this note just makes
explicit that the spike answers the review's one open epistemic gap, so the decision record can
say so in one sentence.
