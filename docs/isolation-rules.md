# Isolation rules — checklist and coverage

Tracks every isolation-inference rule implemented in `IsolationInferenceEngine` and
`IsolationRuleSet` against its source of truth, per the priority order in
[the architecture spec, section 1.5.1](../.). Empirical validation (compiling real snippets
with `swiftc`) is mandatory for any rule marked "inherited" below — see
[Empirical validation](#empirical-validation).

## Resolution priority (as implemented, corrected from the original spec sketch)

1. Explicit isolation attribute on the declaration itself (`explicitIsolation`), or the fact
   that the declaration *is* an actor type (`isActorType`).
2. A global actor attribute on the *enclosing extension* the declaration is physically inside
   (`enclosingExtensionIsolation`) — SE-0316's second, independent propagation rule. Wins over
   the containing type's own propagation, but not over rule 1.
3. Isolation inherited from a containing type, superclass, or protocol conformance — resolved
   recursively, so a container that itself only reaches isolation via rule 4 still propagates.
   Nested types (`isNestedType`) are excluded from the containing-type-propagation part of this
   tier entirely — see Gap C2 below.
4. The rule set's module-level default isolation (SE-0466) — only reached if nothing in 1-3
   applied, and only for declarations `isEligibleForModuleDefaultIsolation`. For a nested type,
   that eligibility is computed dynamically from the enclosing type's own resolved isolation
   rather than read as a flat fact — see Gap C2.
5. `.nonisolated` fallback.

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
| 8 | A witness satisfying a global-actor-isolated protocol requirement infers isolation per-member when the conformance is stated in the same type/extension as the witness, independent of rule 7 | SE-0316: "A witness that is not inside an actor type infers actor isolation from a protocol requirement that it satisfies, so long as the protocol conformance is stated within the same type definition or extension as the witness" | `perWitnessInferenceAppliesEvenWithoutWholeTypeInference` | Yes — `Primary.swift`/`Extension.swift` two-file compile (see Gap A below): compiler note reads "main actor isolation inferred from conformance to protocol 'Refreshable'" on the witness, while an unrelated method on the same type compiles with no error |
| 9 | Swift 5.x, 6.0, 6.1 (pre-6.2): no default-isolation mechanism exists; unattributed, uninherited declarations are `nonisolated` | SE-0466 didn't exist before Swift 6.2 | `preSwift62NeverDefaultsToMainActor` | Not applicable (absence of a mechanism, nothing to compile) |
| 10 | Swift 6.2+ without an explicit `-default-isolation` flag: still `nonisolated` by default | SE-0466: "If no `-default-isolation` flag is specified, the default isolation for the module is `nonisolated`" | `swift62DefaultsToNonisolatedWithoutExplicitOptIn` | Yes — `02_default_isolation.swift` compiled without the flag: no diagnostic |
| 11 | Swift 6.2+ with `-default-isolation MainActor`: eligible declarations default to `@MainActor` | SE-0466 detailed design: "declarations are inferred to be `@MainActor`-isolated by default" | `swift62DefaultsToMainActorWhenConfigured` | Yes — `02_default_isolation.swift` compiled with `-default-isolation MainActor` and an explicitly `nonisolated` caller: error "call to main actor-isolated instance method 'touch()'" |
| 12 | Declarations excluded from default-isolation eligibility (enum cases, typealiases, accessors, actor-type members, `SendableMetatype`-conforming types, nested types in nonisolated types) stay `nonisolated` even when a module default is configured | SE-0466 detailed design exclusion list (quoted in full in the PR description / commit introducing this file) | `nonEligibleDeclarationIgnoresConfiguredDefault` | Not yet — `isEligibleForModuleDefaultIsolation` is currently caller-supplied per fixture; computing it automatically from real declaration shape is Priority 2 work once SwiftSyntax/IndexStoreDB data is wired in |
| 13 | An unreviewed/future Swift version has no matching rule set — the tool must say so explicitly, never silently reuse the nearest known rule set | Architecture spec section 2.8 | `unsupportedFutureVersionThrows` | N/A (governance behavior, not compiler semantics) |
| 14 | A global actor attribute on an *extension* isolates only that extension's members, independent of the primary type's own propagation | SE-0316: "An extension declared with a global actor attribute propagates the attribute to all the members of the extension by default" | `extensionAttributeIsolatesOnlyItsOwnMembers` | Yes — `05_explicit_member_beats_extension.swift` (see below) |
| 15 | An explicit attribute directly on a member still wins over its enclosing extension's attribute | General model — rule 1 outranks rule 2 | `explicitMemberAttributeBeatsEnclosingExtension` | Yes — same fixture: `explicitlyNonisolated()` compiles with no error, `implicitlyMainActor()` errors |
| 16 | An enclosing extension's attribute wins over the primary type's own global actor propagation | SE-0316's two propagation rules are independent; rule 2 outranks rule 3 | `enclosingExtensionOverridesTypePropagation` | Yes — `10_rule16_reverse.swift`: a `nonisolated extension` of an otherwise-`@MainActor` class compiles `nonisolatedMethod()` clean while `mainActorMethod()` (declared in the primary body) still errors |
| 17 | A nested type does **not** inherit isolation via containing-type propagation the way an instance/static member would — confirmed for both `actor` and global-actor-class containers | SE-0316's type→members propagation does not extend to nested type declarations (not itself stated as a proposal quote — established by empirical contrast against rules 3/5) | `nestedTypeInsideActorDoesNotInheritActorIsolation`, `nestedTypeInsideGlobalActorClassDoesNotInheritViaPropagation` | Yes — `06_nested_type_inside_actor.swift` (no diagnostic) and `09_nested_type_default_gate_v2.swift` (see rule 18, same fixture covers both) |
| 18 | A nested type **is** eligible for the module default when its enclosing type's own resolved isolation is not `nonisolated` — via the default tier, not inheritance — and stays nonisolated when the enclosing type is nonisolated, even with a default configured | SE-0466 detailed design: "declarations that are types nested within a nonisolated type" are excluded from default-isolation; its own worked example shows a nested type inside a non-nonisolated enclosing type picking up the default | `nestedTypeUsesModuleDefaultWhenEnclosingTypeIsIsolated`, `nestedTypeStaysNonisolatedWhenEnclosingTypeIsNonisolated` | Yes — `09_nested_type_default_gate_v2.swift` compiled with `-default-isolation MainActor`: `Outer.Nested` errors, `NonisolatedOuter.Nested` doesn't |
| 19 | A nested type's own superclass/protocol-conformance-based isolation still applies — nesting only skips the containing-type-propagation part of tier 3, not the type's own hierarchy | Consequence of rules 3 and 17 both being real, independently — not itself a separate SE citation | `nestedTypeStillInheritsFromItsOwnSuperclass` | Yes — `11_rule19_nested_type_own_superclass.swift`: `Outer.NestedState` (nested in a plain, non-isolated `Outer`) still errors calling a method inherited from its own `@MainActor` superclass `BaseState` |

## Empirical validation

Per the architecture spec's sourcing hierarchy (section 1.5.1, step 5 — "empirical testing
against the real compiler ... mandatory, not optional"), the reproduction snippets that back
the "Empirically verified" column above were compiled for real with `swiftc -swift-version 6`
(Swift 6.3, `swiftlang-6.3.0.123.5`) during development of this rule set — files `01`-`04` during
the original Priority 1 slice, `05`-`09` and `10`-`11` while implementing and then fully closing
out Gap C1/C2 (extension override, nested types) on top of the sourcing already done in Gap C's
research pass, and a two-file `Primary.swift`/`Extension.swift` module while closing Gap A (rule
8). Reproduction `.swift` files are throwaway diagnostic captures (like the `docs/motivation.md`
reproductions) and were not added to the repository — the rule-by-rule wording above is the
durable record of what was verified and how.

## Known gaps and plan

Three gaps, three different situations — not the same kind of "TODO." Ordered here by how
soon each was actually closable, not by severity. Gap A and Gap C are both closed in full; Gap B
remains open, the one genuine structural blocker of the three.

### Gap A — Rule 8 has no dedicated empirical fixture (closed)

**What was missing:** rule 8 (per-witness inference in a same-context-as-witness, different-file-
from-primary-definition conformance) was unit-tested against the fixture model but had never
been independently compiled with `swiftc`, unlike rules 3–7 and 9–11.

**Closed via a genuine two-file module** — `Primary.swift` (the protocol declaration and the
type's primary definition, no conformance) and `Extension.swift` (`extension SyncCoordinator:
Refreshable { func refresh() {} }` plus the call site), compiled together via `swiftc
-swift-version 6 -typecheck Primary.swift Extension.swift`. One real compile proved both
directions at once: `s.unrelatedMethod()` (declared in `Primary.swift`) compiled with no
isolation error — rule 7's negative case, the whole type is not inferred isolated since the
conformance isn't in the same file as the primary definition — while `s.refresh()` (the witness,
declared in `Extension.swift`, same extension as the conformance) errored with "main actor
isolation inferred from conformance to protocol 'Refreshable'" — rule 8's positive case,
confirmed independently of rule 7's outcome, exactly as SE-0316 describes.

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
**See also [Gap C2](#c2--nested-types-implemented)**: nested types added a requirement to this
same classifier that wasn't obvious from the exclusion list alone — eligibility for a nested
type depends on the *enclosing type's own resolved isolation*, not just static facts about the
nested declaration itself. The engine-side gating logic for this is now implemented (see C2
below); what's still missing is the real classifier this gap describes actually *computing*
`isNestedType`/`isEligibleForModuleDefaultIsolation`/`enclosingExtensionIsolation` from
SwiftSyntax/IndexStoreDB data — the fixture inputs are correct by construction, the derivation
from real source isn't built.

### Gap C — `@preconcurrency`, extension isolation override, nested types

**What's missing:** three additional Swift concurrency nuances listed as required test coverage
in the architecture spec's testing section (section 4). Research is complete for all three
(evolution proposal → compiler source → empirical `swiftc` compilation, per section 1.5.1), and
**C1 and C2 are now implemented** (new `DeclarationInfo` fields, new resolution logic, unit
tests, additional empirical verification of the interactions the research pass didn't cover) —
C3 needed no engine change, confirmed correctly out of scope below.

Reproduction snippets for all three were compiled for real with `swiftc -swift-version 6` (Swift
6.3, `swiftlang-6.3.0.123.5`) and, per this document's existing convention, kept as throwaway
files outside the repository — the findings below are the durable record.

#### C1 — Extension isolation override (implemented)

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

**Additional interactions verified while implementing** (not covered by the research pass above):
- `05_explicit_member_beats_extension.swift`: a `nonisolated` method directly inside a
  `@MainActor extension` compiled with no error, while a sibling method with no explicit
  attribute in the same extension errored — confirms rule 1 (explicit-on-declaration) still
  outranks rule 2 (enclosing extension), not just rule 2 outranking rule 3.
- The reverse interaction — an explicitly `nonisolated extension` of an otherwise `@MainActor`
  type — was initially exercised only in the fixture model
  (`enclosingExtensionOverridesTypePropagation`), flagged rather than silently assumed symmetric
  with the confirmed direction, and has since been independently compiled too:
  `10_rule16_reverse.swift` confirms a `nonisolated extension`'s own method compiles clean while
  a sibling method declared in the type's primary body still errors.

**Implemented as:** a new `DeclarationInfo` field, `enclosingExtensionIsolation: IsolationKind?`,
consumed by a new resolution tier in `IsolationInferenceEngine.swift` between tier 1
(explicit-on-declaration) and tier 3 (inherited-from-containing-type) — the extension's attribute
wins over the type's propagation, but an explicit attribute directly on the member still wins
over both. Tests: `extensionAttributeIsolatesOnlyItsOwnMembers`,
`explicitMemberAttributeBeatsEnclosingExtension`, `enclosingExtensionOverridesTypePropagation`
(`Tests/IsolationCoreTests/ExtensionAndNestedTypeIsolationTests.swift`).

#### C2 — Nested types (implemented)

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

**This was correctly flagged as a bug-in-waiting, not just a gap:** the naive way to wire nested
types into the pre-existing shape — pointing `containingTypeUSR` at the enclosing type like any
other member — would have made `resolveInheritedIsolation`'s containing-type-propagation branch
incorrectly inherit the enclosing type's global actor, directly contradicting empirical result 1
above.

**Additional interaction verified while implementing** (not covered by the research pass above):
`06_nested_type_inside_actor.swift` — a `struct` nested inside an `actor` (not just the `@MainActor
class` case the research pass covered) also does not inherit actor isolation: mutating and
reading it from a `nonisolated` context compiled with no error. Confirms the "nested types don't
participate in containing-type propagation" finding generalizes across both isolation sources
(SE-0306 actor-instance isolation and SE-0316 global-actor propagation), not just the one case
originally tested.

**Implemented as:** `DeclarationInfo` gained an `isNestedType: Bool` field. In
`IsolationInferenceEngine.swift`, `resolveInheritedIsolation` now skips the containing-type
propagation check entirely when `isNestedType` is true (superclass and protocol-conformance
checks still apply — those are the nested type's own hierarchy, unrelated to nesting), and a new
`resolveDefaultIsolation` method computes tier-4 eligibility for nested types dynamically:
recursively resolves the enclosing type's own isolation and only applies the rule set's default
if that resolution is not `.nonisolated`, rather than trusting a flat
`isEligibleForModuleDefaultIsolation` bool the way every other declaration kind does. Verified
with `09_nested_type_default_gate_v2.swift` (compiled with `-default-isolation MainActor`): a
nested class inside a plain, default-eligible outer class errors (inherits the default), while
the same nested class inside an explicitly `nonisolated` outer class does not (gate correctly
excludes it) — both directions in one real compile, confirming the mechanism is the default tier
picking up the *rule set's* configured actor, not containing-type inheritance smuggled back in
(also verified in the fixture tests using deliberately different actor names for the outer type's
own isolation vs. the configured default, to rule out the two mechanisms being conflated). Tests:
`nestedTypeInsideActorDoesNotInheritActorIsolation`,
`nestedTypeInsideGlobalActorClassDoesNotInheritViaPropagation`,
`nestedTypeUsesModuleDefaultWhenEnclosingTypeIsIsolated`,
`nestedTypeStaysNonisolatedWhenEnclosingTypeIsNonisolated`,
`nestedTypeStillInheritsFromItsOwnSuperclass` — the last one now also independently compiled,
`11_rule19_nested_type_own_superclass.swift`: a nested class inside a plain, non-isolated
`Outer` still errors calling a method inherited from its own `@MainActor` superclass, confirming
the inheritance is genuinely about the nested type's own class hierarchy, unrelated to nesting.

**Cross-link to [Gap B](#gap-b--iseligibleformoduledefaultisolation-isnt-computed-from-real-data):**
the *engine-side* gating logic for nested types is now implemented, but Gap B itself — actually
computing `isNestedType`/`isEligibleForModuleDefaultIsolation`/`enclosingExtensionIsolation` from
real SwiftSyntax/IndexStoreDB data rather than fixture input — remains blocked on Priority 2, as
before. What changed is that Gap B's eventual classifier now has a concrete, documented
requirement it must satisfy for nested types specifically: it needs read access to the engine's
resolution of the enclosing type, not just static declaration-shape facts about the nested
declaration itself.

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

**Status:** C1 and C2 implemented and fully empirically verified (rules 14-19 in the checklist
above, `DeclarationInfo` fields `enclosingExtensionIsolation`/`isNestedType`, new resolution
logic in `IsolationInferenceEngine.swift`, tests in
`Tests/IsolationCoreTests/ExtensionAndNestedTypeIsolationTests.swift`). C3 required no engine
changes, confirmed rather than left as a hypothesis. Gap C is now closed in full — no open items
remain from this pass.
