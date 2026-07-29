# Problem 4 closure plan: verifying 4a's baseline mechanism, tracing 4b's regression

Status: implementer instructions, follow-up to `hypothesis-0-problem-4-investigation-plan.md`,
written against the updated `hypothesis-0-debugging-log.md` (4a closed by step 0, 4b opened).
The 4a *verdict* is settled and is not reopened here: the compiler said `nonisolated`, the
baseline was wrong, §5.4 applies, and the new code's own behavior is trace-confirmed correct.
What this plan covers is the part of 4a that is **not** settled — the mechanism of the
baseline's wrong answer, currently a conjecture — plus the open 4b regression, the unattributed
third single node, and one follow-up to file outside this task. Ordered by cost and by what
blocks the decision record.

---

## 1. Problem 4a: the mechanism is still a conjecture, and this particular conjecture must not enter the decision record unverified

The log currently attributes the baseline's wrong `globalActor(MBPersistenceStorage)` answer to
sourcekitd returning a different, incorrect result at the same declaration point, "probably
depending on AST-cache state at query time." Two independent reasons to treat that sentence as a
hypothesis to test, not a finding to record:

1. **It leaves the central clue unexplained.** The wrong answer's payload is the containing
   class's *own name*. A cursor-info hover on `class MBPersistenceStorage` has no source from
   which to produce an `@MBPersistenceStorage` global-actor attribution — sourcekitd reports
   attributes that exist (explicitly or as materialized inference) on the symbol; it cannot
   invent a global actor named after the queried class, under any cache state. A payload equal to
   a name string still points where it pointed from the start: at a **code path in the baseline
   that constructs the global-actor isolation case from a bare name string** (placeholder or
   syntactic attribute name) rather than from a resolved USR.
2. **If recorded as fact, it is a landmine under the whole gate.** "sourcekitd answers depend on
   AST-cache warmth" generalizes far beyond one family: it would mean *any* two differently
   ordered runs can legitimately disagree, i.e. the byte-identical gate is not well-defined in
   principle. A claim with that blast radius goes into the decision record only with direct
   evidence — or gets explicitly refuted and replaced by the actual mechanism.

Verification sequence, cheapest-first; stop at the first step that identifies the mechanism:

**1a. Finish step 4 of the investigation plan (the grep) — a desk check, do it first.** Enumerate
every construction site of the global-actor isolation case in the *pre-hypothesis-0* code (the
baseline revision, not the current tree — check out the baseline commit or diff against it), and
classify each by input provenance: resolved USR vs bare name string. Inspect any site reachable
from the superclass/containingType backfill path or the placeholder path. Expected outcome, for
pre-registration: **a reachable site exists that can take `MBPersistenceStorage` as a string** —
most plausibly somewhere in how the baseline handled the unresolved
`superclassUSR = s:7Mindbox18PersistenceStorageP` need or a `syntactic:MBPersistenceStorage…`
placeholder, given that fix 3's split did not exist yet and the old interleaved loop mixed both
need kinds. If found: reproduce it in a unit-scale fixture (feed the site the same inputs, assert
the bogus `globalActor(<name>)` comes out), and the mechanism section of 4a is closed cleanly —
sourcekitd exonerated, the conjecture deleted from the log, the fixture kept as documentation of
the baseline defect.

**1b. Only if the grep comes back genuinely empty: test sourcekitd answer stability directly.**
Same-session harness experiment (fourth-addendum harness, unchanged discipline): issue the
identical cursor-info request at the `MBPersistenceStorage` declaration point (a) cold, first
query of the session; (b) after warming N unrelated files' ASTs (enough to evict, given
`max-asts-in-memory: 8`); (c) repeated M times interleaved with unrelated queries. Byte-diff the
responses. Two possible outcomes, both actionable: **stable** → the cache-state conjecture is
refuted, the baseline mechanism is still in baseline *code*, return to 1a with wider scope (e.g.
response-parsing differences between old and new code for the same response); **unstable** → a
real, documented sourcekitd behavior constraint, which must then be characterized (which requests,
which conditions) and folded into the gate's definition explicitly — not left as a one-line
"probably."

**1c. Baseline self-identity, still outstanding (investigation plan step 3.2).** Run the
unmodified baseline binary twice on `Project Iris`, diff its outputs against themselves. This is now
doubly relevant: it bounds the cache-state conjecture from the reproducibility side (a baseline
that always says `globalActor(MBPersistenceStorage)` at the same point across launches is
consistent with a deterministic code-path bug and squeezes the room for "cache luck"), and it is
independently required before the corrected baseline becomes the gate's reference — a reference
that isn't self-identical can't anchor a byte-identical gate.

