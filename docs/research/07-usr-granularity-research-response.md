# Research response: accessor-granularity mapping and the real-scale linker gap

**Status: remote analysis of `task-compiled-dependency-isolation-usr-granularity.md`,
source-verified where checkable from here (`swiftlang/indexstore-db` `main`, read 2026-07-26),
with pre-registered predictions per thread discipline. Eighth document of the
compiled-dependency-isolation thread.** The task doc's own diagnostic methodology — short-circuit
instrumentation buying exact residue counts in seconds — is the right template for verifying
everything below; re-instrument the same shape before and after each fix.

## 1. Gap A, the check-first question — answered from source: IndexStoreDB exposes the accessor→property relation directly

The task doc asks, correctly, to check for an existing owning-property relationship *before*
building any demangler. Verified in `swiftlang/indexstore-db` sources:

- `Sources/IndexStoreDB/SymbolRole.swift` defines the relation role
  `public static let accessorOf: SymbolRole = SymbolRole(rawValue: INDEXSTOREDB_SYMBOL_ROLE_REL_ACCESSOROF)`.
- `Sources/IndexStoreDB/Symbol.swift` defines accessor subkinds (`accessorGetter`,
  `accessorSetter`, `swiftAccessorWillSet`, `swiftAccessorDidSet`, `swiftAccessorAddressor`,
  `swiftAccessorMutableAddressor`) — so an accessor USR is *detectable as an accessor* without
  parsing anything.
- `Sources/IndexStoreDB/SymbolOccurrence.swift`: every occurrence carries
  `relations: [SymbolRelation]`, each a `(symbol, roles)` pair.

So the mapping the task needs is one index lookup, no demangling, no subprocess: given a
call-graph target USR whose symbol subkind is an accessor, fetch its definition occurrence and
read the relation whose roles contain `.accessorOf` — that relation's `symbol.usr` is the owning
property's canonical USR. **Pre-registered prediction P1:** on a real `Project Iris` index store, getter
and setter definition occurrences carry exactly one `.accessorOf` relation pointing at the
property USR (the direction — which side of the occurrence carries the relation — is the one
detail to confirm empirically in minutes with existing `IndexStoreIntegration` plumbing; if it
turns out to live on the property side instead, invert the query, same cost).

