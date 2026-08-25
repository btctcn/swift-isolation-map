# Task: closure-level isolation attribution (issue #33)

Tracks [issue #33](https://github.com/btctcn/swift-isolation-map/issues/33). Closes the gap
documented as "Finding 2" in `docs/task-baseof-duplicate-occurrence-collision.md`: a call
physically inside an isolated closure literal (`Task { @MainActor in ... }`,
`DispatchQueue.main.async { ... }`) was misreported as an unprotected `nonisolated -> @MainActor`
high-risk boundary, because `IndexStoreDB`'s call graph has no notion of anonymous closures as
their own isolation scope.

**Status: shipped.** Rules A, B, and C are all implemented, tested, and gated against a full,
real-project re-run. Rule C's own implementation record is in "Rule C (issue #41)" below. One
accept-list extension (issue #40) shipped separately; see "Deferred, tracked separately" at the end
for what's still open.

## Step 1 -- Hypothesis

`IndexStoreDB`'s `.calledBy` relation attributes a call site to the nearest *named* enclosing
declaration only. Anonymous closure literals are not indexed as symbols in their own right, so a
call written inside `Task { @MainActor in ... }` is attributed to the enclosing method itself --
`nonisolated` -- with no signal that the call is actually protected by the closure's own isolation.
Hypothesis: recording every closure literal's source range and any global-actor attribute on its
signature, then substituting that isolation for the *specific call sites* inside it (never the
enclosing declaration's own resolved isolation, which stays correct everywhere else), closes the
false-positive direction without touching `IsolationInferenceEngine` (Priority 1, deliberately
unmodified throughout this project).

## Step 2 -- Spike

Every claim below was checked against a real toolchain (Xcode 26.4, Swift 6.3) or real project
data, not assumed -- the full, round-by-round verification record lived outside this repository
during design review (`/Users/ab/Downloads/closure-isolation-attribution.md`, 14 rounds, per
explicit instruction to keep exploratory drafts out of git); this section keeps only the confirmed
conclusions that shaped the shipped design.

**Confirmed real, empirically:**
- `Task { @MainActor in ... }`, `DispatchQueue.main.async { ... }`, and
  `DispatchQueue.main.asyncAfter(deadline:execute:)` all suppress the
  `nonisolated -> @MainActor` diagnostic (zero diagnostics on a faithful reduction), under both
  `-swift-version 6` and `-swift-version 5 -strict-concurrency=complete`.
- `DispatchQueue.global().async { }` does **not** suppress it (the control case), nor does a
  custom `DispatchQueue.toMain(_:)` wrapper found in the audited corpus -- the SDK's special-casing
  is a property of the exact `DispatchQueue.main` declaration, not something that propagates
  through a user-defined wrapper with a plain `@escaping () -> Void` parameter.
- Recognition **must** be an accept-list (`{MainActor} ∪ every type declared @globalActor in the
  analyzed source}`), not an exclusion list. `takesClosure { @Sendable in ... }` compiles with
  **zero diagnostics** -- `@Sendable` is legal in the exact same closure-signature-attribute
  position as a global actor but isn't one. An exclusion list would have trusted it and suppressed
  a real finding; the accept-list correctly falls back to unknown/inherits. Property-wrapper
  attributes (`@State`, `@StateObject`, `@ObservedObject`) were checked too and are **not** a
  collision risk -- each is a hard, categorical `attribute @X is not supported on a closure` parse
  error, distinct from this recognition problem entirely.
- The premise the accept-list's safety argument rests on -- "the source this tool parses compiles"
  -- is usually true, never guaranteed (`SyntaxAnalysis` parses disk bytes independent of build
  success), but this project's existing content-hash staleness detection
  (`Sources/ProjectResolution/Staleness.swift`) already catches most drift with a hard stop before
  a report is even produced, so the accept-list's fail-safe behavior is a second line of defense,
  not the only one.
- A severity split relevant to prioritizing the mirror direction: `Task.detached`/`@concurrent`'s
  own de-isolated self-call is a **hard compile error** (confirmed directly, plus a controlled
  comparison isolating the true cause: a locally-declared function with an identical closure-
  parameter shape but no `@preconcurrency` produces the identical diagnostic ID as a hard error).
  `DispatchQueue.global().async`/`.asyncAfter`'s is only a **warning**, because the real SDK's
  `Dispatch.swiftinterface` declares those specific overloads `@preconcurrency`. This means the
  mirror direction's entire practical weight (code that compiles clean today and silently ships a
  real risk) falls on the `DispatchQueue` forms, not `Task.detached`.

**Measured against Project Iris** (`docs/reference-project-corpora.md`), before writing any
production code:
- **Mirror-direction population: 0.** Zero `Task.detached { }` anywhere in app source; the two
  real `DispatchQueue.global().async { }` occurrences found are both in plainly `nonisolated`
  types, not candidates. Decisively below the "materially larger than 7" bar set for bundling Rule
  C into this change -- deferred, see below.
- **Accept-list conservatism: 0.** All 9 real closure-signature attribute occurrences in the whole
  corpus are `@MainActor`. The design's own motivating counterexamples (`@Sendable`, a custom
  `@globalActor`) are confirmed-real by direct compilation, not by inspecting this corpus's code --
  worth stating plainly rather than implying they were observed defects.
- Neither measurement changes the design (both arguments were always about worst-case/toolchain-
  upgrade safety, not this corpus's current shape) -- they close the two open prerequisites the
  design could not otherwise resolve without writing code.

## Step 3 -- Documentation (this document)

Written after implementation, alongside the code and its real-corpus verification, per this
project's usual practice of updating a task doc's own status as work lands rather than leaving a
stale "not started" header (see `docs/README.md`'s own index notes on several older docs that made
that mistake).

## Step 4 -- Code

**Prerequisite, shipped first and separately measured:** `FileWideNameCollector`
(`Sources/SyntaxAnalysis/DeclarationExtractor.swift`) recognized `@globalActor` only on
`ActorDeclSyntax`. SE-0316 permits `struct`/`enum`/`final class` too ("a global actor type can be a
struct, enum, actor, or final class") -- widened to all four, with an explicit `final`-modifier
check on the `ClassDeclSyntax` case. That check is not redundant even though a non-final
`@globalActor` class is a hard compile error (confirmed: `error: non-final class 'X' cannot be a
global actor`) -- `SyntaxAnalysis` can be run on a file that doesn't currently compile (see the
staleness discussion above), and this is the one place in the design where leaning on "it always
compiles" would fail *unsafely* (a broken file's non-final class would inject a name into a
project-wide accept-list). One line of modifier inspection buys immunity to that.

**Main change:**
1. **New extraction pass** (`Sources/SyntaxAnalysis/ClosureIsolationExtractor.swift`,
   `ClosureIsolationExtractor`/`ClosureLiteralRecord`): walks every closure literal in a file,
   recording its exact range (1-based line, UTF-8-byte column -- the same convention
   `IndexStoreDB` locations already use project-wide), the attribute name on its own signature (if
   any), and, for Rule B, its enclosing call's receiver/member spelling if it's the trailing
   closure or an `execute:`-labeled argument of a member-access call. Records evidence only; makes
   no classification decision (a project-wide accept-list, assembled after every file's own
   extraction, is needed for that -- no single file's pass can know whether a name denotes a global
   actor declared in a *different* file).
2. **`ExtractionResult`/`FileAnalysisResult`** (`DeclarationExtractor.swift`,
   `Sources/ProjectResolution/FileAnalyzer.swift`) thread two new per-file facts alongside the
   existing `protocolGlobalActorNames`: this file's own `globalActorNames` (from
   `FileWideNameCollector`) and its `closureLiteralRecords` -- the same "per-file fact that only
   means something once merged across files" shape `protocolGlobalActorNames` already established.
