# Gap B implementation plan — DeclarationLinker real-scale linking fixes

**Status: plan for review, not yet implemented.**

## Context

Gap A (accessor/property USR mismatch) and a whitespace-path-escaping bug were both found and
fixed earlier this session (`docs/priority-3-compiled-dependency-isolation.md`). Real-world
validation against `Project Iris` (2209 files, 46010 declarations) then showed Gap B is the *sole*
remaining blocker to a full run completing in reasonable time: **100% of 28134 declaration-level
oracle triggers carry a `syntactic:`-prefixed placeholder need** — `DeclarationLinker` never
resolved these superclass/protocol references to real USRs at all, so every one of them pays a
live-query cost destined to fail. At the measured throughput (~13 queries/min), running all 28134
to completion would take 35-40 hours. Full problem statement, real captured examples, and the
exact `DeclarationLinker` code already read this session: `docs/task-gap-b-declaration-linker-real-scale.md`.

A follow-up research response proposed using `IndexStoreDB`'s `.baseOf` relation
(`occurrences(relatedToUSR:roles:)`) to resolve inheritance-clause references directly from the
index, instead of `DeclarationLinker`'s existing location-based placeholder matching. **Verified
this session, directly against the real checked-out `swiftlang/indexstore-db` source**: both the
method and the relation role are real, mirroring `.accessorOf`'s already-trusted shape from Gap A
exactly. A real existing `indexstore-db` test (`IndexTests.swift:90-104`) demonstrates
`occurrences(relatedToUSR: X, roles: .calledBy)` returns occurrences that have a relation *to* X
with that role — applied to `.baseOf`, this means `occurrences(relatedToUSR: declUSR, roles:
.baseOf)` returns occurrences of `declUSR`'s own base types/protocols, real USRs included. Two
additional real bugs were confirmed by directly reading `DeclarationExtractor.swift`: a malformed
placeholder (`"syntactic:@unchecked Sendable"`, attributes leaking into the name via
`.trimmedDescription`) and per-member conformance duplication (inflating the 28134 count — every
member of a type gets its own copy of the type's conformances). A second Plan-agent design review
this session further verified all of the above against the actual code and refined the fix shape
(see inline notes below).

**Explicitly deferred, not part of this work** (user's explicit call): whether
`StalenessOrchestration.swiftFiles` should stop scanning `Pods`/`Carthage` source — a real,
pre-existing, deliberate scope decision, currently "leave it as-is." Write this up as its own
small, separate research-task note after this work lands (not a Gap B fix, not blocking it).

## Phase I1 — Malformed-placeholder fix (isolated, safe, lands first)

`Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `applyInheritance`: currently
`inheritance.inheritedTypes.map { $0.type.trimmedDescription }`. Unwrap `AttributedTypeSyntax` to
its real `.baseType: TypeSyntaxProtocol` property first (confirmed real API,
`.build/checkouts/swift-syntax/.../AttributedTypeSyntax`), e.g.:
```swift
let entries = inheritance.inheritedTypes.map { entry -> String in
    if let attributed = entry.type.as(AttributedTypeSyntax.self) {
        return attributed.baseType.trimmedDescription
    }
    return entry.type.trimmedDescription
}
```
So `@unchecked Sendable` becomes the placeholder `"Sendable"`, not `"@unchecked Sendable"`.

**Widened per external review — `.trimmedDescription` on the same extraction path produces three
further malformed-or-unmatchable placeholder shapes** (all confirmed real against the checked-out
`swift-syntax` source: `IdentifierTypeSyntax.name`/`.genericArgumentClause`,
`MemberTypeSyntax.baseType`/`.name`, `SuppressedTypeSyntax.type` are all real fields):
- **`Container<Int>`** (`IdentifierTypeSyntax` with a `genericArgumentClause`) — subclassing a
  generic base, a routine shape. The placeholder's bare name must be `.name.text` ("Container"),
  not the full `trimmedDescription` (which would include `<Int>` and never match the index
  symbol's own bare name).
- **`Namespace.Proto`** (`MemberTypeSyntax`) — a qualified reference. Match key must be the
  rightmost `.name.text` ("Proto"); retain the full path separately if useful for future
  disambiguation, but the by-name match in Phase I2 needs the rightmost component.
- **`~Copyable`/`~Escapable`** (`SuppressedTypeSyntax`) — a suppression entry, not a conformance
  at all. Skip the entry entirely rather than turning it into a (meaningless) placeholder.

Implement as one normalization function over the inheritance-entry's `TypeSyntax`, replacing the
single `.trimmedDescription` call: `AttributedTypeSyntax` → recurse into `.baseType`;
`IdentifierTypeSyntax` → `.name.text`; `MemberTypeSyntax` → rightmost `.name.text`;
`SuppressedTypeSyntax` → skip the entry; anything else → fall back to `.trimmedDescription`
unchanged (today's behavior, for whatever shape isn't covered above).

**Test**: one case per shape in `SyntaxAnalysisTests/DeclarationExtractorTests.swift` — `@unchecked
Sendable`/`@preconcurrency P` (attribute-stripped), `Container<Int>` (generic-stripped),
`Namespace.Proto` (rightmost-name), `~Copyable` (entry skipped, not present as any placeholder at
all) — replacing the single attribute-only test originally planned.

## Phase I2 — `.baseOf`-based inheritance resolution (the core fix)

**Direction verified empirically first**, exactly like Gap A's `.accessorOf` — do not trust the
strong prior evidence (the real `indexstore-db` test cited above) without a real test against this
project's own toolchain. **The direction fixture must include an extension-declared conformance,
not only a plain `class C: P` shape** — conformances declared via `extension SomeType: SomeProtocol
{ ... }` are the *dominant* real-world shape (confirmed: this is exactly how
`NotificationsListViewController` conforms to `UITableViewDataSource` in the real corpus) and must
be confirmed to surface via `occurrences(relatedToUSR: nominalUSR, roles: .baseOf)` the same way a
direct `class C: P` conformance does — this is the one check that gates whether the whole pass
works on the code shape that actually produced the 28134 number, not just the simplest case.

`Sources/IndexStoreIntegration/IndexStoreClient.swift`: add to `IndexStoreQuerying`:
```swift
func baseTypeUSRs(forUSR usr: String) -> [(usr: String, name: String)]
```
implemented via `db.occurrences(relatedToUSR: usr, roles: .baseOf).map { ($0.symbol.usr, $0.symbol.name) }`
(exact shape TBD pending the direction test — invert if needed, same cost either way per the
research response's own framing).

**Critical correction from external review — query the nominal, not the member, and rewrite every
copy.** The corpus's `needs=` lists overwhelmingly ride on *member* declarations (methods,
properties: `NotificationsListViewController(im)tableView:cellForRowAtIndexPath:
needs=…UITableViewDataSource…`), because `DeclarationExtractor` attaches a copy of the enclosing
type's conformances to every member's own `DeclarationInfo` (already established, see Phase I3).
`.baseOf` is a *type-level* relation — a `.baseOf` query against a *method's* own USR returns
nothing (methods have no base types), so naively querying `baseTypeUSRs(forUSR: declaration.usr)`
per declaration would silently resolve only the small number of nominal-type-level entries and
leave every member-carried copy unresolved — missing exactly where the volume is. Corrected shape:

1. Resolve **once per distinct nominal type**, not per declaration: for a member declaration with
   an unresolved need, the nominal to query is `declaration.containingTypeUSR` — **already an
   existing `DeclarationInfo` field, already threaded through the exact same `rewritten(_:)`
   USR-canonicalization `relink` already applies to `superclassUSR`/`conformances[].protocolUSR`**
   (confirmed by re-reading `DeclarationLinker.link(_:)`:
   `containingTypeUSR: declaration.containingTypeUSR.map(rewritten)`). No new index-based
   member→nominal derivation is needed — reuse this field rather than inventing a second, parallel
   way to answer "which nominal does this declaration belong to" (a real, avoidable divergence risk
   two independent derivations would create). If `containingTypeUSR` is itself still
   `syntactic:`-prefixed (the containing type didn't directly resolve — e.g. it's nested, see the
   nesting-fallback below), resolve *it* first via that same fallback before using it as the query
   key.
2. Query `baseTypeUSRs(forUSR:)` once per distinct real nominal USR (memoize, matching Gap A's own
   per-`link()`-call memoization precedent), building a `bareName → realUSR` map for that nominal.
3. Rewrite **every** copy of that nominal's unresolved needs from the shared map — the nominal's
   own entry (if it too has an unresolved need) *and* every member-propagated copy alike, not just
   the first one encountered.
4. This member→nominal derivation and its memoized per-nominal map are **the same underlying
   mechanism Phase I3's dedup needs** — implement and key it once, shared between the two phases,
   not as two parallel implementations.

By-name matching (strip `"syntactic:"`, compare against each `(usr, name)` pair's `name`) mirrors
`disambiguate`'s existing precedent. **If more than one returned candidate shares the same bare
name** (e.g. `ModuleA.Foo`/`ModuleB.Foo` both trimming to `"Foo"`), skip that name — do not guess,
matching `disambiguate`'s "return nil rather than guess" philosophy; an optional refinement worth
one test if implemented is a location-based tiebreaker (does the occurrence's own location fall
within the nominal's own file or one of its extensions' files) before falling back to skip.
**Reframe, don't investigate, the "direct vs. transitive bases" question**: relation occurrences
are physical clause references in source, so transitivity has nowhere to come from; the real,
worth-checking question is whether conformances declared in *other files'/modules'* extensions of
the same nominal are included (very likely yes, and correct/desirable — the index covers the whole
build, not just one file).

**Nesting-mismatch fallback, only where Phase I2 can't reach**: Phase I2 only resolves a reference
when the nominal being queried already has a real USR. It can't help when that nominal's own USR
never resolved at all (e.g. the extension-only-type limitation `DeclarationLinker`'s own header
comment already documents, or a nested declaration whose own qualified placeholder never matches a
bare-name reference to it — confirmed as a real, separate bug by directly reading
`SyntacticIdentity.typeUSR(_:)` vs. `typeUSR(named:)`). For that residual case, add a small,
careful fallback in `relink`/`rewritten(_:)`: if a direct `usrRewriteMap` lookup misses for a
bare-name placeholder, search the map's keys for any qualified key ending in `.<name>` — apply the
rewrite **only if exactly one such key exists**; multiple matches must fall through unresolved
rather than guess (same "never guess" philosophy as `disambiguate`).

## Phase I3 — Per-member duplication dedup

`Sources/swift-isolation-map/ExternalIsolationBackfill.swift`'s `resolveDeclarationLevelTriggers`:
per the Plan-agent review, **dedup here, not in `DeclarationExtractor`** —
`IsolationInferenceEngine.swift` (confirmed by direct reading) reads
`declaredInSameFileAsPrimaryDefinition`/`declaredInSameContextAsWitness` per-declaration off
`declaration.conformances` (rule 8), meaning each member's own copy is semantically load-bearing,
not accidental duplication; changing extraction would need auditing every consumer of
`.conformances` for no real benefit here.

**Corrected per external review — cache-and-apply, not skip-and-leave.** Merely skipping a
duplicate (nominal-type USR, unresolved-need) pair without also applying the *result* of the first
attempt to every later copy would leave those later copies still `syntactic:`, silently losing
rule 8's input on those members — the same failure as Phase I2's own member-vs-nominal correction,
by a different route. The pair map must store the resolution *outcome*
(`pairKey → resolvedUSR-or-unknown`), keyed and shared with Phase I2's own per-nominal
`bareName → realUSR` map (per that phase's point 4 — one implementation, not two), and rewrite
**every** subsequent copy of that pair from the stored outcome, not just skip attempting it again.
If Phase I2 lands with its own correction (querying and rewriting all copies from one per-nominal
map), Phase I3's own residue becomes just the genuinely-unresolvable pairs — the two phases sharing
one keying scheme is exactly why this matters.

## Phase I4 — End-to-end trace of the specific `NotificationsListViewInput` failure

Per the task doc's own insistence (confirmed necessary by the Plan-agent review too): even though
Phase I2 should fix this specific case's *symptom* (assuming
`NotificationsListViewController`'s own USR resolved, which its real, visible `c:@M@Ls_net_ru@objc
(cs)NotificationsListViewController(im)...` USRs in the corpus strongly suggest), trace *why*
`buildUSRRewriteMap`'s own direct resolution failed for `NotificationsListViewInput`'s own
declaration — confirmed via `grep -rn "protocol NotificationsListViewInput" Project Iris` to be a
**top-level** declaration (not nested, so Phase I2's nesting-fallback doesn't apply here) — to
understand whether there's a *third*, still-undiscovered failure mode. Add a temporary debug print
at `buildUSRRewriteMap`'s lookup point (`candidatesByLocation[LocationKey(location: location)]`)
for this specific declaration's own location, following the task doc's own suggested method.

**Per external review, print the placeholder byte-compare first, before the location diff** — even
confirmed top-level, if any same-named declaration exists anywhere in the extracted corpus (Pods
sources included, currently in scope) a collision-dedup `#offset` suffix on the declaration side
could break map-key identity in a way invisible to the location-based probe. The print costs
nothing and should come first regardless of what the location diff would otherwise show. Fix
whatever it reveals, or document it as a real, narrower residual limitation if Phase I2 already
covers it in practice and no further linker bug is found.

**Traced against the real `Project Iris` corpus (2026-07-27). Result: a third, deeper failure mode, not
any of the previously hypothesized ones.** A temporary scratch test (extracted the real file,
queried the real DerivedData index store directly, then deleted per this project's standing
"revert every temporary diagnostic" discipline) showed:

- `DeclarationExtractor.extractWithContext` produces **no `DeclarationInfo` at all** for
  `NotificationsListViewInput` — not a wrong USR, not a location mismatch, not an `#offset`-suffix
  collision. Confirmed by directly reading `DeclarationExtractor.swift`: `ProtocolDeclSyntax` is
  only ever visited in `TypeIndexBuilder`'s pass (to record a protocol's own global-actor attribute
  into `protocolGlobalActorNames`, if it has one) and in `FileWideNameCollector`'s pass (to record
  its bare name into `fileWideNames.protocolNames`) — the main `DeclarationVisitor` (pass 3, the
  one that actually calls `emitTypeDeclarationIfNeeded`/`declarations.append`) has **no
  `ProtocolDeclSyntax` override at all**. This is `DeclarationExtractor`'s existing, deliberate
  design: a protocol's isolation contribution is modeled entirely through the separate
  `protocolGlobalActorNames` merged map (populated regardless of whether the protocol itself is
  ever linked), never through `declarations[protocolUSR]`. `buildUSRRewriteMap`'s failure isn't a
  bug in its own matching logic at all — there was simply never a `DeclarationInfo` for it to
  resolve.
