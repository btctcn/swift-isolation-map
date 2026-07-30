# Retrospective: hypothesis 0's query-location bugs, and what the chase actually taught us

Written after `docs/task-oracle-query-concurrency.md`'s decision record (§7) closed. That document
records *what was decided*; this one is the narrative — the false leads, the near-misses, and the
methodology lessons they forced, kept here so a future contributor touching this same code doesn't
have to rediscover them the hard way. Not required reading to use or maintain the tool; useful if
you're about to change how `ExternalIsolationBackfill` picks a query location or representative,
or if a future correctness-gate diff produces a discrepancy and you're tempted to trust the first
plausible explanation. See `docs/hypothesis-0-file-sorted-oracle-queries.md` for what hypothesis 0
*is*, if you're not already familiar with it.

## The setup

Hypothesis 0's whole premise was almost embarrassingly simple: collect every oracle query the
analysis needs, sort them by `(file, line, column)`, run them in that order instead of whatever
order call-graph/declaration-table iteration happened to produce. A real diagnostic measurement
had already shown this was worth doing — 4780 AST rebuilds against 4825 queries, essentially zero
cache reuse. Sorting queries so nearby ones share a file should let `sourcekitd`'s own AST cache
actually do its job.

Implementing "sort the queries" turned out to require a surprising amount of getting query
*ordering itself* wrong in four different, unrelated ways, each caught only because a correctness
gate was run against a real, large project and its output diffed byte-for-byte against a known-good
baseline — never because the bug was visible in code review or in the project's existing unit
tests.

## The chain, in the order it actually happened

**Fix attempt 1** merged the two trigger kinds (call-graph edges, declaration-level
superclass/conformance needs) into one sorted list — but kept picking, for a shared conformance
pair, "the type's own declaration always claims it, never a member." This looked reasonable: a
type's own declaration is one canonical place to ask "what's this type's isolation." It fixed
nothing yet because it hadn't been run against real data.

**A real `Project Iris` gate run found `PhotoServiceImpl` regressed** — baseline said `@MainActor`
(correctly: its conformance to `PHPickerViewControllerDelegate` is declared in a separate
extension), the new code said `nonisolated`. The type's own primary-declaration line, hovered
directly, doesn't reflect a conformance added later via a different `extension` block. Confirmed
with real `swiftc`, not by reading the parser and guessing.

**Fix attempt 2** flipped the rule: a type's own entry *never* claims a conformance pair inline;
a member always gets first refusal, the type's own entry only claims a pair as a last resort if no
member does. This fixed `PhotoServiceImpl` — the extension's own member became the query point, and
that member's location does reflect the whole type's resolved isolation, because typechecking a
member's body always needs the type's fully-resolved isolation anyway.

**A second real `Project Iris` run found `KFImageRenderer` newly regressed** — the *opposite* shape.
`KFImageRenderer` conforms to `View` directly on its primary declaration, no extension involved. Fix
attempt 2's rule handed the claim to a member (`binder`, a `@StateObject`-attributed property)
instead of the type's own line — and that member's own hover answer came back
`globalActor(name: "StateObject")`, a fabricated fact: neither of this project's two isolation
parsers checked that an attribute naming a real, resolvable type is actually a *global actor* type,
as opposed to, say, a SwiftUI property wrapper that merely also resolves to a real struct via USR.