3. **Project-wide merge + classification** (`Sources/IndexStoreIntegration/DeclarationLinker.swift`,
   `link(_:)`): unions every file's `globalActorNames` into one accept-set
   (`mergedGlobalActorNames.formUnion(...)`, the same merge pattern already used for
   `mergedProtocolGlobalActorNames`, just a set union instead of a dictionary merge since there's no
   collision policy to choose), then classifies every closure record via
   `classify(_:knownGlobalActorNames:)`:
   - **Rule A**: the closure's own signature attribute, tested against the accept-set --
     `.globalActor(name:)` if recognized, `nil` ("unknown/inherits") otherwise. Subsumes
     `Task { @MainActor in }`, `Task(priority:) { @MainActor in }`, capture lists
     (`Task { @MainActor [weak self] in }`), and any user-defined global actor, all for free -- no
     hardcoded enclosing-call shape.
   - **Rule B**: a closure whose enclosing call is specifically `DispatchQueue.main.async`/
     `.asyncAfter` classifies as `.globalActor(name: "MainActor")` even with no attribute of its
     own, since the SDK's special-casing lives in the framework's declaration, invisible to Rule A.
     Deliberately narrow (matched on the literal receiver text `"DispatchQueue.main"`) -- the
     `toMain(_:)` finding in Step 2 is the empirical reason a broader "anything that eventually
     reaches `.main.async`" rule would be wrong, not just broader.
   - Classified closures are grouped by file into `LinkedAnalysis.closuresByFile`.
