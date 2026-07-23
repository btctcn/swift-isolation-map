# Isolation rules — checklist and coverage

Tracks every isolation-inference rule implemented in `IsolationInferenceEngine` and
`IsolationRuleSet` against its source of truth, per the priority order in
[the architecture spec, section 1.5.1](../.). Empirical validation (compiling real snippets
with `swiftc`) is mandatory for any rule marked "inherited" below — see
[Empirical validation](#empirical-validation).

## Resolution priority (as implemented, corrected from the original spec sketch)

1. Explicit isolation attribute on the declaration itself (`explicitIsolation`), or the fact
   that the declaration *is* an actor type (`isActorType`).
2. Isolation inherited from a containing type, superclass, or protocol conformance — resolved
   recursively, so a container that itself only reaches isolation via rule 3 still propagates.
3. The rule set's module-level default isolation (SE-0466) — only reached if nothing in 1-2
   applied, and only for declarations `isEligibleForModuleDefaultIsolation`.
4. `.nonisolated` fallback.

**This reorders the architecture spec's original 4-tier list** ("explicit → containing type →
default → protocol conformance"). SE-0466's own exclusion list rules out default-isolation for
any declaration with "inferred actor isolation from a superclass, overridden method, protocol
conformance, or member propagation" — so protocol-conformance inference is not a lower-priority
fallback after the default, it's part of the same inheritance tier that pre-empts the default.
Verified in `protocolConformanceInferenceBeatsConfiguredDefault`
(`Tests/IsolationCoreTests/IsolationInferenceEngineTests.swift`).

## Rule set version boundaries

**One `IsolationRuleSet` type per Swift version in this tool's actively-reviewed range
(6.0–6.3), even when its behavior is byte-identical to the previous version.** This was a
deliberate decision, revised from an earlier range-based design during PR #2's review.

The original design had `SwiftVersionRange.upperBound` silently cover multiple versions (e.g.
one `Swift62RuleSet` spanning 6.2–6.3), on the reasoning that duplicating an identical class
per version was pointless churn. The counter-argument that won: **explicitness about "nothing
changed" matters more than avoiding duplication here.** With per-version types, supporting a
new Swift release always means the same uniform action — add a new type — whether or not its
body differs from the previous one. A range design instead has two different possible actions
(bump a field vs. add a class) depending on a judgment call that's easy to make carelessly.
Per-version types also mean each version gets its own git-blameable, reviewable commit stating
"I checked this version, here's what I found" — a stronger audit trail than an edit to a
range's `upperBound`, and more in line with this project's "never silently assume" principle
than the range design actually was.

Concretely: `Swift60RuleSet`, `Swift61RuleSet`, `Swift62RuleSet`, `Swift63RuleSet` are four
separate types in `Sources/IsolationCore/IsolationRuleSet.swift`. Each one's
`SwiftVersionRange` is a single-point range (`lowerBound == upperBound`) representing exactly
that version — `SwiftVersionRange` itself wasn't removed, since a degenerate one-point range is
a natural special case of the same `contains(_:)` matching logic the registry already needed.
`Swift5RuleSet` is the one deliberate exception: Swift 5.x stays a single bucket (5.0–5.10)
rather than eleven near-empty types, because it predates this tool's primary audience (Swift 6
strict-concurrency migrators) and isn't under the same version-by-version review discipline as
6.0–6.3.

| Rule set | Version | Why it exists as its own type |
|---|---|---|
| `Swift5RuleSet` | 5.0–5.10 (bucket) | Pre-Swift-6; not the tool's primary audience — see exception above |
| `Swift60RuleSet` | 6.0 | Strict concurrency became mandatory; no default-isolation mechanism yet |
| `Swift61RuleSet` | 6.1 | Identical body to 6.0 — SE-0449 only changes *where* `nonisolated` may be written, not what it resolves to |
| `Swift62RuleSet` | 6.2 | SE-0466 shipped here, adding the opt-in `-default-isolation` flag |
| `Swift63RuleSet` | 6.3 | Identical body to 6.2 — SE-0481 (`weak let`) is a Sendable/mutability change, not an isolation-inference one |

