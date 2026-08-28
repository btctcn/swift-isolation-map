# Unsafe escape hatches, `@preconcurrency`, and severity diagnostics — scope

Tracks [issue #117](https://github.com/btctcn/swift-isolation-map/issues/117).

**Status: PR1 implemented locally (shapes 1-3: `@unchecked Sendable`, `nonisolated(unsafe)`,
`@preconcurrency` declaration-trigger with `containingTypeUSR`-level lookup, `.preconcurrencyConformance`
informational-only, `.uncheckedSendable.isMutable` deferred as `nil`) — code, tests, and real-corpus
verification all done (Steps 4-6); not yet committed or opened as a PR (Step 7). Every design
decision in this document was checked against a real compiler run, real source (SE-0423's own text,
this codebase's own extractor), or both — not asserted from reasoning alone; three rounds of review
each surfaced a real, checked-and-fixed gap (the conformance-downgrade mechanism, the Gap C3
generalization, and type/extension-level `@preconcurrency` propagation), and each one's own
regression guard is now a real, passing test, not just a note in this document. 581/581 tests
passing (21 new), real-corpus verified against Project Iris (Step 6). PR2 (shape 4,
`@preconcurrency import`) has two spikes still open and deliberately not blocking PR1: the
`.path`-vs-index-store module-name comparison for Clang submodules, and the `@CM@`-qualifier lookup
direction.

## Step 1 — Hypothesis

`AnalysisReportBuilder`'s own doc comment already admits the gap this document scopes: `risk` is
"structural, resolved-isolation-kind-based... not `@unchecked Sendable`/`nonisolated(unsafe)`-aware
data-race detection." By the time a project compiles, every cross-isolation call is already either
`await`-ed or uses one of several explicit escape hatches Swift itself provides — but none of those
hatches are currently visible anywhere in the report. A team can be "passing" Swift 6 strict
concurrency checking while quietly relying on `@unchecked Sendable`/`nonisolated(unsafe)` on every
mutable class, and the tool has no way to say so.

A second, related gap surfaced in the same discussion: the report gives no structured reasoning for
*why* a given edge is `low`/`medium`/`high` beyond `explanation()`'s generic per-bucket sentence
(`AnalysisReportBuilder.swift:352`), and has no notion at all of a *softened* severity — a
structurally-`high` edge whose real-world compiler enforcement is weaker because of `@preconcurrency`
attribution somewhere along the boundary.

Four independent shapes are in scope:
1. `@unchecked Sendable` conformance on a type.
2. `nonisolated(unsafe)` on a stored property.
3. `@preconcurrency` on a declaration or a single protocol conformance.
4. `@preconcurrency import Foo` at the top of a file.

(3) and (4) were initially going to be deferred — `docs/isolation-rules.md`'s Gap C3 already
concluded `@preconcurrency` "needs no `DeclarationInfo` field and no `IsolationInferenceEngine`
resolution logic" and punted its reporting-layer implications to an undesigned "Priority 3." That
conclusion about *isolation resolution* still holds and is not revisited here — this document is
exactly the "Priority 3" C3 deferred, now being designed.

## Step 2 — Spike (verified against real syntax trees, not guessed)

**`nonisolated(unsafe)`** — confirmed via `swift-frontend -dump-parse` on a real snippet
(`nonisolated(unsafe) var mutableCounter: Int`): parses as a `nonisolated_attr` with an explicit
`unsafe` marker. Confirmed the equivalent in `SwiftSyntax` (the library this project actually
parses with, not the compiler's internal AST) by reading the generated node definitions directly:
`DeclModifierSyntax.name.text == "nonisolated"` plus `DeclModifierSyntax.detail: DeclModifierDetailSyntax?`
whose own `.detail: TokenSyntax` carries `"unsafe"`
(`.build/checkouts/swift-syntax/.../syntaxNodes/SyntaxNodesD.swift`). The existing modifier check at
`DeclarationExtractor.swift:553`/`:783` (`modifiers.contains(where: { $0.name.text == "nonisolated" })`)
does not currently distinguish plain `nonisolated` from `nonisolated(unsafe)` — both are already
correctly treated as `.nonisolated` for isolation *resolution* (accurate, no bug there), but the
`(unsafe)` detail is simply never read anywhere today.

**`@unchecked Sendable`** — `AttributedTypeSyntax.attributes: AttributeListSyntax`
(`.build/checkouts/swift-syntax/.../SyntaxNodesD.swift`), the same node
`DeclarationExtractor.normalizedInheritedName` (`DeclarationExtractor.swift:136-150`) already
unwraps via `attributed.baseType` — but the function's own doc comment (line 131) confirms it
*discards* the attribute deliberately, keeping only the base type name for conformance-name
matching. `AttributeListSyntax.contains(named:)` already exists (`DeclarationExtractor.swift:485`)
and is already used for `"globalActor"`/`"preconcurrency"` elsewhere — the exact same helper
detects `"unchecked"` with no new parsing code.

**`@preconcurrency` on a conformance** — identical shape to `@unchecked Sendable` above (same
`AttributedTypeSyntax`, same discarded-attribute situation, same `contains(named: "preconcurrency")`
call). **`@preconcurrency` on a declaration/member** — identical shape to the existing
`node.attributes.contains(named: "globalActor")` checks already scattered through
`DeclarationExtractor.swift` (lines 186/193/200/214/etc.) — no new mechanism needed, just a new call
site.

**Checked directly, real compiler, in response to review — does a bare-function `@preconcurrency`
behave like Gap C3's test, and does a type-level `@preconcurrency` cover its own unannotated
members?** Gap C3's own snippet (`docs/isolation-rules.md:418`) is a bare function; SE-0337's own
text frames the mechanism around "nominal declarations," so generalizing from one function-shaped
test to the whole "declaration-level `@preconcurrency`" category (as the first pass of this document
did implicitly) needed the same scrutiny the conformance trigger just got — and turned up a real
gap. Ran directly (`xcrun swiftc -swift-version 6 -typecheck`):

```swift
@preconcurrency @MainActor func annotatedFunc() {}
@MainActor func plainFunc() {}

@preconcurrency @MainActor class AnnotatedType {
    func method() {}   // no attribute of its own
}

@MainActor class PlainType {
    func method() {}
}

nonisolated func caller() {
    annotatedFunc()             // warning
    plainFunc()                 // error   (control)
    AnnotatedType().method()    // warning -- method itself carries no @preconcurrency
    PlainType().method()        // error   (control)
}
```

Two confirmed facts: (1) a bare function's own `@preconcurrency` reproduces Gap C3's result exactly
— same mechanism, no separate case. (2) `@preconcurrency` on a **type** downgrades the diagnostic
for a call to that type's own **unannotated** method — the softening is inherited from the
containing declaration, not re-stated per member. This is the far more common real-world shape
(annotate a legacy type once, not every one of its methods), and it means checking only the
callee's own `attributes.contains(named: "preconcurrency")` — as Step 3 originally specified —
would systematically **under-trigger** the downgrade for exactly this shape: the opposite direction
from the conformance bug (a missed downgrade leaves the report stricter than the compiler actually
is, rather than looser), but the same root cause — a check that doesn't match where the real
softening actually comes from. Design correction, folded into Step 3 below: the declaration-trigger
lookup must check the callee's own attribute **or** walk up to `DeclarationInfo.containingTypeUSR`
and check that type's own attribute — no new infrastructure, `containingTypeUSR` already exists
(`IsolationCore/DeclarationInfo.swift:10`) and this is the same shape of containment-lookup the
codebase already does elsewhere (e.g. `enclosingExtensionIsolation`). **Not yet checked, flagged as
a real remaining gap rather than assumed either way:** whether the softening also propagates through
class *inheritance* (a subclass of an `@preconcurrency`-annotated class, calling a method the
subclass itself declares) — plausible by the same logic, not tested, non-blocking for PR1 but worth
a follow-up spike before relying on it.

**Checked, given this project's own history of extension-specific bugs (Gap A/C):** does an
`extension AnnotatedType { func extMethod() {} }` member get the same softening as a method declared
in the type's own body? Added a fifth/sixth case to the same real `swiftc` snippet —
`AnnotatedType().extMethod()` also produces a warning, `PlainType().extMethod()` (control) still
errors. Confirmed in the codebase this isn't luck: `emitMember`
(`DeclarationExtractor.swift:676-687`) is the single path that builds `DeclarationInfo` for a member
declared in a type's own body *or* in an extension of it, and `containingTypeUSR` is computed
identically in both cases — `SyntacticIdentity.typeUSR(named: qualifiedTypeName)`, keyed only by the
tracked type name, with no separate extension-specific branch that could diverge. The
containment-walk fix above is therefore correct for the extension case by construction, not by
coincidence.

**`@preconcurrency import Foo`** — confirmed via direct read of `ImportDeclSyntax`'s generated
definition: `ImportDeclSyntax.attributes: AttributeListSyntax` and `.path: ImportPathComponentListSyntax`
(`.build/checkouts/swift-syntax/.../SyntaxNodesGHI.swift`). Same `contains(named:)` helper detects
the attribute; `.path` gives the imported module path. This is the one shape with **no existing
analog anywhere in the codebase** — confirmed by grep, there is no per-file import-attribute
extraction today at all.

**Not spiked, flagged in review — `.path`'s string does not verifiedly match the index store's
module-name string.** The spike above only confirms `.path`'s own parse shape, not that its text is
byte-identical to whatever `indexstore_shim_unit_reader_get_module_name` reports for the same real
target. The concrete failure case to check before trusting a naive comparison: a Clang-submodule
import (`import Dispatch.Introspection`, or any framework with an `explicit module` clause in its
modulemap) — `.path` would carry the full dotted component list (`Dispatch`, `Introspection`), while
every real `@CM@<Module>@@`-qualified USR already seen in this codebase's own docs names only the
top-level umbrella module (`c:@CM@UIKit@@objc(cs)UIView...` — always `UIKit`, never a dotted
submodule form, per `docs/task-external-property-accessor-usr-mismatch.md`). That's suggestive that
index-store module names are always top-level, never dotted, but it's evidence from a *different*
data source (a USR qualifier) than the one this comparison actually needs (a unit's own module-name
string) — **not the same claim, not yet verified as the same value.** Required before Step 4: a real
fixture importing a known Clang submodule, run through the same real index-store path
`RawIndexStoreClient` already uses, comparing `path`'s first component (the working hypothesis, not
a confirmed fix) against the unit's actual `indexstore_shim_unit_reader_get_module_name` output. This
matters specifically because legacy/ObjC frameworks with submodules are exactly where
`@preconcurrency import` is most commonly reached for in practice — the case most likely to be
silently broken by getting this wrong is also the case the feature most needs to cover.

**Module-name plumbing gap, confirmed by grep — the real cost driver for shape (4):** module name is
read today only at the raw index-store *unit* level, for module-scoping filtering
(`indexstore_shim_unit_reader_get_module_name`, `RawIndexStoreClient.swift:354`), and goes no
further. `DeclarationInfo` (`IsolationCore/DeclarationInfo.swift`) has no `moduleName` field at all.
Resolving "does this edge's callee live in a module this file `@preconcurrency import`-ed" requires
a new `USR -> moduleName` fact threaded from the index-store unit level through
`DeclarationLinker`/`ExternalIsolationBackfill` into `AnalysisReportBuilder` — a new cross-cutting
data path, not a localized change like (1)-(3).

**Flagged in review, not yet spiked — same risk class as PR #81's Amendment 3:** any lookup keyed
by a USR that comes off a call-graph edge can receive a `@CM@<Module>@@`-qualified USR for a Clang/
ObjC symbol even when the data structure being looked into is keyed unqualified, or vice versa —
confirmed real and already handled once, for a *different* lookup, in
`RawIndexStoreClient.owningPropertyUSR(forUSR:)` (lines 165-172): try the USR directly, and only if
that finds nothing, retry with `Self.strippingClangModuleQualifier(usr)` applied. The new
`USR -> moduleName` side map is exactly this same shape of lookup, fed by the same call-graph-edge
`calleeUSR` path, and **must** be built the same way — a single `moduleName(forUSR:)`-style function
that tries the direct USR first and falls back to the stripped form internally, never a raw
dictionary a call site queries directly. Getting this wrong has a silent, not a loud, failure mode:
a qualifier mismatch means the lookup simply finds nothing, so `@preconcurrency import` quietly
stops matching for ObjC-imported callees specifically — precisely the population most likely to be
imported with `@preconcurrency` in the first place (legacy ObjC frameworks predating Swift
concurrency annotations). Which side (the side map's keys, or the edge's `calleeUSR`) actually
carries the qualifier in practice is not yet known and must be checked directly against a real
`@CM@`-bearing edge before Step 4, not assumed from the `owningPropertyUSR` precedent.

## Step 3 — Documentation (this document)

### Report shape

New top-level `escapeHatches: [EscapeHatchFinding]` array on `AnalysisReport` (not folded into
`nodes`/`edges` — a per-declaration or per-import fact, not a caller/callee pair):

```swift
public struct EscapeHatchFinding: Codable, Equatable, Sendable {
    public let kind: EscapeHatchKind   // .uncheckedSendable, .nonisolatedUnsafe,
                                        // .preconcurrencyDeclaration, .preconcurrencyConformance,
                                        // .preconcurrencyImport
    public let declarationUSR: String? // nil for .preconcurrencyImport (module-level, not a USR)
    public let name: String            // type/property/function/module name, for display
    public let isMutable: Bool?        // .nonisolatedUnsafe (var vs let) / .uncheckedSendable
                                        // (class has mutable stored properties) only; nil otherwise
    public let location: AnalysisLocation
}
```

`isMutable` drives the only risk judgment this array itself makes: a mutable `nonisolated(unsafe)
var` or an `@unchecked Sendable` class with mutable stored properties is flagged materially
differently from an immutable `let`/value-type case in any future consumer or `--severity`-style
filter on this array — deferred to whenever this array grows its own filtering flag, not designed
here.

**`isMutable` for `.uncheckedSendable` is not spiked and was wrongly stated as settled above —
correction.** For `.nonisolatedUnsafe`, `isMutable` is free: `var` vs `let` is read directly off the
same `DeclModifierSyntax`/binding keyword Step 2 already confirmed. For `.uncheckedSendable`, "does
this class have mutable stored properties" is a genuinely separate, unscoped task: it means walking
the type's member list and, for each property, distinguishing a stored `var` from a computed
property (no backing storage, not a race risk the same way), handling property wrappers (the
wrapper's own storage, not the projected value, is what's actually stored), and deciding whether an
inherited mutable stored property from a superclass counts (it does, semantically, but resolving it
means walking the superclass chain, which may not be in the same file or even the same module). None
of this was spiked. Before Step 4, either (a) spike the member-list walk as its own small task and
size it honestly, or (b) ship `.uncheckedSendable` findings in v1 with `isMutable: nil` always (the
conformance itself is still real, useful, zero-cost information on its own) and defer the
mutability judgment to a follow-up once sized. **Decided: (b).** Same class of unscoped
cross-module/cross-file work as the module-name plumbing already split into PR2 — deferred for the
same reason, not sized here.

### Severity downgrade — **Variant A, confirmed** — trigger set corrected after review

When a structurally-`high` edge's boundary is softened by `@preconcurrency` on the **callee's own
declaration**, or by the **callee's module** being `@preconcurrency import`-ed in the caller's file,
`risk` on that `AnalysisEdge` reports the **downgraded** value (`.medium`), not the structural one —
confirmed as the right call specifically *because* SE-0337 changes the compiler's own diagnostic
severity (error → warning) at the *use site*, unlike `isAwaited`/`isUnknown`, which document real
facts that never change the compiler's actual enforcement and so were deliberately kept orthogonal
to `risk` (`docs/task-await-aware-risk-classification.md`).

**A `@preconcurrency`-attributed conformance is deliberately excluded from this trigger set —
originally included, wrong, caught in review.** The first pass of this document modeled a
conformance-level `@preconcurrency` (`class Widget: @preconcurrency P {}`) the same as the
declaration/import cases: downgrade any edge reaching that type. Checked directly against SE-0423's
own text, and that model is wrong about the actual mechanism: `@preconcurrency` on a conformance
"is scoped to the implementation of the protocol requirements in the conforming type" — it
suppresses a **one-time witness-checker diagnostic**, at the conformance declaration itself, that
checks whether the type's method implementations satisfy the protocol's isolation requirements. It
is explicitly **not** a broad softening of call-site diagnostics: SE-0423's own text states "the
compiler will continue to emit diagnostics inside the module when called from off the main actor."
A direct call to that type's method — unrelated to the protocol, or even a call *through* the
protocol from elsewhere — gets no softening at all from this attribute. Modeling it as an edge-risk
downgrade would have meant the tool under-reports risk for a call the compiler itself still treats
as a full error — wrong in the dangerous direction, and a direct violation of this project's own
Guiding Principle ("a tool that gives an incorrect concurrency-safety result is worse than no tool
at all"). A `@preconcurrency`-attributed conformance is still recorded as an `EscapeHatchFinding`
(kind `.preconcurrencyConformance`) — it's real, useful information about where a witness check was
softened — but it is **informational only** and never feeds the edge-downgrade mechanism.

Consequence, stated explicitly rather than left implicit: `--severity`, `--sort=severity`,
`summary.highRiskBoundaries`, and the exit code (`report.summary.highRiskBoundaries > 0`) all follow
the downgraded value. A `@preconcurrency`-softened edge stops failing a CI gate keyed on high-risk
boundaries, matching what the compiler itself now enforces at that boundary.

**Scoped deliberately to `high` -> `medium` only, not `medium` -> `low` — the reason, stated
explicitly rather than left for the reader to guess.** The empirical basis for "`@preconcurrency`
downgrades the compiler's own diagnostic from error to warning" is `docs/isolation-rules.md`'s Gap
C3 test — and, worth being precise about since precision is exactly what this section got wrong
once already, that test's own snippet (`@preconcurrency @MainActor func` called from a `nonisolated`
context) is **declaration-level `@preconcurrency`**, not conformance-level. It's the correct
empirical basis for the declaration/import trigger this section now scopes to, and was never
evidence for the conformance trigger removed above — worth naming so the mistake above isn't
repeated in a different shape later. Separately from the conformance question, that test also
exercised specifically the classic `nonisolated`-caller-reaches-isolated-state
shape — exactly what `risk == .high` means by definition (`riskLevel`'s own doc comment: "a
`nonisolated` caller reaching `.actor`/`.globalActor` state"). `risk == .medium` is a grab-bag
("everything else that's still cross-isolation," including `.unspecified` on either side) that was
never verified to be a hard compiler *error* in the first place for every one of its sub-shapes —
if a given `.medium` edge isn't an error today, `@preconcurrency` has nothing to downgrade it from,
and applying the same mechanical one-level-down shift there would be an unverified, possibly
incorrect claim, which this project's Guiding Principle rules out making without evidence. PR1 ships
`high -> medium` only, on the specific evidence that supports it. Whether any `.medium` sub-shape is
itself an error `@preconcurrency` would soften to `.low` is an open, unverified question, deliberately
deferred — not assumed symmetric, not assumed inapplicable.

`AnalysisEdge` gains two fields to keep the "why" traceable without re-deriving it:
```swift
public let structuralRisk: RiskLevel?   // present only when it differs from `risk` (i.e. a real downgrade happened); nil otherwise
public let severityRationale: String?   // e.g. "structurally high (nonisolated -> @MainActor); downgraded to medium: callee is @preconcurrency-attributed"
```
Both defaulted/optional in `Decodable`, same pattern as `isUnknown`'s original introduction, so
existing JSON without these fields still decodes. `explanation` itself is left as-is for the
non-downgraded case — it already gives a reasonable generic rationale per bucket
(`AnalysisReportBuilder.swift:352`); `severityRationale` only exists when there's something extra to
say.

**Deferred, not designed here:** with the conformance trigger removed, PR1 has only one downgrade
trigger (declaration-level `@preconcurrency`), so `severityRationale` as a single string is
unambiguous. PR2 adds a second, independent trigger (`@preconcurrency import`) on the same edge
shape — a single edge could in principle satisfy both at once (a `@preconcurrency`-declared function
in a module the caller also `@preconcurrency import`-ed). What `severityRationale` says when both
fire simultaneously isn't specified yet; revisit when PR2 is actually designed, not before.

The new top-level `escapeHatches: [EscapeHatchFinding]` field on `AnalysisReport` needs the same
treatment, missed above: default it to `[]` on decode (same reasoning as the two `AnalysisEdge`
fields) so that JSON written by any version of this tool before this array existed still decodes
under a newer schema without an explicit migration.

### New `DeclarationInfo`/`ProtocolConformance` fields

- `ProtocolConformance` (`IsolationCore/DeclarationInfo.swift:100`) gains `isPreconcurrency: Bool`
  (informational only, per the correction above — never read by the downgrade lookup).
- `DeclarationInfo` gains `hasPreconcurrencyAttribute: Bool`, set when *this specific declaration*
  carries the attribute. **The downgrade lookup must not stop there** — confirmed by direct
  `swiftc` test above, `@preconcurrency` on a type softens diagnostics for that type's own
  unannotated methods too. The lookup used by the edge-downgrade mechanism is therefore: callee's
  own `hasPreconcurrencyAttribute`, **or**, when the callee has a `containingTypeUSR`, that type's
  `DeclarationInfo.hasPreconcurrencyAttribute` — a one-level containment walk using a field that
  already exists (`IsolationCore/DeclarationInfo.swift:10`), not new plumbing. Inheritance-based
  propagation (a subclass of an annotated class) is unchecked and not part of this lookup for now
  (see the spike note above).
- New per-file extractor (name TBD, e.g. `PreconcurrencyImportExtractor`) producing
  `[file: Set<moduleName>]`, threaded through the same `ExtractionResult` /
  `FileAnalysisResult` / `LinkedAnalysis` shape `awaitedRangesByFile` already uses
  (`docs/task-await-aware-risk-classification.md` Step 4 is the template).
- New `USR -> moduleName` side map, sourced from the already-read
  `indexstore_shim_unit_reader_get_module_name` value, threaded through `DeclarationLinker`.

### Out of scope, deliberately

- Real data-race detection — still a structural heuristic, same caveat as the rest of the tool.
- `mermaid`/`dot` annotation of escape hatches or downgrades — `json`-only for v1; a call-graph
  diagram is the wrong place to also encode per-declaration facts, and forcing it in now is exactly
  the scope-creep this whole roadmap discussion is trying to avoid.
- Any change to `IsolationKind` resolution from `@preconcurrency` — Gap C3's conclusion stands
  unchanged; this document only adds a reporting-layer effect.
- `// SAFETY:`-comment / suppression-comment interaction (separate design,
  `docs/task-suppression-comments.md`).
- Intersecting escape-hatch findings with real cross-isolation edges from the call graph (e.g. "this
  `@unchecked Sendable` class is actually reached from 6 different isolation domains") — a strong
  future idea, not this pass.

**These two are mechanically different, worth stating so Step 4 doesn't quietly grow the wrong
one.** The severity-downgrade mechanism above is a **local, bounded lookup**: given one edge's
`calleeUSR` (and the caller's own file, for the import case), answer one yes/no question against
that declaration's own `hasPreconcurrencyAttribute`, or its immediate `containingTypeUSR`'s (one
level up, no further), or its module being in the caller-file's `@preconcurrency import` set —
`ProtocolConformance.isPreconcurrency` no longer participates here, see the correction above — and
never looks at any other edge or finding. The deferred "reached from 6 different isolation domains"
idea directly above is an **aggregation across the whole `escapeHatches`/`edges` set** — for one
finding, count or enumerate every edge elsewhere in the report that touches it. The second is a
materially larger, different-shaped piece of work; do not fold it into the downgrade lookup's
implementation.

### Sequencing recommendation

Shapes (1)-(3) (`@unchecked Sendable`, `nonisolated(unsafe)`, `@preconcurrency`
declaration/conformance) are all local to a single file's own syntax tree plus the existing
`DeclarationInfo`/`ProtocolConformance` structures — no new cross-cutting data path. Shape (4)
(`@preconcurrency import`) is the one that needs the new `USR -> moduleName` plumbing end to end.
Recommend splitting into two PRs so the first isn't blocked on designing/validating the new
module-name path — **and the conformance-trigger correction above shrinks PR1 further, which makes
this split safer, not just smaller:** the only downgrade trigger left in PR1 is declaration-level
`@preconcurrency`, with its own direct empirical basis (Gap C3's exact test snippet). **PR1** =
shapes (1)-(3) (including `.preconcurrencyConformance` as an informational-only `EscapeHatchFinding`,
never a downgrade trigger) + the `structuralRisk`/`severityRationale`/downgrade mechanism
(declaration-triggered only) + `escapeHatches` array, with `.uncheckedSendable` findings carrying
`isMutable: nil` (Step 3 decision above). **PR2** = shape (4), extending the same downgrade
mechanism to the import-triggered case once the module-name side map exists, and its own
qualifier-normalization/submodule-name spikes are done. **Confirmed with the user** — this is the
plan, not a proposal awaiting sign-off.

## Step 4 — Code

Done. `ProtocolConformance`/`DeclarationInfo` gained `isUnchecked`/`isPreconcurrency`/
`hasPreconcurrencyAttribute`/`isNonisolatedUnsafe` (`IsolationCore/DeclarationInfo.swift`);
`DeclarationExtractor.swift` populates them (`TypeIndexEntry`'s two new conformance-attribute sets,
`applyInheritance` and the extension visitor both feeding them, `emitMember`/`emitTypeDeclarationIfNeeded`
reading them into `DeclarationInfo`/`ProtocolConformance`); `OutputFormat/AnalysisReport.swift` gained
`EscapeHatchKind`/`EscapeHatchFinding`, `AnalysisReport.escapeHatches`, and `AnalysisEdge.structuralRisk`/
`.severityRationale` (all with the same decode-default pattern `isUnknown`/`isAwaited` established);
`AnalysisReportBuilder.swift` gained `escapeHatchFindings(from:)` and `preconcurrencyDowngradeReason(...)`,
the latter implementing exactly the declaration-or-containingType lookup Step 3 specifies, deliberately
never consulting `ProtocolConformance.isPreconcurrency`.

## Step 5 — Tests

Done. 21 new tests: 11 in `Tests/SyntaxAnalysisTests/DeclarationExtractorTests.swift` (each new
extraction flag, both true and false cases, plus the extension-conformance case), 7 in
`Tests/swift-isolation-mapTests/AnalysisReportBuilderTests.swift` (escape-hatch assembly, the
declaration-trigger downgrade, the containing-type-trigger downgrade, the conformance-never-downgrades
regression guard, the high-only-not-medium scoping guard), 3 in
`Tests/swift-isolation-mapTests/AnalysisEdgeCodableTests.swift` (JSON round-trip and old-JSON-still-decodes
for the new fields). Full suite: 581/581 passing (560 pre-existing + 21 new).

**The `containingTypeUSR` invariant tech debt flagged during review is closed, not just noted**:
`DeclarationExtractorTests.swift`'s `containingTypeUSRMatchesBetweenBodyMemberAndExtensionMember`
(confirmed present at that name, confirmed passing in the full run above) asserts equality between a
type-body member's `containingTypeUSR` and a same-type extension member's — the exact regression
guard proposed when the extension-propagation question was checked in Step 2, so a future refactor
that split extension handling into its own path would now fail a test instead of silently diverging.

## Step 6 — Documenting results

Real-corpus run against Project Iris (`~/ios`, `lsboutique.xcworkspace`/`ls.net.ru`, ~2200 real
files, 41739 nodes / 1537 edges / 28351 types analyzed, `highRiskBoundaries: 1462`):

| | value |
|---|---|
| `escapeHatches` (any kind) | 0 |
| `AnalysisEdge`s with `structuralRisk` set (a real downgrade fired) | 0 |

Zero findings, and confirmed this is correct rather than a silent extraction failure: a direct
`grep -rn` across the entire real `~/ios` tree (app code + all Pods) found `nonisolated(unsafe)`
0 times, `@unchecked Sendable` 0 times, and `@preconcurrency` exactly once --
`ProductReturnDownloadRequestViewController.swift:10`, `@preconcurrency import WebKit`. That one
real occurrence is shape (4) (`@preconcurrency import`), the one shape PR1 deliberately does not
detect (see Sequencing recommendation) -- so PR1 correctly finds nothing on this corpus not because
extraction is broken, but because every declaration/conformance-level escape hatch this corpus
could have is genuinely absent, and the one real escape hatch it does have is out of PR1's scope by
design, not by oversight. A useful, if unexciting, real-world data point for the design doc's own
motivating question (are teams quietly relying on these hatches): at least on this one real,
~2200-file, pre-Swift-6-strict-concurrency corpus, they currently aren't -- worth re-checking after
PR2 ships shape (4), and worth re-checking against a second real corpus before drawing any general
conclusion from a sample of one.

Zero regressions: full `swift test` -- 581/581 passing (560 pre-existing + 21 new: 11 in
`DeclarationExtractorTests`, 7 in `AnalysisReportBuilderTests`, 3 in `AnalysisEdgeCodableTests`).

## Step 7 — PR

Next.