- `NotificationsListViewController` itself extracts correctly (confirmed:
  `superclassUSR = "syntactic:BaseLuxuryViewController"`,
  `conformances = ["syntactic:UITableViewDataSource", "syntactic:UITableViewDelegate",
  "syntactic:NotificationsListViewInput"]`, a direct, non-extension inheritance clause — not the
  dominant corpus shape, but a real one).
- The real index has `NotificationsListViewInput` as `s:9Ls_net_ru26NotificationsListViewInputP`.
  Querying `baseTypeUSRs(forUSR:)` on `NotificationsListViewController`'s own real usr
  (`c:@M@Ls_net_ru@objc(cs)NotificationsListViewController`) returns all four real base
  types/protocols **including this one**, confirming **Phase I2 already resolves this specific
  conformance's placeholder to the correct real USR**, entirely independent of whether
  `NotificationsListViewInput` itself ever gets its own `DeclarationInfo`.

**Conclusion, per this phase's own explicit escape hatch ("or document it as a real, narrower
residual limitation if Phase I2 already covers it in practice"): documented, not further patched.**
Extracting protocols as their own `DeclarationInfo` would be a real, separate, larger architecture
change (SE-0466 default-isolation eligibility never applies to protocols themselves; protocol
*requirement* members' own containing-type/path tracking would need auditing too, since
`DeclarationVisitor` never pushes a type-scope for a protocol body either) — out of Gap B's own
Definition of Done, not attempted here. Practical consequence, honestly stated: because
`linked.declarations[protocolUSR]` can never be populated for *any* project-local protocol,
`ExternalIsolationBackfill`'s "already known locally, skip the oracle entirely" short-circuit never
fires for a conformance to a plain protocol with no global-actor attribute of its own (this exact,
common VIPER shape) — Phase I2 still correctly resolves the USR, and Phase I3's per-nominal dedup
still bounds the cost to one live oracle query per distinct (nominal, protocol) pair rather than
one per member, which remains the dramatic win Gap B promises; it is just not a full zero-cost
short-circuit for this specific shape. No further linker bug found; `NotificationsListViewInput`'s
own case is otherwise fully explained.