**The "identical to previous" claims are evidence-based, not assumed.** Checked against
[`download.swift.org/swift-evolution/v1/evolution.json`](https://download.swift.org/swift-evolution/v1/evolution.json)
(`jq -r '.proposals[] | select(.status.version == "<X>")'`, cross-referenced against
`(?i)actor|isolat|concurren|sendable` in title/summary):
- **6.0** has several concurrency-relevant proposals (SE-0414 Region based isolation, SE-0420
  inheritance of actor isolation for closures, SE-0423 dynamic isolation enforcement, SE-0430
  `sending` parameters, SE-0431 `@isolated(any)`, SE-0434 usability of global-actor types) —
  none change the 4-tier resolution model this engine implements; mostly closure/call-graph
  mechanics relevant to Priority 2, not Priority 1's inference rules.
- **6.1**: SE-0449 ("Allow `nonisolated` to prevent global actor inference") only expands
  *where* `nonisolated` is legal to write syntactically — doesn't change what an
  already-resolved `nonisolated` attribute means, which is all this engine consumes
  (`DeclarationInfo.explicitIsolation`, already past that syntactic question).
- **6.3**: the only proposal in that keyword space is SE-0481 (`weak let`) — relaxes a
  *mutability* restriction on weak references for Sendable purposes, doesn't touch isolation
  inference, inheritance, or defaulting.

**Forward-looking flag, not yet actioned:** the same dataset shows SE-0518 (`~Sendable` for
explicitly marking non-`Sendable` types) already implemented and tagged version 6.4 — ahead of
the local toolchain (6.3). This is why `Swift63RuleSet.swiftVersion.upperBound` stops at
`"6.3"` rather than being left open-ended: when `swift-version-watch.yml` eventually flags
Swift 6.4, SE-0518 (and anything else tagged 6.4 by then) needs a real review before adding
`Swift64RuleSet` — which, per the policy above, must happen as its own new type regardless of
whether the review concludes "identical to 6.3" or "something changed."

**Methodology note:** `WebFetch`'s summarization of the raw `evolution.json` (800KB+) produced
confidently wrong answers here (claimed no proposals were tagged "6.3" at all) on a first pass.
For anything requiring an exact/complete answer against a large structured dataset, download it
and query directly (`jq`, `grep`) rather than trusting a fetch-and-summarize tool's read of it.

## Rule checklist

| # | Rule | Source | Test(s) | Empirically verified |
|---|------|--------|---------|----------------------|
| 1 | Explicit attribute overrides everything, even containing-actor membership | General model (SE-0306) | `explicitAttributeOverridesContainingActor` | — (trivially implied by 2-4) |
| 2 | An actor type is isolated to itself | SE-0306 | covered implicitly by rule 3 | — |
| 3 | Instance members of an `actor` are isolated to that actor by default | SE-0306: "the instance methods, properties, and subscripts of an actor have an isolated `self` parameter" | `actorInstanceMemberInheritsActorIsolation` | Yes — `04_static_asymmetry.swift` (contrast case) |
| 4 | Static members of an `actor` are **not** actor-isolated by this rule | SE-0306: "static methods, properties, and subscripts do not have a `self` parameter ... so they are not actor-isolated" | `actorStaticMemberIsNotActorIsolated` | Yes — `04_static_asymmetry.swift`: `UserSession.shared` errors on the unrelated "nonisolated global shared mutable state" diagnostic, never on actor isolation, confirming it is genuinely nonisolated |
| 5 | A type carrying a global actor attribute (e.g. `@MainActor`) propagates it to all methods, properties, subscripts and extensions, **including static members** | SE-0316: "propagates the attribute to all methods, properties, subscripts, and extensions of the type by default" | `globalActorTypePropagatesToInstanceMember`, `globalActorTypePropagatesToStaticMemberToo` | Yes — `04_static_asymmetry.swift`: `ProfileViewModel.shared` errors "main actor-isolated static property ... can not be referenced from a nonisolated context" |
| 6 | A subclass of a global-actor-isolated class **mandatorily** inherits that isolation, and that inheritance itself propagates to the subclass's own members | SE-0316: "propagates the attribute to its subclasses mandatorily" | `subclassMandatorilyInheritsSuperclassGlobalActor` | Yes — `01_subclass_inheritance.swift`: compiler note reads "main actor isolation inferred from inheritance from class 'BaseViewModel'" |
| 7 | A type conforming to a global-actor-qualified protocol **in the same file as its primary definition** infers that actor's isolation for the whole type | SE-0316: "A non-actor type that conforms to a global-actor-qualified protocol within the same source file as its primary definition infers actor isolation from that protocol" | `sameFileProtocolConformanceInfersWholeTypeIsolation`, `differentFileProtocolConformanceDoesNotInferWholeTypeIsolation` (negative case) | Yes — `03_protocol_conformance.swift`: compiler note reads "main actor isolation inferred from conformance to protocol 'Refreshable'" |
| 8 | A witness satisfying a global-actor-isolated protocol requirement infers isolation per-member when the conformance is stated in the same type/extension as the witness, independent of rule 7 | SE-0316: "A witness that is not inside an actor type infers actor isolation from a protocol requirement that it satisfies, so long as the protocol conformance is stated within the same type definition or extension as the witness" | `perWitnessInferenceAppliesEvenWithoutWholeTypeInference` | Not yet — same underlying compiler feature as rule 7's fixture; a dedicated cross-file-extension snippet is a good v0.1 follow-up |
| 9 | Swift 5.x, 6.0, 6.1 (pre-6.2): no default-isolation mechanism exists; unattributed, uninherited declarations are `nonisolated` | SE-0466 didn't exist before Swift 6.2 | `preSwift62NeverDefaultsToMainActor` | Not applicable (absence of a mechanism, nothing to compile) |
| 10 | Swift 6.2+ without an explicit `-default-isolation` flag: still `nonisolated` by default | SE-0466: "If no `-default-isolation` flag is specified, the default isolation for the module is `nonisolated`" | `swift62DefaultsToNonisolatedWithoutExplicitOptIn` | Yes — `02_default_isolation.swift` compiled without the flag: no diagnostic |
| 11 | Swift 6.2+ with `-default-isolation MainActor`: eligible declarations default to `@MainActor` | SE-0466 detailed design: "declarations are inferred to be `@MainActor`-isolated by default" | `swift62DefaultsToMainActorWhenConfigured` | Yes — `02_default_isolation.swift` compiled with `-default-isolation MainActor` and an explicitly `nonisolated` caller: error "call to main actor-isolated instance method 'touch()'" |
| 12 | Declarations excluded from default-isolation eligibility (enum cases, typealiases, accessors, actor-type members, `SendableMetatype`-conforming types, nested types in nonisolated types) stay `nonisolated` even when a module default is configured | SE-0466 detailed design exclusion list (quoted in full in the PR description / commit introducing this file) | `nonEligibleDeclarationIgnoresConfiguredDefault` | Not yet — `isEligibleForModuleDefaultIsolation` is currently caller-supplied per fixture; computing it automatically from real declaration shape is Priority 2 work once SwiftSyntax/IndexStoreDB data is wired in |
| 13 | An unreviewed/future Swift version has no matching rule set — the tool must say so explicitly, never silently reuse the nearest known rule set | Architecture spec section 2.8 | `unsupportedFutureVersionThrows` | N/A (governance behavior, not compiler semantics) |

## Empirical validation

Per the architecture spec's sourcing hierarchy (section 1.5.1, step 5 — "empirical testing
against the real compiler ... mandatory, not optional"), the reproduction snippets that back
the "Empirically verified" column above were compiled for real with `swiftc -swift-version 6`
(Swift 6.3, `swiftlang-6.3.0.123.5`) during development of this rule set. Reproduction `.swift`
files are throwaway diagnostic captures (like the `docs/motivation.md` reproductions) and were
not added to the repository — the rule-by-rule wording above is the durable record of what was
verified and how.

## Known gaps and plan

Three gaps, three different situations — not the same kind of "TODO." Ordered here by how
soon each is actually closable, not by severity.

### Gap A — Rule 8 has no dedicated empirical fixture

**What's missing:** rule 8 (per-witness inference in a same-context-as-witness, different-file-
from-primary-definition conformance) is unit-tested against the fixture model but has never
been independently compiled with `swiftc`, unlike rules 3–7 and 9–11.

