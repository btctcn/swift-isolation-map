# Problem 4 investigation plan: the `MBPersistenceStorage` family divergence (hypothesis 0, open)

Status: instructions for the implementer, written against `hypothesis-0-debugging-log.md`. Fixes
1–3 are done and confirmed; this plan covers only the open problem 4 (~72–75 declarations in the
`MBPersistenceStorage` family: `globalActor(MBPersistenceStorage)` in the pre-hypothesis-0
baseline, `nonisolated` after all three fixes) and the two minor items that fall out of the same
work. The `MBP-TRACE` run already in flight stays useful — §6 maps its possible outcomes onto the
steps below — but the steps are ordered so that the cheapest, most direction-setting check runs
first, not the one that happens to be already started.

The one sentence that orders everything else: **a correctness-gate diff localizes a divergence
but does not, by itself, say which side is wrong.** Problems 2 and 3 were new-code bugs. Problem 4
carries a specific red flag pointing the other way — the global-actor payload is *the containing
class's own name*, while the class's own record is `nonisolated` in both runs. A class and a
same-named global actor inside one resolution chain is the signature of a name-string path (i.e.
a placeholder-derived one), not a USR path — which is exactly the pre-existing, documented
collision class that fix 3 dealt with, except potentially living in the **baseline**. So step 0
establishes ground truth before any code is presumed guilty.

---

## Step 0 — decisive first: ask the compiler which answer is true (§1.5.1 discipline)

Per the architecture's own sourcing hierarchy, the arbiter is empirical `swiftc` validation, not
either of the two runs.

Recipe:

1. Scratch package/target compiled in Swift 6 language mode, with the Mindbox pod's real
   `MBPersistenceStorage.swift` (or a faithful minimal reduction of it: class + two or three of
   the affected `@UserDefaultsWrapper` properties, e.g. `deprecatedEventsRemoveDate`,
   `apnsTokenSaveDate`, plus `dateFormatter`) in the target.
2. From a deliberately `nonisolated` context (a free function is enough), read and write those
   properties **without** `await`.
3. Read the diagnostics. If the members were genuinely isolated to any global actor, Swift 6 mode
   must diagnose the synchronous access; if it compiles clean, they are `nonisolated` — full stop.
4. Record the exact compiler output in the debugging log (and later the decision record), the
   same way every other empirical check this project has made is recorded.

Decision fork — everything downstream branches here:

- **Compiler says `nonisolated` (expected, given these are property-wrapper-backed members of a
  plain class):** the baseline is wrong for this family; problem 4 is reclassified from
  "hypothesis 0 does not converge" to "hypothesis 0's gate discovered a latent accuracy bug in
  the baseline." Proceed to steps 1–4 to identify the baseline mechanism (the gate still cannot
  close on an unexplained diff — "baseline wrong" is not a license to stop tracing), then apply
  §5's gate-rebase procedure.
- **Compiler diagnoses actor isolation (unexpected):** the new code is wrong; steps 1–4 apply
  unchanged, but the suspect list inverts — fix 3's placeholder pass and the collect-phase need
  extraction become the primary suspects, and §5's gate-rebase procedure is *not* invoked.

Either way, do not skip step 0 or run it after the tracing: it costs minutes, and it decides
which codebase (old or new) every subsequent finding indicts.

## Step 1 — census before deep-tracing: how many families are there?

Before spending more time inside `MBPersistenceStorage`, group the **entire** remaining node diff
(all declarations whose `isolation` differs between baseline and the current post-fix-3 run) by
`(file, containing type)` and count the families. Motivation: the aggregate counters still differ
in ways one family may not fully explain (`mainActorTypes` 12011 vs 11999 is a 12-type gap;
`highRiskBoundaries` 329 vs 559), and boundaries are edge-derived, so a small declaration family
can fan out into many boundary deltas — or hide a second, unrelated family behind the same
totals. The census answers, in one pass over data that already exists (the two result sets),
whether closing `MBPersistenceStorage` closes problem 4 entirely or reveals problems 5+ queued
behind it. Output: a table of `family → node count → example USRs`, appended to the debugging
log.

## Step 2 — diff the shared state, not the per-node inputs

A family of ~72–75 nodes flipping *together* is the signature of **one shared upstream fact**
changing, not of 72 independent bugs. The efficient localization is therefore a diff of the
shared caches between the two runs, filtered to family-adjacent entries, rather than per-node
input tracing:

- Dump `backfilled` (the USR → outcome map) and `conformancePairOutcomes` / `pairOutcomes` at
  end-of-oracle-phase in both code paths (env-gated, same discipline as the statistics hook).
- Diff the dumps, filtered to any key or value whose text contains `MBPersistenceStorage` (and,
  per step 1's census, the other family names if any).
- The entries that differ — or exist on one side only — name the shared fact directly. Then trace
  *that one fact's* resolution (who queried it, at what location, in what order, with what
  outcome), instead of the whole family.