## Phase I5 — Re-verify and close out

- Re-add the same env-gated diagnostic shape used to find Gap A and Gap B (short-circuit +
  hit/miss logging in `ExternalIsolationBackfill`'s two trigger loops), measure the new
  `syntactic:`-prefixed miss fraction and the *distinct-pair* residue (per Phase I3's reframed
  metric) against `Project Iris`, revert after use.
- If the improvement is dramatic, attempt one real, complete (non-diagnostic-shortcut) `Project Iris` run
  and report the actual wall-clock time and `External oracle: N resolved` count honestly.
- Full `swift test -c release` suite green throughout (207 tests currently).
- Update `docs/priority-3-compiled-dependency-isolation.md` and
  `docs/task-gap-b-declaration-linker-real-scale.md` with real before/after numbers; write the
  small, separate Pods-in-scope research note (deferred item, not a Gap B fix).
- Update project memory.

## Sequencing

I1 (isolated) can land first, standalone. I2 is the core fix and should land as one unit with its
own direction-verification test. I3 is independent of I2 and can land in parallel/either order. I4
is investigative — do it alongside I2's implementation (its outcome may reveal I2 needs an
adjustment) rather than strictly after. I5 is last. **Per external review, one addition**: the
shared member→nominal derivation that both I2 (querying the nominal, not the member) and I3
(keying dedup on nominal-type USR) depend on is a small prerequisite unit — since `containingTypeUSR`
already supplies it, this is not a new lookup mechanism, just a shared helper — and it lands with
whichever of I2/I3 is implemented first, so the other can reuse it rather than deriving it a
second, divergent way.