The decision-record sentence for 4a stays open until 1a/1b lands: verdict (compiler) — done;
new-code correctness (trace) — done; baseline mechanism — pending, with the conjecture explicitly
labeled as such in the log until then.

## 2. Problem 4b: run the PSI trace against a pre-registered fork

Top-candidate mechanism, registered here before the trace runs: **conformance-pair claim-once is
query-location-sensitive, and hypothesis 0's sort changed the claimant.** The pair-level analog of
problem 3: claim-once for pairs is only order-safe if the pair's *answer* does not depend on which
declaration's location the live query runs at. The pair is queried at the location of whichever
declaration claims it first; the sort changed traversal order, hence potentially the claimant,
hence potentially the query location, hence — if hover at the two locations reveals different
things about the conformance-inferred `@MainActor` — the shared answer, flipping the whole family
while the dedup mechanism itself remained formally unchanged. The baseline was right here by
traversal luck, which is itself an inherited order-dependence.

The trace (same shape as `MBP-TRACE`, filter `PhotoServiceImpl`, both code paths) must log, for
the (`PhotoServiceImpl`, `PHPickerViewControllerDelegate`) pair: whether the pair enters the work
list at all; which declaration claimed it; the exact (file, line, column) the live query used; and
the raw outcome. That output lands on a two-way fork:

- **(a) Queried in both paths, at different locations, with different outcomes** → the
  location-sensitivity mechanism above is confirmed. Fix direction: the collect phase chooses the
  pair's query location **canonically and semantically** — the location of the construct that
  *syntactically declares* the conformance (here, the `extension PhotoServiceImpl:
  PHPickerViewControllerDelegate` line), recorded per pair at collect time, independent of
  traversal order. This both fixes the regression and removes the inherited order-dependence —
  making it the second entry in the "hypothesis 0's gate found latent defects in the old code"
  list. A regression fixture pins it: primary type + same-file extension declaring an
  actor-inferring conformance, asserting the pair's query location is the extension's.
- **(b) Never queried in the new path** → the implementer's own suspect is confirmed: the
  eligibility filter (`declaredInSameFileAsPrimaryDefinition` or adjacent logic) fails to cover
  the "primary + conformance-declaring extension in the same file" shape, and the fix is in the
  filter, with the same fixture shape asserting the pair *reaches* the work list.

Either branch: no fix before the trace disambiguates — the log's own observation stands (two
consecutive confident fixes were incomplete; blind-fixing has negative expected value here).
If the trace shows a third shape not on this fork (queried at the same location with different
outcomes, or claimed but dropped between collect and execute), that is new information that feeds
back into §1's stability question — report it before fixing.

## 3. The third single node needs attribution

The census found 2 families + 3 single nodes, of which 2 are attributed (genuine improvements:
`unspecified` → correctly resolved). The third is currently unaccounted. §5.3 of the
investigation plan binds here: the gate closes on **zero unexplained residual** — every diff
entry attributed to exactly one of {fixed baseline bug, fixed new-code bug, compiler-verified
correction}. One node is cheap to trace with the same per-node diff tooling; do it before the
final gate run, not after.

## 4. Follow-up to file outside this task (do not fold into the gate)

**`PhotosUI` as a candidate for `BulkSymbolGraphExtractor.defaultModules`.** 4b surfaced that
`PHPickerViewControllerDelegate` resolves only via live query because PhotosUI isn't
bulk-extracted. Adding it is a semantic-source change (moves facts from live-query to bulk-cache
provenance) — by this task's own out-of-scope rules it does not belong in hypothesis 0's gate.
File it as its own small follow-up with its own before/after; while at it, check whether the
diagnostic run's residual live-query module histogram (hypothesis 4's measurement, still pending)
suggests other frameworks in the same position — one measurement may justify several additions at
once.

## 5. Execution order

1. §1a grep (desk check, baseline revision) — closes or redirects 4a's mechanism.
2. §2 PSI trace → fork (a)/(b) → targeted fix + fixture → real `Project Iris` run.
3. §3 third-single-node attribution (can ride along with step 2's run).
4. §1c baseline double-run (30-minute background task; start it in parallel with step 2 — it
   needs no code changes).
5. §1b only if §1a came back empty.
6. Then: §5 gate-rebase procedure from the investigation plan (corrected baseline, zero
   unexplained residual), §7 minor items (acceptance denominator, regression fixtures — now three
   with 4a's, likely four with 4b's), and the decision record.
