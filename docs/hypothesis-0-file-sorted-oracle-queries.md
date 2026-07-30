# Hypothesis 0: file-sorted oracle query ordering (~33% faster, zero semantic change)

**Status: shipped** (PR #15, 2026-07-29). This is the readable, standalone summary of hypothesis
0 — what it is, why it works, what it cost to get right, and the real numbers. The exhaustive,
line-by-line decision record (every bug's full trace, every arbitration) lives in
`task-oracle-query-concurrency.md` §7.1–§7.6; this document doesn't repeat that detail, it
orients a reader who just wants to know what hypothesis 0 *is* before (or instead of) reading it.

## What it is

The external-isolation oracle (`ExternalIsolationBackfill.resolve`, see `docs/README.md`'s oracle
diagram) issues one real `sourcekitd` query per unresolved external USR, live, when the bulk
symbol-graph cache can't already answer. Before this change, those queries were issued in
whatever order the two trigger sources (edge-level call-graph traversal, declaration-level
superclass/conformance resolution) happened to produce — which, on a real ~2200-file project,
meant consecutive queries routinely landed on *different* files. `sourcekitd`'s own AST cache is
small (8 resident ASTs, confirmed via `max-asts-in-memory`), so file-hopping like this meant
almost every query paid a full, real AST rebuild: **4780 AST builds for 4825 requests — ~99%**,
essentially zero cache reuse.

Hypothesis 0: collect every query into one deduplicated work-item list *before* executing any of
them, sort that list by `(file, line, column)`, then execute the single merged, sorted list in one
pass. Consecutive queries then usually share a file, so each file's AST gets built once and reused
by every subsequent query into the same file, instead of being evicted and rebuilt on every hop.
Semantics are untouched by construction — same queries, same session, same sequential issuance,
only the *order* changes, and outcome application is itself order-independent (merged
deterministically by canonical key, not by completion/iteration order).

## Why it wasn't a simple reorder in practice

Getting this to actually pass the project's own byte-identical correctness gate against a real,
full project took three real, non-hypothetical bugs — each found *by* the gate itself, each
requiring a real `swiftc` compile to arbitrate, not reasoning alone (full traces:
`task-oracle-query-concurrency.md` §7.1–§7.3):

1. **Conformance-pair claim representative** (§7.1) — deduplicating a shared `(nominal, protocol)`
   conformance pair needs a *consistent* declaration to query it at, and neither "the type's own
   entry always wins" nor "a member always wins" is correct — two real, opposite-shape regressions
   on the real corpus proved it both ways. Fixed by picking the declaration whose own conformance
   copy is physically declared in the same context that introduces the conformance
   (`declaredInSameContextAsWitness`), already computed and just not used for this before.
2. **A latent parser bug it exposed** (§7.2) — once a previously-unreached member became a real
   claim candidate, a real bug in both isolation parsers surfaced: any attribute resolving to a
   real USR was accepted as naming a global actor, `@StateObject` included. Fixed with a positive
   validation (`GlobalActorNameValidation`), not a broader heuristic.
3. **Edge-level query-order non-determinism** (§7.3) — a small family of synthesized `.init()`
   declarations (no source location of their own) had their canonical representative decided by
   `Dictionary`/call-graph iteration order, not guaranteed stable across process launches — three
   identical-binary runs against the identical corpus gave three different answers. Fixed by
   making the representative a pure function of the *set* of edges (lexicographically-smallest
   location, with a USR tie-break for two distinct symbols sharing one exact location — a second,
   narrower instance of the same class of bug, caught by a cheap zero-live-query plan-dump diff
   before it ever reached a real gate run).

## A related discovery, not itself hypothesis 0's subject

Arbitrating one of §7.3's answers against real `swiftc` produced a wrong conclusion on the first
attempt — checked at only one Swift language mode when the real project's own build uses a
different one (full story: §7.4). This produced a binding, project-wide methodology rule (an
arbiter must run at the oracle's own real language mode) and a documented contract (this tool
reports isolation as each module actually compiles today, never a predicted future mode — see the
root `README.md`'s own "Language-mode contract" section). It's recorded here because it was found
during hypothesis 0's own gate work, not because it's specific to query ordering.

## The numbers

Measured on a release build, real full-corpus run, before/after `source.request.statistics`
snapshots plus manual wall-clock (full context: §7.6):

| Metric | Before | After |
|---|---|---|
| Wall-clock | 29:41 | **20:00 — ≈33% faster** |
| `num-ast-builds` | 4780 (~99% of requests) | **1764** |
| `num-ast-cache-hits` | 44 | **3029** |

The decisive, pre-registered acceptance signal: `num-ast-builds` should track the number of
*distinct files* reaching `sourcekitd` (1595), not the number of queries — `1764 / 1595 ≈ 1.11`,
builds now sit within ~11% of the theoretical minimum, a complete reversal from the pre-fix ~99%.

**Correctness**: real full-corpus per-node diff against baseline — 64 differences, every one
attributed (a baseline bug the gate incidentally caught, six real accuracy improvements, one
harmless artifact), zero unexplained residual. Two independent full runs of the shipped binary:
0 node diffs, identical summary counters.

## Where to go for more

- `task-oracle-query-concurrency.md` §7.1–§7.6 — the full decision record this document
  summarizes.
- `docs/retrospective-oracle-query-location.md` — what the *chase* itself taught, independent of
  the specific bugs (methodology, not mechanism).
- `docs/research/12-oracle-concurrency-research-response.md` and
  `docs/research/13-oracle-concurrency-task-amendments.md` — the research that predicted ordering
  would be the dominant fix (and correctly predicted concurrent issuance, hypothesis 1, would not
  be) before any of this was built.
- `docs/research/14-hypothesis-0-problem-4-investigation-plan.md` and
  `docs/research/15-hypothesis-0-problem-4-closure-plan.md` — the investigation plans for the two
  real regressions this hypothesis's own gate surfaced.