**Why it's open:** scope call made when this rule set first shipped — rule 8 exercises the same
underlying compiler feature as rule 7's already-verified fixture (`03_protocol_conformance.swift`,
"main actor isolation inferred from conformance to protocol"), just triggered by a different
scope condition, so it was judged lower marginal risk than the priority-reordering finding and
the static-member asymmetry, both of which *were* compiled.

**Plan:** compile a genuine two-file module — `Primary.swift` (the type's primary definition,
no conformance) and `Extension.swift` (`extension Type: GlobalActorProtocol { ... }` with the
witness) — via `swiftc -swift-version 6 -typecheck Primary.swift Extension.swift`. This proves
rule 7's negative case (a method in `Primary.swift` stays nonisolated) and rule 8's positive
case (the witness in `Extension.swift` is isolated) in one real compile, which a single-file
snippet can't do. Small, self-contained, no design changes needed — closable in the same style
as the existing empirical checks.

### Gap B — `isEligibleForModuleDefaultIsolation` isn't computed from real data

**What's missing:** this `DeclarationInfo` field (rule 12's SE-0466 exclusion list — enum
cases, typealiases, accessors, `SendableMetatype`-conforming types, nested types in nonisolated
types) is currently a caller-supplied fixture input, correct by construction in tests but with
no code anywhere that derives it from an actual declaration.