Expected shape of the answer, for calibration: exactly one or two entries (a placeholder key
like `syntactic:MBPersistenceStorage`-something, or one member's shared answer) differing, with
72–75 declarations all consuming it via the containing-type/superclass chain or via the shared
placeholder answer table.

## Step 3 — audit order-dependence: "exact original semantics" includes iteration order

Fix 3 reproduced the original retry semantics (`backfilled[usr] == nil`, retry on `.unknown`,
share on success). But first-success-wins sharing is **iteration-order-dependent by
construction**: whichever declaration's query succeeds first sets the shared answer for every
same-named placeholder after it. Two audits:

1. **New pass vs old pass order.** Does `resolveSyntacticPlaceholderNeeds` iterate its needs in
   the *same order* the original interleaved loops would have reached them? If the new pass runs
   in sorted order (or collection order of a different container), the first-success winner can
   legitimately change, flipping an entire family while every individual rule is faithfully
   reproduced. If the orders differ, either reproduce the original order for this pass or —
   preferably, see §5 — treat the order-dependence itself as the baseline defect to eliminate.
2. **Is the baseline order even deterministic?** If the original loops iterated
   `Dictionary.values` (e.g. `linked.declarations.values`), iteration order depends on Swift's
   per-process randomized hash seed — meaning the baseline's own answers for colliding
   placeholders could vary between *launches* of the unmodified old binary. Test directly: run
   the baseline twice, diff its own outputs against itself. If baseline is not self-identical,
   that is a standing nondeterminism inherited by the gate's reference side — exactly the class
   of defect DoD 3 declares a blocking correctness bug, pre-existing rather than introduced. It
   must be recorded, and the gate can only be defined against an order-stabilized baseline.

## Step 4 — grep the construction sites: where can a bare name become a global-actor payload?

The only way the *containing class's name string* can end up as a `globalActor(...)` payload is a
code path that constructs that isolation case from a name (a placeholder string, a syntactic
attribute name) rather than from a resolved USR. Those construction sites are finitely
enumerable: grep for every point that builds the global-actor isolation case, classify each by
input provenance (resolved USR vs bare string), and inspect the ones reachable from the
placeholder path. This is a desk check — no 30-minute run — and it converts the `MBP-TRACE`
result from "raw values to interpret" into "confirmation or refutation of a named mechanism."

## §5 — gate consequences (only if step 0 says the baseline is wrong)

The DoD's byte-identical gate stays byte-identical — against a **corrected** baseline:

1. The baseline defect (the mechanism steps 2–4 identify) is fixed in its own commit, with its
   own regression test, documented as its own finding — discovered *by* hypothesis 0's gate,
   logically independent of it.
2. Baseline is re-run with that fix; the corrected numbers become the gate's reference. The
   correction's own before/after (e.g. 329 → whatever the corrected truth is) is recorded with
   the step-0 compiler evidence attached.
3. Hypothesis 0's gate then requires byte-identity against the corrected reference, with zero
   unexplained residual. "The remaining diff is probably the same bug" is not closure — every
   residual family must be attributed (fixed baseline bug, fixed new-code bug, or compiler-
   verified correction) before the gate counts as passed.
4. Engineering the new code to reproduce a compiler-refuted baseline answer is prohibited — this
   follows from the project's own first principle, not from convenience.

## §6 — mapping the in-flight `MBP-TRACE` output onto the steps

- Trace shows the family's `containingTypeUSR`/`superclassUSR` collected as **real USRs** with
  query outcomes differing between paths → the shared fact is a real-USR answer; step 2's cache
  diff pinpoints it; step 4 is likely exonerated.
- Trace shows a **placeholder** among the collected needs whose resolved answer differs (or
  resolves on one side only) → step 3's order audit is the live suspect; step 4 identifies the
  payload mechanism.
- Trace shows identical collection and identical query outcomes on both paths → the divergence is
  downstream, in the apply/inference stage (`enclosingExtensionIsolation`, member-vs-containing
  chain in `IsolationInferenceEngine`) — rerun step 2's diff at the post-apply stage instead of
  the oracle-cache stage.

## §7 — minor items (do not lose these in the main investigation)

1. **Acceptance-equality denominator.** The pre-registered signal "post-ordering
   `num-ast-builds` == distinct file-group count" should count only groups **that actually reach
   sourcekitd**: groups whose every item fails before the query (missing compiler args) pay no
   build by definition. Print both numbers (total groups, sourcekitd-reaching groups) in the
   env-gated diagnostic; the equality assert binds to the second. This keeps the check a strict
   `==`, preserving its value as a silent-ordering-regression detector, instead of degrading it
   to `<=`.
2. **Two regression fixtures after closure**, one per confirmed bug class, so neither ever again
   requires a 30-minute real run to detect:
   - Fix 2's class: a conformance resolved **through the bulk symbol-graph cache** (non-empty
     `bulkModuleNames`, extension declaring the conformance in another file), asserting the
     outcome is applied to the declaration's `conformances`.
   - Fix 3's class: two declarations from **different real entities** sharing one
     `syntactic:<Name>` bare-name placeholder, where the correct answers differ — asserting
     claim-once sharing is not applied across them and each resolves independently.
   - If step 0 reclassifies problem 4 as a baseline bug, its fix's regression test (from §5.1) is
     the third fixture in the same series.