At this point the investigation had two regressions with genuinely incompatible fixes ("the type
wins" fixes one, breaks the other; "a member wins" fixes the other, breaks the first) plus a
freshly-discovered, unrelated parser bug — and, separately, a family of `.init()` nodes
(`MindboxSDKInitializer` and four others) that flickered between resolved and `unspecified` across
repeated runs of the *identical* binary. That flicker was, for a while, wrongly attributed to
whichever conformance-pair fix was in flight at the time, because it appeared in the same gate
diffs. It had nothing to do with conformance pairs at all — it was the **edge-level** trigger's own
dedup picking a different call-site representative each run, because `linked.callGraph`'s iteration
order (ultimately traced to `IndexStoreDB` occurrence enumeration) isn't guaranteed stable across
process launches. A completely separate code path, discovered only by deliberately running the
same binary twice and diffing the two outputs against each other — not against baseline.

**Fix attempt 3 (the one that shipped)** replaced "type vs. member" with the actual distinguishing
signal that had been sitting in the data the whole time:
`ProtocolConformance.declaredInSameContextAsWitness` — true for a declaration whose own copy of a
conformance was witnessed inside the exact same syntactic construct (primary body, or a specific
extension) that introduces it. `PhotoServiceImpl`'s witnessing member has it; `KFImageRenderer`'s
witnessing member has it too (its conformance is on the primary body, and `binder` lives inside
that same body). The type's own entry never has it (a separate, project-wide extraction rule). One
criterion, both shapes, no more type-vs-member dichotomy to get backwards. The parser bug (§ above)
was fixed independently, as its own, orthogonal positive-validation check.

Separately, the edge-level flicker got its own fix: the canonical representative for a shared
callee is now the lexicographically-smallest `(file, line, column)` among every edge referencing
it — a pure function of the *set* of edges, computed without ever consulting iteration order.

**Then arbitrating those `.init()` answers against real `swiftc` nearly produced a false
accusation.** The oracle said `MindboxSDKInitializer.init()` was `@MainActor`-isolated; a real
`swiftc -typecheck -swift-version 6` compile of the whole module, calling all five constructors
from a nonisolated context, raised no diagnostic for any of them — looking exactly like the oracle
had fabricated an answer, matching this investigation's established pattern of the gate exposing
real bugs. It was about to be written up that way. It was wrong, and it was only caught because the
arbitration was, out of habit at this point, re-run at a *second* language mode before being
trusted: `-swift-version 5` — the real build's actual mode, not an assumed one — raised a hard
compile error for exactly that one constructor. SE-0411's synthesized-init exemption from
global-actor inheritance is itself gated to Swift 6 language mode; under 5, the class's `@MainActor`
propagates to its synthesized init unconditionally. The oracle had been right all along, in the
language mode it was actually asked in. The near-miss produced this project's own binding rule
going forward: an arbiter must run at the same language mode the oracle's query used, or the
comparison isn't valid — checking only one mode when the two differ is not a shortcut, it's exactly
this mistake.

**A final, narrower non-determinism** turned up after all of the above, from the cheapest possible
tool: dumping the fully-planned, sorted query list and diffing it against itself across two runs,
with zero live queries involved. Two distinct USRs sharing one exact `(file, line, column)` (a
synthesized property getter and its setter counterpart at the same call-site token, a real shape on
`Project Iris`) had their relative order decided by `Dictionary` iteration order, unstable across process
launches, because the sort key was location alone. A `targetUSR`/`usr` tie-breaker closed it. This
is the fix that most directly validates keeping the plan-dump tool around permanently: it caught a
real bug in minutes, without a single `sourcekitd` round trip, before it could ever reach an
expensive real-corpus gate run.

## Three methodology lessons, confirmed twice each, not assumed once

1. **A correctness-gate diff localizes a discrepancy; it does not say which side is wrong.**
   Confirmed by problem 4a (`MBPersistenceStorage`): the "regression" was the new code
   *accidentally* fixing a baseline that had been wrong all along, discovered only by checking
   real `swiftc`, not by assuming the newer code was the buggy side. Confirmed again by the
   `MindboxSDKInitializer` near-miss above, in the opposite direction: the diff pointed at the new
   code, and the new code was right. Every non-trivial diff in this investigation was arbitrated by
   a real compile, never settled by re-reading the diff itself.
2. **An arbiter must match the oracle's own conditions, not just exist.** Getting the right answer
   from `swiftc` still isn't enough if it's compiled in the wrong language mode, the wrong SDK, or
   a hand-simplified reduction that drops the real property/conformance shape being checked. Two
   separate, unrelated bugs in this investigation (the language-mode near-miss; an earlier,
   unrelated arbitration attempt that briefly used a hand-written reduction instead of the real
   project's own build arguments) trace to the same root mistake: trusting an arbiter's *result*
   without first confirming it was asked the *same question* the oracle was asked.
3. **A repeat run tests stability, not correctness — and a stable answer isn't automatically the
   right one.** Two runs of the identical binary agreeing with each other proves the run is
   deterministic; it says nothing about whether the agreed-upon answer is correct (a bug can
   reproduce as reliably as a fix). Conversely, three runs each landing on a *different* answer for
   the same declaration is not "noisy but roughly fine" — it is direct, load-bearing evidence that
   something in the query-planning pipeline depends on unordered iteration, worth chasing to a real
   fix (the edge-level canonical representative, then the tie-breaker) rather than averaged away or
   attributed to "sourcekitd flakiness" and left alone.

## What actually closed the gate

- `declaredInSameContextAsWitness`-based conformance-pair claim, replacing every earlier
  type-vs-member heuristic (`docs/task-oracle-query-concurrency.md` §7.1).
- Positive validation in both isolation parsers — an attribute names a global actor only after
  checking it isn't a known non-actor property wrapper, `MainActor`'s own USR aside (§7.2).
- Canonical, iteration-order-independent representative for shared edge-level callees, plus a
  `targetUSR`/`usr` tie-breaker for the rare case where two distinct targets share one exact
  location (§7.3).
- An explicit, documented language-mode contract: this tool reports isolation as each module
  actually compiles today, in its own real `-swift-version`, never an assumed or hardcoded mode
  (§7.4; also in the README).
- Two permanent, cheap diagnostic instruments kept specifically because they each caught a real bug
  before an expensive real-corpus run had to: `SWIFT_ISOLATION_MAP_DUMP_MERGED_PLAN` and the
  "distinct live-query file groups" count inside `SWIFT_ISOLATION_MAP_ORACLE_STATS`.
- A real, measured wall-clock improvement (29:41 → 20:00, ≈33%) and the pre-registered acceptance
  signal it was gated on (`num-ast-builds` tracking distinct file count, not query count) actually
  passing, not just plausibly close (§7.6).
