# Review: Gap B implementation plan — approved with four corrections

**Status: plan-review record for `task-gap-b-implementation-plan.md`, to be applied before
implementation begins. Tenth document of the compiled-dependency-isolation thread.** The plan is
approved in shape and sequencing: the `.baseOf` direction-verification gate mirrors Gap A's
`.accessorOf` discipline exactly; the skip-don't-guess collision philosophy matches
`disambiguate`'s precedent; I4's trace survives even though I2 fixes the symptom — all correct.
One refinement in the plan is explicitly endorsed as a correction *to the research response it
implements*: the Plan-agent's finding that per-member conformance copies are semantically
load-bearing for rule 8 (`declaredInSameFileAsPrimaryDefinition`/
`declaredInSameContextAsWitness` read per-declaration) is right, and the ninth document's
implication that deduplication could live in the extractor was too aggressive — dedup belongs at
the backfill, as the plan says. The four corrections below are ordered by severity; the first is
the one that changes behavior at the scale the whole task is about.

## Correction 1 (critical) — I2 must query the *nominal*, and rewrite *all* copies, or it misses exactly where the mass is

As written, I2 iterates `byUSR.values` and calls `baseTypeUSRs(forUSR: declaration.usr)` for
each declaration with unresolved needs. But the captured corpus — and the plan's *own* I3
rationale — establish that conformance copies ride on **member** declarations (methods,
properties): `NotificationsListViewController(im)tableView:cellForRowAtIndexPath:` carries
`needs=…UITableViewDataSource…`. A `.baseOf` relation query against a *method's* USR returns
nothing — methods have no base types. So for every member-carried copy, I2-as-written performs
an empty query and leaves the need unresolved; only the nominal's own entry resolves. Since
`IsolationInferenceEngine` reads `declaration.conformances` per declaration (rule 8 — the
plan's own finding), member copies that stay `syntactic:` mean rule 8 silently loses its input
on those members. The fix shape:

1. Resolve once per **distinct nominal**: query `baseTypeUSRs(forUSR: nominalUSR)`, build a
   per-nominal `bareName → realUSR` map.
2. Rewrite **every** copy of that nominal's needs from the shared map — the nominal's own entry
   and all member-propagated copies alike.
3. The member→nominal derivation this requires is the *same* derivation I3's
   `(nominal-type USR, unresolved-need)` pair key already needs. **I2 and I3 must share one
   implementation of it and one keying scheme** — two parallel derivations of "which nominal
   does this declaration belong to" is a future divergence bug by construction. If no existing
   `DeclarationInfo` field supplies it, derive via the index (`.containedBy`/`childOf`
   relations, the established query pattern) rather than by string-parsing USRs.

Acceptance addition for I2's tests: a fixture where the *member's* conformance copy (not just
the nominal's) is asserted rewritten after the pass.

## Correction 2 — I1's normalization is narrower than the real problem; three more shapes come out of the same `.trimmedDescription` path

Unwrapping `AttributedTypeSyntax` fixes `@unchecked Sendable` and `@preconcurrency P`, but the
same extraction path emits three further malformed-or-unmatchable placeholder shapes, each of
which silently defeats I2's by-name matching later:

- **`Container<Int>`** — subclassing a generic base (`IdentifierTypeSyntax` with a
  `genericArgumentClause`). The index symbol's name is `Container`; the placeholder's bare name
  must be `name.text`, not `trimmedDescription`. Subclassing a generic base is a routine iOS
  codebase shape, not an edge case.
- **`Namespace.Proto` / `Foundation.Data`** — qualified references (`MemberTypeSyntax`). Bare-
  name matching needs the rightmost `name.text` (retain the full path separately if useful for
  future disambiguation, but the match key is the rightmost component).
- **`~Copyable` / `~Escapable`** — suppression entries (`SuppressedTypeSyntax`). These are not
  conformances at all; the entry should be skipped entirely, not turned into a placeholder.

Fix shape: one normalization function over the inheritance-entry type — `AttributedType` →
recurse into `baseType`; `IdentifierType` → `name.text`; `MemberType` → rightmost `name.text`;
`SuppressedType` → skip entry — with one unit test per shape, replacing the single
`@unchecked Sendable` test the plan specifies.

## Correction 3 — I3 must be cache-and-apply, not skip-and-leave

"Skip if that exact pair was already attempted" is correct for suppressing duplicate *cost*, but
if the second member's copy is skipped without receiving the first attempt's *result*, that copy
remains `syntactic:` and rule 8 loses its data on that member — the same failure as Correction 1
by a different route. The pair map must store the resolution outcome
(`pairKey → resolvedUSR-or-unknown`) and rewrite every subsequent copy from it. Note the
interaction: if I2 lands with Correction 1 (all copies rewritten from the per-nominal map), I3's
residue is only the genuinely-unresolvable pairs — which is precisely why the two phases sharing
one keying scheme matters. I3's unit test should assert both halves: second copy not re-queried
*and* second copy rewritten.

## Correction 4 — I2's direction fixture must include the extension-declared shape, and the "transitive bases" question should be reframed

A direction-verification fixture containing only `class C: P` validates the relation's direction
but not the corpus's *dominant* shape: conformances declared on **extensions**
(`extension NotificationsListViewController: UITableViewDataSource … { … }`). The same fixture
must include an extension-declared conformance and assert it surfaces via
`occurrences(relatedToUSR: nominalUSR, roles: .baseOf)` — this is the ninth document's
pre-registered P1, and it gates whether the whole pass works on the code shape that produced the
28134 in the first place.

The plan's open question "does `.baseOf` return only direct bases or transitively-inherited ones
too" should be reframed before it is investigated: relation occurrences are *physical clause
references in source* — transitivity has nowhere to come from. The real question is whether
**retroactive conformances declared in other files' (or other modules') extensions** are
included — likely yes, and desirable data. Its practical consequence: same-bare-name collisions
become slightly more plausible, and before falling back to skip-don't-guess, one cheap tiebreaker
is available — the occurrence's own location (the clause physically lives in this declaration's
file or its extensions' files). Skip remains the correct floor; the tiebreaker is an optional
refinement worth one test if implemented.

## Minor note on I4

Keep the placeholder byte-compare as the *first* print of the trace, despite the grep having
confirmed `NotificationsListViewInput` is top-level: if any same-named declaration exists
anywhere in the extracted corpus (Pods sources included, which are currently in scope), a
collision-dedup `#offset` suffix on the declaration side would break map-key identity in exactly
the way that is invisible to every other probe — and the print costs zero.

## Sequencing and verification, as amended

Sequencing is unchanged (I1 → I2 ∥ I3 → I4 alongside I2 → I5) with one addition: the shared
member→nominal derivation (Correction 1/3) is a small prerequisite unit landing with whichever
of I2/I3 goes first. Verification additions over the plan's own list: per-shape normalization
tests (Correction 2), member-copy-rewritten assertion (Correction 1), second-copy-rewritten
assertion (Correction 3), extension-declared-conformance direction fixture (Correction 4). The
plan's I5 measurement, metrics, and honest-wall-clock reporting stand exactly as written.