4. **Applied at exactly one point** (`Sources/swift-isolation-map/AnalysisReportBuilder.swift`,
   `build`'s edge-mapping step): for each cross-isolation edge, the innermost closure (by call-site
   containment; `effectiveCallerIsolation(atLine:column:in:)` in `ClosureIsolationExtractor.swift`)
   whose range contains the edge's own call-site location decides that edge's caller isolation --
   never an outer enclosing closure's, even when the innermost one is itself unrecognized (that's
   exactly how an unattributed inner closure "punches a hole" in an outer recognized one, e.g.
   `DispatchQueue.global().async { ... }` nested inside `Task { @MainActor in ... }`). No enclosing
   recognized closure at all falls back to the declaration's own resolved isolation, unchanged.
   **Never implemented as skipping the edge**: a call from inside a recognized closure into a
   *different* global actor's isolated state is still a genuine boundary and must still be reported
   -- only the substituted isolation value changes, nothing about `IsolationInferenceEngine`'s own
   declarations/edges, or any *other* edge from the same declaration, is touched.

**Deliberately not built in this change:** Rule C (`Task.detached`, non-`main` `DispatchQueue`s, a
confirmed de-isolating attribute) -- see "Deferred, tracked separately."

## Step 5 -- Tests

- **`Tests/SyntaxAnalysisTests/DeclarationExtractorTests.swift`**: four new cases for the collector
  widening -- `struct`/`enum`/`final class`-spelled `@globalActor` recognized; a non-`final` class
  attributed `@globalActor` is **not** recognized (the one place the design leans on a check instead
  of the "it compiles" premise).
- **`Tests/SyntaxAnalysisTests/ClosureIsolationExtractorTests.swift`** (new): raw-evidence
  extraction (signature attribute capture, trailing-closure and `execute:`-labeled-argument receiver/
  member capture, nested closures each getting their own correctly-contained range, a column-
  accounting regression fixture with a preceding non-ASCII line) and `classify(_:)`'s Rule A/B logic
  in isolation (recognized name, `@Sendable` and an arbitrary undeclared name both falling to
  unknown/inherits, `DispatchQueue.main.async`/`.asyncAfter` matching, `DispatchQueue.global()` and
  a `toMain`-shaped wrapper not matching).
- **`Tests/swift-isolation-mapTests/AnalysisReportBuilderTests.swift`**: five new cases at the
  `build()` level (no real project needed) -- direct protection, the §7.2 innermost-closure
  regression (an unrecognized closure nested inside a recognized one is not protected), the §7.4
  invariant (a call to a *different* global actor from inside a recognized closure is still
  reported, not dropped), an unattributed `Task { }` leaving behavior unchanged, and
  `DispatchQueue.main.async` vs `.global().async` on identical shapes producing opposite outcomes.
- **New real fixture project**: `~/GlobalActorFixture` (outside this repo, alongside Project Iris
  and SQLumen -- a from-scratch SPM package, not derived from either), created specifically because
  neither real corpus this project validates against contains a single `@globalActor` declaration
  of *any* spelling. Exercises all four SE-0316 spellings end to end through a real build/index/
  report cycle, not just `SyntaxAnalysis`-level unit tests -- confirmed the collector widening
  resolves `struct`/`enum`/`final class`-spelled actors correctly in a real report, and doubles as
  a minimal real reproduction of issue #33 itself (`highRiskBoundaries` went from **4 to 0** after
  the fix, one edge per global-actor spelling).