Keep the suffix rewrite as a **zero-lookup fast path, validated against the relation**, not as an
independent source of truth: the captured corpus itself shows the shape (`…Sdvg` getter,
`…pvs` setter vs. a property's canonical `…vp`; subscripts `…ig`/`…is` vs. `…ip`). A
corpus-driven unit test — every accessor USR captured by the diagnostic run, suffix-mapped, must
equal the `.accessorOf` answer — gives the fast path the same evidentiary standing as everything
else in this thread. One semantic note for the record: mapping an accessor to its property means
answering with the *property's* isolation; per-accessor isolation divergence is exotic but
expressible, so state the approximation in the decision record and let any future counterexample
become a fixture rather than silently assuming none exists.

## 2. Gap A's real payoff is misclassification, not cache hit rate — apply the mapping at the classification point

The single most consequential number in the diagnostic is not the bulk-miss count — it's that
**60% of edge-level misses (11400) carry the project's own module prefix with accessor
suffixes**. Those are project-local property accesses whose edge targets (`…vg`/`…vs`) miss the
`declarations` table (keyed by canonical property USRs) and are therefore *misclassified as
external*, then marched through the whole oracle pipeline that was never supposed to see them.

Therefore the mapping must be applied at the **earliest point where an edge target is resolved
against `declarations`** — before the internal/external classification — not merely "before
consulting the bulk cache" as the task doc's Gap-A step 2 words it. Done there, one fix
simultaneously: (a) turns the 11400 project-local misses into ordinary internal resolutions with
zero oracle involvement; (b) lets external property reads (`Date.timeIntervalSince1970`,
`Mindbox`'s setter case) hit the already-extracted bulk entries; (c) shrinks the live-fallback
residue to genuinely-unknown externals. **Prediction P2:** this placement alone removes ≥60% of
today's edge-level oracle load before any coverage work, and the post-fix hit-rate metric (task
DoD Gap-A #4, today 850/19807 ≈ 4.3%) moves to a large double-digit percentage.

On coverage: adding `Swift` and `CoreFoundation` to `defaultModules` is right (the
`s:Sa…`/`s:Sb…`/`CGFloat` samples are exactly stdlib-shaped); measure the stdlib graph's
size/time before trusting it in the default path — it is the largest module there is — and note
it is also the ideal first resident for the still-pending persistent cross-run cache (perf-task
option D): invariant per toolchain, shared across every project.

## 3. Gap B — ranked hypotheses with concrete checks (pre-registered, cheapest first)

The decisive diagnostic fact: 100% of declaration-level misses are `syntactic:` placeholders —
and a `syntactic:` placeholder is a **name, not a USR**, so it can never hit a USR-keyed cache
even in principle. Two structurally different populations hide under that one prefix, and they
need different fixes:

**H-external (e.g. `syntactic:UICollectionViewCell`, `syntactic:CodingKey`):** these may never
have been the linker's to resolve — if `DeclarationLinker` links placeholders only through
*definition* occurrences of project symbols, external supertypes stay syntactic *by design*, and
no linker fix changes that. The structural completion is already within reach: the inheritance
clause's source location is known from syntax, and the index store records a **reference
occurrence at exactly that location carrying the real USR** (`UICollectionViewCell`'s clause
mention is an indexed reference). Resolve: placeholder + clause location → reference occurrence →
real USR → the normal, now-bulk-first oracle path. **Prediction P3:** for the captured examples,
the reference occurrence with the correct USR is present at the clause location in `Project Iris`'s
store — checkable in minutes with existing plumbing, and this one step converts the entire
external slice of the 28134 from permanently-unresolvable to ordinarily-resolvable.

**H-local (e.g. `syntactic:NotificationsListViewInput`, `syntactic:ManagerAssembly` — the
project's own protocols):** these are the true linker bug. Trace exactly one, end-to-end, per the
task doc's own instruction; the ranked suspects to check while tracing, in order of cheapness:
path-form mismatches in location comparison (absolute vs. `realpath` vs. workspace-relative;
`Project Iris` sits behind `Project Iris` — symlinks and case are classic scale-only failures), then
any capped/limited index query in the disambiguation loop (a `maxResults`-style cap invisible on
small fixtures), then candidate-name mismatch for nested/qualified names. And one adjacent real
bug to fix regardless of whether it is Gap B's cause: the never-root-caused
`News/News/ List/…` stderr noise is characteristic of **unquoted-whitespace splitting of paths**
in the build-log→compiler-args parser — a real corruption for any file under a space-containing
directory, currently affecting the live oracle's arguments even if not the linker. It has sat as
"cosmetic" through two documents; a project named with a space away from being a correctness
bug is worth the hour.

## 4. Execution order (each step independently checkable with the diagnostic)

0. Re-add the short-circuit diagnostic (the task doc preserves its exact shape) — it is the
   before/after instrument for every step below.
1. Gap A: `.accessorOf`-based normalization at the classification point (P1, P2), suffix fast
   path corpus-validated behind it.
2. `Swift` + `CoreFoundation` into `defaultModules`, with measured extraction cost.
3. Gap B external slice: clause-location → reference-occurrence resolution (P3).
4. Gap B local slice: single-case end-to-end trace of `NotificationsListViewInput`, fix what it
   reveals, re-run diagnostic — `syntactic:` residue should approach zero (task DoD Gap-B #3).
5. The whitespace-path parser fix, independent of what step 4 finds.
6. Timed, complete DoD runs on both projects; and fold in the honestly-flagged leftover from the
   G6 record — a stratified ~10-finding audit of `~/SQLumen`'s 38→93 `highRiskBoundaries` against
   real `swiftc` ground truth, so the number's correctness standing matches the golden matrix's
   before it anchors any before/after narrative.

Nothing above touches `IsolationInferenceEngine`, the risk heuristic, or the report schema; every
isolation fact still originates from the compiler; the only things that change are (a) which USR
identifies a thing, decided by the index store's own relations, and (b) how a syntactic name
becomes a USR, decided by the index store's own occurrences — both answered by the project's
existing sources of truth rather than any new mechanism.
