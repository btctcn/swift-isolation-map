# `.low` risk explanation always claims `await`, even for same-domain calls that need none

Tracks [issue #47](https://github.com/btctcn/swift-isolation-map/issues/47).

**Status: shipped.**

## Step 1 — Hypothesis

Auditing all `risk == "low"` app-code edges from a real run against Project Iris
(`docs/reference-project-corpora.md`). Hypothesis going in: the `.low` risk *level* itself might be
wrong for some of these (e.g. should some of them be `.medium` instead).

## Step 2 — Spike

All 14 low-risk app-code edges found have identical caller/callee isolation
(`globalActor(MainActor) -> globalActor(MainActor)`). Read the real source at each of their call
sites; none has an `await`. Example (`lsboutique/Redesign/Account/Presenter/AccountPresenter.swift:356`):

```swift
Task { @MainActor in
    AuthenticationService.shared.userDidLogout()
}
```

The call to `userDidLogout()` is a plain synchronous call, already running inside a `@MainActor`
closure (Rule A, issue #33), calling another `@MainActor` method -- no suspension point exists
here, and same-actor calls never need one.

**The `.low` risk level itself is correct** -- these edges are genuinely safe, and there's no
fourth "zero risk" bucket to move them to instead. The bug is narrowly in
`AnalysisReportBuilder.explanation(caller:callee:risk:)`
(`Sources/swift-isolation-map/AnalysisReportBuilder.swift`): the `.low` case unconditionally
renders `"...compiler-enforced via await"`, regardless of whether `caller` and `callee` are
actually two *different* isolation domains (a real cross needing an `await` hop) or the exact same
one.

Traced *why* an edge with literally identical caller/callee isolation strings can exist in the
report at all, since `IsolationInferenceEngine.crossIsolationEdges()` filters
`resolveIsolation(caller) != resolveIsolation(callee)` -- which would seem to exclude exactly this
shape. The answer: that filter runs on each declaration's own *declared* isolation, before
`AnalysisReportBuilder.build()`'s closure-attribution substitution (§7.2,
`docs/task-closure-isolation-attribution.md`) ever runs. In the real example above, the *declared*
isolation of the enclosing method (not the `Task { @MainActor in }` block) is what
`crossIsolationEdges()` compares against the callee's `.globalActor(MainActor)` -- genuinely
different, so the edge passes the engine's filter -- but by the time `explanation()` runs, the
*effective* caller isolation has been substituted to `.globalActor(MainActor)` too, landing both
sides on the identical string. This is the only mechanism by which a same-domain `.low` edge can
reach `explanation()` at all; a call written directly between two identically-attributed
declarations with no closure involved is filtered out by the engine before it ever becomes an edge.

## Step 3 — Documentation (this document)

## Step 4 — Code

`Sources/swift-isolation-map/AnalysisReportBuilder.swift`'s `explanation(caller:callee:risk:)`,
`.low` case:

```swift
if case .globalActor = caller, caller == callee {
    return "caller and callee share the same isolation domain (\(describe(caller))) -- no suspension needed"
}
return "crosses an actor boundary between two isolated contexts (\(describe(caller)) -> \(describe(callee))), compiler-enforced via await"
```

Deliberately scoped to `.globalActor` only, not `.actor` too: a global actor is a singleton (there
is only ever one `MainActor`), so two `.globalActor(name:)` endpoints naming the same actor are
provably the same isolation domain. This tool has no notion of actor *instance* identity, though --
only actor *type* name -- so two `.actor(name: "Cache")` endpoints could be two distinct instances
of `Cache` (or, in principle, two distinct types sharing a name across modules) genuinely needing a
real `await` between them. Claiming "no suspension needed" there would be an unconfirmed safety
claim, which this project's guiding principle ("a tool that gives an incorrect result is worse than
no tool at all") rules out. Custom-actor same-name pairs keep the existing, still-accurate-enough
"compiler-enforced via await" wording.

## Step 5 — Tests

`Tests/swift-isolation-mapTests/AnalysisReportBuilderTests.swift`:
- `lowRiskSameGlobalActorExplanationDoesNotClaimAwait`: reproduces the real
  `Task { @MainActor in }` shape via the existing closure-fixture helper; asserts the explanation
  mentions "same isolation domain" and not "await". Confirmed to fail without the fix.
- `lowRiskDifferentDomainsExplanationStillClaimsAwait`: an `actor` calling a `@MainActor` callee
  (genuinely different domains, no closure involved) still gets the "compiler-enforced via await"
  wording -- unaffected by this fix.
- `lowRiskSameActorTypeNameStillClaimsAwait`: reproduces the identical closure-substitution
  mechanism as the first test, but with an `.actor(name: "Cache")` override instead of
  `.globalActor` -- confirms the fix's scoping doesn't over-apply to custom actors, which still get
  the "compiler-enforced via await" wording.

Full `swift test -c release`: 301/301 passing.

## Step 6 — Documenting results

Presentation-only fix -- no isolation resolution, risk level, or edge count changes. Filtered the
most recent real report against Project Iris (post-#57/#58) for `risk == "low"` edges with
identical caller/callee isolation strings: **16** (up from the 14 originally found when #47 was
filed -- the small drift is expected, since #57/#58's fix shipped in between and changed which
declarations resolve at all). All 16 are `globalActor(MainActor) -> globalActor(MainActor)`; every
one now reads "caller and callee share the same isolation domain (globalActor(MainActor)) -- no
suspension needed" instead of the previous, false "compiler-enforced via await" claim.
`summary.crossActorBoundaries` and `summary.highRiskBoundaries` are unchanged, as expected for a
text-only fix.

## Step 7 — PR

Merged as [#59](https://github.com/btctcn/swift-isolation-map/pull/59).