- Full suite: **277 tests in 16 suites, all passing**, `swift test -c release` (this project's
  standing rule: debug builds segfault intermittently with `IndexStoreDB` linked).

## Step 6 -- Documenting results

**Real-corpus gate**, re-run against Project Iris end to end (full build, index, link, external
oracle, report) with `--oracle-workers 8`, before and after this change:

- **Collector widening alone**: byte-identical to the pre-widening baseline (as content -- the
  8-worker merge's array *order* is not deterministic across separate runs, a pre-existing,
  already-documented property of oracle-worker merging, not something this change affects; compared
  as multisets, not raw byte-for-byte). Expected: Project Iris has zero `@globalActor` declarations
  of any spelling, so there is nothing for the widening to find on this specific corpus -- the
  `GlobalActorFixture` project above is what actually exercises it.
- **Full change (Rule A + B)**: of the app-code (excluding vendored Pods and the test target)
  high-risk boundaries, **exactly 7 disappeared, 0 appeared, and every one of the retained edges is
  byte-identical in content to the pre-fix baseline** -- the same rigor as every other correctness
  gate in this project (a diff, not an eyeball check). The 7 are the exact 5 real locations/7 edges
  already on record (3 edges at the original `Cart.swift` example from issue #33 itself, 4 more
  single-edge locations) -- not a new, different set. The absolute baseline count measured this
  session (235 distinct app-code high-risk edges before the fix, not the historically-cited 247) is
  real corpus drift over time, unrelated to this change -- a real, evolving app accumulates and
  fixes its own findings between audits; the disappeared/appeared counts, not the absolute baseline,
  are the actual gate criterion, and they match exactly.
- One incidental, correct, non-gated observation while diffing: a handful of *medium*-risk edges
  (callee isolation itself unresolved by the external oracle) also picked up a corrected
  `callerIsolation` display (`nonisolated` -> `globalActor(MainActor)`) without changing `risk` --
  expected, since the fix applies to every call site inside a recognized closure, not only the ones
  in the specific high-risk sample previously audited by hand.
- A real, pre-existing, unrelated data property surfaced while diffing, not introduced by this
  change: 9 pairs of byte-identical duplicate call-graph edges (same caller/callee/file/line,
  presumably `IndexStoreDB` reporting the same real call twice via two relations) exist in Project
  Iris's raw edge list both before and after -- symmetric across the diff, doesn't affect the gate.

## Step 7 -- PR

Next.

## Rule C (issue #41)

Implemented after Rules A/B shipped, once real evidence (see below) justified the work.

**Attribute inventory** (the one prerequisite Step 2 flagged as correctness-critical, since a
missed de-isolating attribute here is a missed false negative, unlike Rule A's fail-safe
accept-list): checked directly against a real toolchain, not `Attr.def` alone.
`swift/include/swift/AST/DeclAttr.def`/`TypeAttr.def` list `concurrent`, `nonisolated`, and
`isolated`(`(any)`) as isolation-related attribute spellings; real compilation narrowed this to
exactly one closure-literal-legal spelling: `{ @concurrent in ... }` compiles and genuinely
de-isolates (a `@MainActor` self-call inside it is a hard error). `{ nonisolated in ... }`,
`{ @nonisolated in ... }`, `{ nonisolated(nonsending) in ... }`, and `{ @isolated(any) in ... }`
are each rejected outright -- `'nonisolated'/'isolated' is a declaration modifier, not an
attribute` / `'nonisolated' is not supported on a closure`. No accept-list needed for this rule the
way Rule A needs one: one fixed, unambiguous spelling, not an open set.

**`Task.detached { }` and non-`main` `DispatchQueue.async`/`.asyncAfter`**: both already produced
the exact evidence `classify(_:knownGlobalActorNames:)` needs (`enclosingCallReceiver`/
`enclosingCallMember`) with zero extraction-side changes -- confirmed directly by running the
existing `ClosureIsolationExtractor.extract` against real probe files, not assumed from the shape
matching Rule B's own receiver/member capture. Real compilation confirmed the severity split Step 2
predicted: `Task.detached { self.touch() }` (touch() `@MainActor`) is a hard `error:`; `DispatchQueue
.global().async { self.touch() }` is only a `warning:`, both still real findings this tool should
surface.

