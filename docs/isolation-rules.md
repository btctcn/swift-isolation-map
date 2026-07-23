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

`IsolationRuleSet` classes are not one-per-Swift-version. Each one is named after the version
that introduced a change to isolation *semantics* (what gets inferred, and how), and its
`SwiftVersionRange.upperBound` is "the last version this has been reviewed and confirmed still
accurate for" — not a hardcoded end-of-life. `SwiftVersionRange.contains(_:)` compares
major.minor component-wise and both bounds are inclusive. Current boundaries:

| Rule set | Range | Why it starts there |
|---|---|---|
| `Swift5RuleSet` | 5.0–5.10 | Pre-Swift-6; no mandatory strict concurrency |
| `Swift6RuleSet` | 6.0–6.1 | Strict concurrency became mandatory; no default-isolation mechanism yet |
| `Swift62RuleSet` | 6.2–6.3 | SE-0466 shipped in 6.2, adding the opt-in `-default-isolation` flag |

**Why there's no `Swift63RuleSet`:** nothing changed. This isn't an assumption from matching
the local toolchain version — it was checked against
[`download.swift.org/swift-evolution/v1/evolution.json`](https://download.swift.org/swift-evolution/v1/evolution.json)
(`jq -r '.proposals[] | select(.status.version == "6.3")'`, cross-referenced against
`(?i)actor|isolat|concurren|sendable` in title/summary). The only 6.3 proposal in that space is
SE-0481 (`weak let`) — it relaxes a *mutability* restriction on weak references for Sendable
purposes, but doesn't touch isolation inference, inheritance, or defaulting, so `Swift62RuleSet`
folding 6.2 and 6.3 together is correct rather than assumed.

Same check for the `Swift6RuleSet` boundary: 6.0 has several concurrency-relevant proposals
(SE-0414 Region based isolation, SE-0420 Inheritance of actor isolation for closures, SE-0423
dynamic isolation enforcement, SE-0430 `sending` parameters, SE-0431 `@isolated(any)`, SE-0434
usability of global-actor types) — none of them change the 4-tier resolution model this engine
implements; they're mostly about closures/call-graph mechanics relevant to Priority 2, not
Priority 1's inference rules. 6.1 has SE-0449 ("Allow `nonisolated` to prevent global actor
inference"), which only expands *where* `nonisolated` is legal to write syntactically — it
doesn't change what an already-resolved `nonisolated` attribute means, which is all this engine
cares about (it consumes `DeclarationInfo.explicitIsolation`, already resolved past that
syntactic question). So 6.0–6.1 sharing one rule set is also correct, not assumed.

**Forward-looking flag, not yet actioned:** the same dataset shows SE-0518 (`~Sendable` for
explicitly marking non-`Sendable` types) already implemented and tagged version 6.4 — ahead of
the local toolchain (6.3). This is a concrete reason `Swift62RuleSet.upperBound` stops at `"6.3"`
rather than being left open-ended: when `swift-version-watch.yml` eventually flags Swift 6.4,
SE-0518 (and anything else tagged 6.4 by then) needs a real review for isolation-inference impact
before deciding whether `upperBound` simply extends or a new rule set is needed — not a
reflexive bump.

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
| 9 | Swift 5 / Swift 6 (pre-6.2): no default-isolation mechanism exists; unattributed, uninherited declarations are `nonisolated` | SE-0466 didn't exist before Swift 6.2 | `swift5And6NeverDefaultToMainActor` | Not applicable (absence of a mechanism, nothing to compile) |
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

## Known gaps for a future pass

- Rule 8's dedicated fixture (witness inference without whole-type inference, in a genuinely
  separate-file extension) hasn't been independently compiled yet — currently only unit-tested
  against the fixture model, not cross-checked against `swiftc`.
- `isEligibleForModuleDefaultIsolation` (rule 12) is not yet computed from real declaration
  shape; it's an engine input, correct by construction in fixtures but unimplemented for real
  SwiftSyntax/IndexStoreDB data (Priority 2).
- `@preconcurrency`, extension isolation override, and nested types are listed as required
  coverage in the architecture spec's testing section but are not yet modeled at all.
