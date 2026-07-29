# Review addendum: two wording amendments to the refined external-extension-isolation task

**Status: review-addendum record for the refined `task-external-type-extension-isolation.md`,
to be applied to the task text (or carried into the implementation plan) before implementation
begins. The refined task is otherwise approved as written.** The refinement round itself is the
thread's discipline working end to end and deserves the record stating so: variant 1a was not
accepted on the review's authority but independently re-verified on two real index stores —
V1–V2 on the `cross-file-witness` fixture, V3 on the motivating `Project Iris` case itself, returning
`c:objc(cs)UIViewController` (the clang spelling, the exact bulk-cache key) and confirming the
reverse-direction query returns nothing; the sibling extension-attribute concern was checked and
produced the best possible outcome — `enclosingExtensionIsolation` already exists, is already
consulted by the engine *before* containing-type propagation, both polarities already have
dedicated passing tests, and the task now records this so no future session re-raises a settled
question; and the pre-registered baseline came back **20 of 129**, four times the motivating
file's 5, with the additional shapes named (`UICollectionViewLayoutAttributes`,
`WKWebViewConfiguration`, `UITabBarController`, `MKMapView` extensions). One empirical nugget
from the verification is worth keeping visible for implementers: an extension's synthetic USR is
derived from its *first member* (`s:e:s:So16UIViewControllerC…E19addCustomBackButton…`), so
per-extension identity is stable by construction. Two amendments follow; both are wording-level,
but each guards a property the refined task itself declares non-negotiable.

## Amendment 1 — specify the grouping step, or §per-extension is lost exactly where it matters

The refined fix shape reads: "resolve the extended type's real USR **via any one such member**,
then … rewrite `containingTypeUSR` on **every member of that extension**." Between those two
phrases sits an unspecified step: *how the implementation knows which members belong to "that
extension."* There is only one wrong answer available, and it is also the most convenient one:
grouping by the shared bare-name placeholder (`"syntactic:UIViewController"`). That grouping is
per-bare-name resolution — members of *every* extension of *anything* named `UIViewController`
anywhere in the project (Pods sources included, under the current scope) would receive one
extension's answer — which is precisely what the task's own retained-verbatim per-extension
section forbids, reintroduced silently through an implementation detail.

The amendment: state the shape explicitly as —

1. **Hop 1 runs per member.** Each member's own `.definition` occurrence's `.childOf` relation
   yields *that member's own* extension's synthetic USR.
2. **Hop 2 is memoized per extension USR.** `occurrences(relatedToUSR: extensionUSR,
   roles: .extendedBy)` runs once per distinct extension, not once per member.
3. **Grouping falls out of hop 1 for free**: "the members of this extension" are exactly the
   members whose hop-1 answer is the same extension USR. No placeholder-based grouping exists
   anywhere in the pass.

Cost is unchanged (hop 1 is a fast in-memory index lookup; hop 2 is one query per extension),
divergence safety holds by construction, and the never-guess floor needs no separate collision
handling — two same-named types extended in-project simply produce two extension USRs with two
independent hop-2 answers.

## Amendment 2 — close the verification set: V4 into the DoD-5 fixture, plus one end-to-end assert

Of the four pre-registered verification points, three are now empirically confirmed; **V4 —
nested extended types (`extension Foo.Bar`) and extensions of generic types — is the one not yet
run.** The risk is low precisely because the chain is relation-based rather than name- or
location-based, but since the DoD-5 fixture package is being built regardless, folding both V4
shapes into it costs two small declarations and retires the only open point of four, rather than
leaving it as the un-run exception to an otherwise fully verified design.

The same fixture should carry one more end-to-end assert, closing a seam the task currently
crosses on faith: **the backfilled isolation fact must land in the `declarations` store keyed by
the same real USR that `resolveInheritedIsolation` subsequently looks up as the rewritten
`containingTypeUSR`.** The existing external-superclass backfill machinery almost certainly
already does this — it is the same store and the same keying it uses for superclass facts — but
the fixture asserting the full chain (member → rewritten `containingTypeUSR` → backfilled entry
→ engine resolves `globalActor(MainActor)`) turns "almost certainly" into a regression test for
free.

## Residual limitation to record (one line in the decision record, per convention)

An extension none of whose members resolved to a real USR has no hop-1 entry point; its members
remain exactly as today — placeholder containing type, `.nonisolated`, false-positive-only per
the task's own verified scope note. Post-Gap-B this population should be near zero; it should be
named in the decision record as an evidenced limitation rather than discovered later as a
surprise, with the diagnostic's counter as its measurement if a number is wanted.

## Summary of changes to the task text

Section 3's fix-shape paragraph: replace "via any one such member … every member of that
extension" with the three-step per-member/memoized shape of Amendment 1. DoD 5: add the two V4
shapes and the end-to-end keying assert of Amendment 2. DoD 7's decision record: include the
residual-limitation line. Everything else — including DoD 4's pre-registered 20-of-129 check —
stands exactly as written.