**A real architectural gap, found only by writing the most valuable fixture first and watching it
fail** (`Task.detached { self.someMainActorMethod() }`, written inside an already-`@MainActor`
method calling another `@MainActor` method): `IsolationInferenceEngine.crossIsolationEdges()`
compares only *declared* caller/callee isolation, with no notion of closures at all -- since both
sides are declared the same actor, this edge never reached `AnalysisReportBuilder.build()`'s own
closure-substitution step in the first place. Fixed by iterating `engine.callGraph` directly
instead of the pre-filtered `crossIsolationEdges()`, including an edge when *either* the declared
view crosses (Rule A/B's own existing case, unaffected) *or* the closure-corrected effective view
crosses (Rule C's new case) -- a strict superset of the previous edge set when no closure applies,
confirmed by the real-corpus gate below showing zero changes to any previously-reported edge.

**A second real regression, also only found via the real-corpus gate, not anticipated in the
original design**: broadening the edge set the way above also exposed calls whose *effective*
caller isolation is now `.nonisolated` (via Rule C) reaching a confirmed-`.nonisolated` callee --
the existing "isolated caller reaching confirmed nonisolated callee is never a risk" suppression
was gated on `isIsolated(callerIsolation)`, which a nonisolated caller (naturally, or via Rule C)
never satisfied, so a shape that could never previously reach that carve-out (declared
nonisolated -> declared nonisolated was never "crossing" under the old declared-only filter) now
did, and wasn't suppressed -- 10 spurious new "medium" edges on the real-corpus gate below, all real
instances of exactly this shape. Fixed by dropping the `isIsolated(callerIsolation)` half of that
condition entirely: the carve-out's own stated reasoning ("nonisolated imposes no isolation
requirement on its caller... regardless of which actor the caller is isolated to") never actually
depended on the caller being isolated, so this is the carve-out's own correct, general form, not a
new judgment call. This also, as a verified-correct side effect, suppresses `unspecified ->
confirmed nonisolated` edges that predate this change entirely (a caller this tool has no
declaration for calling a confirmed-safe nonisolated callee, e.g. vendored-dependency-internal
calls and a real, already-known cross-target-scoping gap in `MindboxNotification.swift` -- spot-
checked directly against real source, not just counted: every sampled case is a genuine, already-
safe call into stdlib/SDK primitives, e.g. `Dictionary` subscript/`DispatchQueue.async` itself, not
a hidden finding).

**Real-corpus gate**, before/after against Project Iris (`--oracle-workers 4`, deduplicated by
`(callerUSR, calleeUSR, file, line)` per this doc's own established precedent for the pre-existing
IndexStoreDB duplicate-edge quirk):
- **0 edges disappeared, 0 common edges changed risk/isolation** -- Rules A/B's existing, tested
  behavior is completely unaffected.
- **5 new edges appeared**, all genuine: `nonisolated -> globalActor(MainActor)`, `.high`. Spot-
  checked at the source, not just counted -- e.g. `MapViewController.mapView(_:regionDidChangeAnimated:)`
  writes `self?.selectedCoordinateRegion` (a `@MainActor` property) from inside
  `DispatchQueue.global(qos: .userInitiated).async { }`; `OrdersCell`'s prefetch handler calls
  `self.model?.loadMore?(callback)` the same way -- real, previously-invisible risk, exactly Rule
  C's own motivating shape.
- **244 previously-reported `unspecified -> nonisolated` "medium" edges correctly suppressed** by
  the carve-out generalization above (see that section for the direct source-level verification this
  isn't hiding a real finding).
- `highRiskBoundaries`: 1481 -> 1486 (exactly the 5 new high-risk edges, nothing else moved).

## Resolved, tracked separately

- **[Issue #40](https://github.com/btctcn/swift-isolation-map/issues/40)**: Rule A's accept-list
  originally could only ever see global actors declared in *parsed* source, so a global actor
  vended by a compiled dependency fell to unknown/inherits. Shipped: `BulkSymbolGraphExtractor` now
  detects a type's own literal `@globalActor` attribute during the extraction it already runs and
  threads the discovered names into the same accept-list Rule A/C both trust.
