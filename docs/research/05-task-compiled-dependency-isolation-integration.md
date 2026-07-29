# Task: compiled-dependency isolation — integration phase

**Status: implementation task specification for dedicated future sessions, not a record of
completed work.** Successor to `task-compiled-dependency-isolation.md`, whose research
prerequisite is now fully discharged: across the five-document research thread
(`task-compiled-dependency-isolation.md` → `solution-compiled-dependency-isolation.md` →
`compiled-dependency-isolation-sourcekit-lsp-spike.md` with four addenda →
`design-deltas-after-crosscheck.md` → `research-phase-closure-usr-matching.md` →
`cursorinfo-oneshot-preverification.md`), every falsifiable claim has been verified empirically
on the reference machine (Xcode 26.4.0 / Apple Swift 6.3) and, where mechanisms mattered,
traced to real `swiftlang/swift` source. Nothing in this spec rests on an unverified assumption;
where a residual unknown exists it is named as such with a phase-gate to close it. The user's
original bar stands unchanged: a 100% solution matching real `swiftc` behavior, no heuristics or
hardcoded name lists as a source of truth.

## 1. The converged design (one paragraph, normative)

Transport: `sourcekitdInProc` loaded via `dlopen`, following the existing
`ToolchainLocating`/`libIndexStore` precedent — one in-process session per analysis run, reused
across all queries. Query: `source.request.cursorinfo` with `key.sourcefile`, `key.offset` (the
edge's already-known position from `IndexStoreIntegration`), `key.compilerargs` (Phase A output),
and `key.retrieve_symbol_graph: 1`, issued per analyzed call-graph edge whose target member's
isolation is not resolvable from project-local declarations. Result selection: strictly by USR —
the edge's member USR compared against each result's `key.usr` (top-level primary plus every
element of `key.secondary_symbols`), exact match or prefix-before-`"::SYNTHESIZED::"` match;
text-level selection of any kind is prohibited. Isolation extraction: from the matched result's
`key.symbol_graph` declaration fragments (`"kind": "attribute"`, global actor identified by the
fragment's `preciseIdentifier` USR, e.g. `s:ScM` for `MainActor`; `nonisolated` as an attribute
fragment spelling), with `key.fully_annotated_decl` XML as the documented fallback parser. Every
oracle-failure path — load failure, timeout, unresolved build settings, no USR match, malformed
response — produces an explicit `unknown` isolation state, never a silent `.nonisolated`.
`IsolationInferenceEngine` remains untouched; new facts enter at the `DeclarationLinker` layer per
the `protocolGlobalActorName` backfill precedent.

## 2. Binding requirements (non-negotiable, inherited from the research thread with their evidence)

1. **USR matching, never text.** The `DivergentIsolation` result shape (primary = the type,
   secondary = the invoked `init()`) is codified in SourceKit source as deliberate behavior; only
   USR equality selects correctly. Scanning any response for the presence of `@MainActor` is the
   confident-wrong-answer failure mode this task exists to eliminate.
2. **Per-edge queries against the actually-referenced member.** No canonical-member or
   initializer proxies for type-level isolation — member isolation legitimately diverges from
   type isolation (empirically proven). The edge's member USR and position, both already resolved
   by `IndexStoreIntegration`, define each query.
3. **`unknown` as a first-class outcome, end to end** — declarations table through
   `AnalysisReportBuilder` output. This closes the epistemic half of the original bug ("provably
   nonisolated" vs. "no idea" must never be conflated) independently of oracle coverage.
4. **Structured parse formats only**: symbol-graph attribute fragments (JSON) primary,
   fully-annotated-declaration XML fallback. Markdown (hover) is a diagnostic instrument, not a
   production input.
5. **Engine stability invariant**: `IsolationInferenceEngine` unmodified. If implementation
   uncovers a genuine reason to touch it, that is a stop-and-decide moment with its own
   documented decision, per project precedent — not an incidental edit.
6. **sourcekitd request-array construction appends at index `-1`** (`SIZE_MAX` through the
   C size type). Sequential indices crash the process (`_xpc_api_misuse`) — empirically hit,
   root-caused, and fixed during the dlopen spike; encode it in the request-builder abstraction
   so no call site can get it wrong.
7. **Standing project disciplines apply unchanged**: `swift test -c release` always (the
   IndexStoreDB-linked debug segfault); feature branch before first commit; no commits or pushes
   without explicit per-instance permission; everything repo-bound in English; empirical
   re-verification of toolchain claims on the machine that actually builds.

## 3. Phase plan

### Phase A — build-settings decision and acquisition (gate: written decision record)

The single remaining pre-implementation decision, shared prerequisite for any transport
(`key.compilerargs`). Two candidate paths, to be decided explicitly and recorded in a
`docs/*.md` decision record before Phase B code:

- **Option 1: depend on `xcode-build-server`** (third-party, Python, brew-installed). Fast to
  adopt; adds a runtime trust/distribution surface to a correctness-focused tool whose install
  story is currently self-contained SPM+Homebrew.
- **Option 2: vendor a minimal translator** — the tool already mandates `--scheme`; run
  `xcodebuild build` (or `-dry-run` where sufficient — verify empirically whether dry-run logs
  carry full `swiftc` invocations) for that scheme, parse the `swiftc` invocations from the log,
  emit the per-file compiler arguments directly. Self-contained; guarantees the oracle sees the
  *same* flags and language mode as the real build — itself a correctness requirement, since
  cursor-info answers are computed under the file's build settings.

SwiftPM projects need neither: arguments are recoverable from the package build description
(and the SwiftPM path was already proven end-to-end zero-config in the spike using this very
repository). Acceptance for the phase: compiler arguments successfully produced for **both**
real-world targets (`~/SQLumen`, scheme `SQLumen`; Project Iris, its own scheme) and for a SwiftPM
fixture, with a spot-check that a cursor-info query under those arguments resolves a real UIKit/
SwiftUI symbol on each.

### Phase B — `SourceKitDIntegration` target (dlopen wrapper)

New SPM target mirroring the `IndexStoreIntegration` shape: locate `sourcekitdInProc` within the
active toolchain (extend `ToolchainLocating`), `dlopen` + resolve the C API surface, lifecycle
(initialize once, serve many, shut down), a request-builder that owns requirement 6, and a
response reader exposing typed accessors for `key.usr`, `key.secondary_symbols`,
`key.fully_annotated_decl`, `key.symbol_graph`. Error taxonomy at this layer already maps every
failure to a value the oracle layer will render as `unknown` — no throwing paths that could
abort a whole analysis run because one symbol misbehaved. Unit tests with a live toolchain
(release config), including a deliberate-failure case (bogus offset / missing file) proving the
`unknown` path.

### Phase C — the oracle layer (per-edge resolution)

Orchestration: take the set of edges whose target USR is absent from project-local
`declarations[...]`; for each, issue the Phase B query at the edge's position with Phase A
arguments; select the result per requirement 1; extract isolation per requirement 4 into a
small, explicit fact type: `globalActor(USR)`, `nonisolated`, or `unknown` (no attribute
fragment present ⇒ `unknown`, not `nonisolated` — the compiler materializes resolved isolation
as attributes, so their absence on a *matched* result is still treated conservatively; revisit
only with new evidence). Deduplicate queries by (file, offset) and cache by member USR within a
run. Measure per-query latency on the real projects here — this phase decides empirically
whether per-edge querying is fast enough or whether the batch alternative (per-module
`symbolgraph-extract`, kept in reserve by the research thread) needs a comparison run. Do not
build the batch path speculatively.

### Phase D — backfill and reporting

Inject Phase C facts at `DeclarationLinker` (the `protocolGlobalActorName` precedent), leaving
the engine untouched. `AnalysisReportBuilder`: the original task spec anticipated no changes
here; surfacing `unknown` requires a *minimal, documented* one — a distinct category in output
and counts, without touching the `high`/`medium`/`low` classification logic for resolved
isolation (that logic remains explicitly out of scope). An edge into `unknown` must be visibly
its own thing: neither silently dropped nor promoted to `high`. Update output schemas
(json/mermaid/dot) accordingly and document the schema addition.

### Phase E — golden fixtures with paired compile-proofs

Extend `Tests/Fixtures/*` with the full matrix the research thread proved out, each asserting
the tool's resolved isolation **and** paired with a real `swiftc -typecheck` proof of ground
truth (the `repro2.swift` discipline):

1. Mechanism A: subclass of an ObjC-bridged `@MainActor` class (`UITableViewCell` under the iOS
   SDK, or `NSCell` under macOS if fixture CI constraints prefer it — the mechanism equivalence
   is already proven).
2. Mechanism B: `SwiftUI.View` conformance.
3. Case 4: purpose-built `.swiftmodule`-only dependency (no interface), including the
   `InferredChild` shape — attribute-less leaf whose isolation is inherited.
4. `DivergentIsolation` shape: `nonisolated init` on a `@MainActor` class — the fixture proving
   USR selection picks the member, not the type (the init-call edge must **not** be a finding).
5. Module-default shape: dependency built with `-default-isolation MainActor`, member access
   resolved as isolated.
6. Negative control: plain nonisolated dependency class — no spurious isolation.
7. Synthesized-extension member — exercising the `"::SYNTHESIZED::"` prefix rule (the one
   research-thread nuance never exercised by a fixture; low risk, but this is where it gets its
   test).
8. Oracle-failure fixture: broken build settings on purpose, asserting `unknown` in output.

### Phase F — real-world Definition-of-done run

Re-run the exact original commands (Project Iris, its own scheme; `~/SQLumen` scheme `SQLumen`;
both `--output json`) and diff findings before/after. Requirement: every disappeared `high`
finding attributable to a newly resolved external chain; every survivor attributable to a
genuinely project-internal edge or an explicit `unknown`; the `unknown` count itself reported
and eyeballed for surprises. Write the run up as a `docs/*.md` record (article-quality, per the
project's standing intent).

## 4. Integration-point map (existing code touched or consulted)

- `Sources/swift-isolation-map/StalenessOrchestration.swift` / `SwiftVersionDetection.swift` —
  Phase A home territory: scheme-driven build-settings acquisition sits beside existing
  scheme/version resolution. Content-hash staleness discipline extends to cached compiler args.
- `Sources/IndexStoreIntegration/DeclarationLinker.swift` — Phase D injection point (existing
  cross-file backfill precedent).
- `Sources/IndexStoreIntegration/` edge data — already carries per-edge member USR + location;
  Phase C consumes as-is.
- `Sources/IsolationCore/IsolationInferenceEngine.swift` — **not modified** (requirement 5).
- `Sources/swift-isolation-map/AnalysisReportBuilder.swift` — Phase D's minimal `unknown`
  surfacing; its doc comment's honest-limitations section gets updated, since this task closes
  one of the gaps it documents.
- New: `Sources/SourceKitDIntegration/` (Phase B), mirroring `IndexStoreIntegration`'s
  structure and its dlopen/locating patterns.

## 5. Out of scope (unchanged from the original task, restated to prevent silent expansion)

- `@unchecked Sendable` / `nonisolated(unsafe)` escape-hatch detection (separate documented
  v0.2+ gap).
- Any change to the risk heuristic's classification logic for *resolved* isolation. Adding the
  `unknown` category (Phase D) corrects the heuristic's inputs and output vocabulary; it does
  not reweigh `high`/`medium`/`low`.
- The batch `symbolgraph-extract` oracle — reserve option only, gated on Phase C's latency
  measurements showing a real need.

## 6. Definition of done (checkable, mapped to the original spec's five points)

1. Phase A decision record exists; compiler args produced for both real projects + SwiftPM
   fixture. *(extends original DoD 1 — the empirical spike it demanded is already complete)*
2. Phases B–D merged with full test coverage; engine untouched (or a deliberate, documented
   exception per requirement 5). *(original DoD 2)*
3. Phase E fixture matrix green, each with its paired compile-proof. *(original DoD 3,
   broadened by the research findings from two fixtures to eight)*
4. Phase F before/after diff produced, attributed, and written up. *(original DoD 4)*
5. Case 4 is resolved — no longer an open question: solvable, implemented, fixture-proven, with
   the one honest inherited constraint documented (binary swiftmodules readable only by the
   producing toolchain — the same constraint `swiftc` itself has). *(original DoD 5, closed in
   the affirmative)*