**Why it's open:** genuine structural blocker, not a scope call. Deriving this requires
classifying real declarations by kind and conformance — that's SwiftSyntax/IndexStoreDB data,
which doesn't exist in this codebase yet (Priority 2 hasn't started; the CLI is still a stub).
Writing this classifier against nothing would mean guessing at a shape that Priority 2 would
likely have to redo anyway.

**Plan:** not closable now. Tracked here as a concrete requirement *for* Priority 2's kickoff,
not left implicit: whoever builds the SwiftSyntax/IndexStoreDB → `DeclarationInfo` translation
layer must implement this classifier against the SE-0466 exclusion list already quoted in this
document, and should add the golden-file/fixture tests for it at that point (real declarations
of each excluded kind, compiled and checked against `expected-graph.json`, per the testing
strategy in section 4 of the architecture spec) — not as fixture-only unit tests like today's.
**See also [Gap C2](#c2--nested-types-needs-a-model-change)**: nested types add a requirement to
this same classifier that isn't obvious from the exclusion list alone — eligibility for a nested
type depends on the *enclosing type's own resolved isolation*, not just static facts about the
nested declaration itself.

### Gap C — `@preconcurrency`, extension isolation override, nested types unmodeled

**What's missing:** three additional Swift concurrency nuances listed as required test coverage
in the architecture spec's testing section (section 4). **Research is now complete for all
three** (evolution proposal → compiler source → empirical `swiftc` compilation, per section
1.5.1) — findings below. No `DeclarationInfo` fields or resolution logic exist for any of them
yet; two of the three turn out to need real engine changes, one turns out to be correctly out of
scope for this engine.

Reproduction snippets for all three were compiled for real with `swiftc -swift-version 6` (Swift
6.3, `swiftlang-6.3.0.123.5`) and, per this document's existing convention, kept as throwaway
files outside the repository — the findings below are the durable record.

#### C1 — Extension isolation override (needs a model change)

**The "may already work for free" possibility this section previously raised turned out to be
wrong.** SE-0316's detailed design has two separate propagation rules, not one:

> "A type declared with a global actor attribute propagates the attribute to all methods,
> properties, subscripts, and extensions of the type by default."
>
> "An extension declared with a global actor attribute propagates the attribute to all the
> members of the extension by default."

The second rule is an independent isolation source: an extension can carry its own global actor
attribute governing only the members declared inside that extension, distinct from whatever the
primary type itself propagates.

**Empirically confirmed:** a plain (nonisolated) class with one method in its primary body and a
second method in a separate `@MainActor extension` of the same type — the primary-body method
compiled with no isolation error; the extension method produced `error: call to main
actor-isolated instance method ... in a synchronous nonisolated context`. The two propagation
rules act independently, exactly as SE-0316 states.

**Why this isn't free:** `resolveInheritedIsolation` in `IsolationInferenceEngine.swift` only
reads `DeclarationInfo.containingTypeUSR`, `superclassUSR`, and `conformances` — there is no
field anywhere that captures "the global actor attribute declared on the extension this member is
physically inside." `DeclarationInfo` cannot express this input today.

**Required model change:** a new `DeclarationInfo` field (e.g. `enclosingExtensionIsolation:
IsolationKind?`), consumed by a new resolution step between tier 1 (explicit-on-declaration) and
tier 2 (inherited-from-containing-type) — the extension's attribute wins over the type's, but an
explicit attribute directly on the member still wins over both.

#### C2 — Nested types (needs a model change)

**Nested types are a distinct category, not "a member that happens to be a type" — confirmed by
two independent, opposite-direction empirical results.**

1. **No containing-type inheritance.** A `struct` nested inside an explicitly `@MainActor final
   class` does **not** become main-actor isolated the way an instance method would: mutating a
   nested static var produced the generic `nonisolated global shared mutable state` diagnostic
   (not a main-actor one), and calling the nested type's instance method from a `nonisolated`
   context compiled with no isolation error at all.
2. **But it does participate in the module-default eligibility gate.** SE-0466's own worked
   example is explicit that

   > "Declarations that are types nested within a nonisolated type" [are excluded from default
   > isolation]

   and its code sample shows a `struct Nested` inside a plain `class C` (itself defaulted to
   `@MainActor` under `-default-isolation MainActor`) **also** commented `// @MainActor` — nested
   types are eligible for the *module default* exactly when their enclosing type is not itself
   nonisolated. Reproduced empirically both directions: the nested type inside a
   default-eligible enclosing class became MainActor-isolated under `-default-isolation
   MainActor`; the same nested type inside an explicitly `nonisolated` enclosing type stayed
   nonisolated even with the flag on.

**Why this isn't just missing, it's a bug waiting to happen:** if a nested type were modeled
today the obvious way — pointing `containingTypeUSR` at its enclosing type, like any other member
— `resolveInheritedIsolation`'s `if case .globalActor = containingIsolation { return
containingIsolation }` branch (`IsolationInferenceEngine.swift`, tier 2) would **incorrectly**
propagate the enclosing type's global actor to it, directly contradicting empirical result 1
above. The naive way to wire nested types into the existing shape produces a wrong answer, not
just an incomplete one.

**Required model change:** `DeclarationInfo` needs an explicit `isNestedType` (or equivalent)
distinction so nested types are excluded from the tier-2 containing-type-propagation branch
entirely, and rely solely on tier 3 (module default), gated by the enclosing type's own resolved
isolation rather than a flat per-declaration bool.

**Cross-link to [Gap B](#gap-b--iseligibleformoduledefaultisolation-isnt-computed-from-real-data):**
this is the same field, `isEligibleForModuleDefaultIsolation`, that Gap B already flags as
fixture-only/not-computed-from-real-data. Gap B's classifier now has a concrete extra requirement
discovered here: for a nested type, eligibility isn't a standalone fact about the declaration
itself the way it is for enum cases/typealiases/accessors/`SendableMetatype` types — it depends on
the *enclosing type's own resolved isolation*, which means the classifier needs read access to the
engine's resolution of the enclosing type, not just static declaration-shape facts. Whoever builds
Gap B's classifier should design for this from the start rather than retrofitting it after nested
types are added.

#### C3 — `@preconcurrency` (confirmed out of scope for this engine)

**The "diagnostic severity, not resolution" hypothesis this section previously proposed is
correct, now confirmed rather than assumed.** SE-0337's detailed design says `@preconcurrency` on
a declaration only:

> "At use sites whose enclosing scope uses Minimal concurrency checking, the compiler will
> suppress any diagnostics about mismatches in these traits."
>
> "At use sites whose enclosing scope uses Strict concurrency checking, including in Swift 6 and
> later, the compiler will downgrade any such diagnostics from errors to warnings."

Nothing in the proposal describes it changing a declaration's resolved isolation.

**Empirically confirmed:** a `@preconcurrency @MainActor func` called from a `nonisolated`
context under `-swift-version 6` produced the **identical diagnostic wording** as the same call
without `@preconcurrency` ("call to main actor-isolated global function ... in a synchronous
nonisolated context") — the only difference was `warning:` instead of `error:` (exit code 0
instead of 1). The resolved isolation is unchanged; only the severity of the *mismatch*
diagnostic at the call site changes.

**Conclusion:** `@preconcurrency` needs no `DeclarationInfo` field and no
`IsolationInferenceEngine` resolution logic — `IsolationKind` resolution is unaffected by it. It
belongs to Priority 3 (risk-level/reporting: whether a cross-isolation edge is reported as an
error-equivalent or a downgraded warning), not Priority 1. No further action needed in this
engine; revisit only when Priority 3's reporting/risk-annotation layer is designed.

**Status:** research phase closed for all three. C1 and C2 are ready to be scoped as real
implementation work (new `DeclarationInfo` fields + resolution branches + empirical-backed unit
tests, same discipline as rules 1-13 above); C3 requires no further action in this engine.