## Verification

- New unit test for I1: **per-shape normalization** (per external review Correction 2), one case
  each for attribute-stripping (`@unchecked Sendable`), generic-stripping (`Container<Int>` →
  `"Container"`), rightmost-name (`Namespace.Proto` → `"Proto"`), and skip-entry (`~Copyable`) —
  replacing the single `@unchecked Sendable` case originally planned.
- New live test for I2's `.baseOf` direction (the empirical gate, same discipline as Gap A), **its
  fixture including an extension-declared conformance** (per external review Correction 4), not
  just a direct `class C: P` conformance, since extension-declared conformance is the corpus's
  dominant real shape.
- Extended `DeclarationLinkerUnitTests.swift`/`DeclarationLinkerTests.swift` coverage for I2's
  third pass: a project-local protocol resolves via the relation query; an external protocol
  resolves the same way; a same-bare-name-collision case correctly skips rather than guesses; **and
  a member-copy-rewritten assertion** (per external review Correction 1) — the *member's* copy of
  the nominal's conformance, not just the nominal's own entry, is asserted rewritten after the pass.
- New unit test for I3's dedup (same pair attempted twice across two members only queried once),
  **asserting both halves** (per external review Correction 3): the second copy is not re-queried,
  *and* the second copy is rewritten from the first attempt's cached outcome, not left `syntactic:`.
- Full `swift test -c release` green throughout.
- The `Project Iris` diagnostic re-measurement (I5) is the decisive real-world check, written up per this
  project's standing convention. I5's measurement, metrics, and honest-wall-clock reporting stand
  exactly as originally written.
