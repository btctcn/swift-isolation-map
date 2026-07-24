# Priority 2, Phase 3 — USR/location linking (empirical record)

Per this project's sourcing discipline, applied to a linking *mechanism* rather than an isolation
rule: every design decision below was checked against a real toolchain and real compiled fixtures
before being relied on, not assumed from the architecture doc's code sketch. Two of the doc's own
claims turned out stale; both are corrected here with evidence, not silently.

## Location convention: SwiftSyntax and IndexStoreDB agree

Verified with a real fixture (an `actor` with a stored property and a method, compiled and
indexed for real): SwiftSyntax's `SourceLocationConverter.location(for:)` (measured at each
declaration's name token) and IndexStoreDB's `SymbolLocation` (`line`/`utf8Column`) use the
**same convention** — 1-based line, 1-based UTF-8-byte column — and point at the **same position**
for the same real symbol. This is what makes `DeclarationLinker`'s (file, line, column) matching
possible at all; it was checked empirically before being built on, not assumed.

## Multiple real symbols can share one location

The same fixture showed **three** IndexStoreDB symbols at the exact location of a plain stored
property (`currentUser`): `currentUser` (`instanceProperty`), `getter:currentUser`
(`instanceMethod`), `setter:currentUser` (`instanceMethod`) — Swift's implicit accessors report at
their property's own location, not a synthesized location of their own. A separate fixture showed
the same pattern for an actor's implicit `init()`, which reports at the *type's own* location.

`DeclarationLinker.disambiguate` resolves this by name where possible:
- Exact match (handles types and properties — `currentUser` vs. `getter:currentUser` are
  textually distinct).
- Prefix-before-`(` match (handles methods with parameter labels: this extractor's
  `DeclarationInfo.name` is the bare base name, e.g. `login` — matching `node.name.text` — while
  IndexStoreDB's symbol name includes labels, e.g. `login(as:)`).
- A single candidate needs no disambiguation.
- Otherwise: **no match, not a guess.** The placeholder USR is left unresolved rather than picking
  arbitrarily — a documented, visible limitation, not a silent wrong answer.

## The architecture doc's call-graph algorithm doesn't match IndexStoreDB's real API

Section 2.2 describes finding a call's caller via "`.childOf` relations, walking up." Verified
against a real two-function fixture (one calling the other): a `.call`-role occurrence's
`.relations` carries `.calledBy`/`.containedBy`, not `.childOf` — and it names the caller
*directly*, no walking needed. `IndexStoreClient.callGraphEdges(forUSR:)` uses the relation role
actually confirmed present.

## Cross-file `protocolGlobalActorName` backfill

Phase 1's `DeclarationExtractor` computes `ProtocolConformance.protocolGlobalActorName` purely
syntactically, per file — correct within one file, but necessarily `nil` when the conformed-to
protocol is declared in a *different* file than the conforming type/witness (SwiftSyntax has no
cross-file notion, and IndexStoreDB can't help either: Phase 0 already confirmed its symbol kind
can't even distinguish `actor` from `class`, let alone see a `@MainActor` attribute). Closed by
exposing each file's own `protocolGlobalActorNames` map via a new `ExtractionResult` type,
merging every file's map in `DeclarationLinker`, and backfilling any `nil` conformance by looking
up the protocol name embedded in its syntactic placeholder USR.

## Golden-fixture test: a genuine cross-file protocol-witness call

`Tests/Fixtures/cross-file-witness/` splits the classic rule 7/8 scenario across three files on
purpose — `@MainActor protocol Refreshable` in `Protocol.swift`, `SyncCoordinator`'s primary
declaration (no conformance) in `SyncCoordinator.swift`, the conformance and witness in a
*third* file. A single-file extraction of any one of them could never resolve `refresh()` as
MainActor-isolated; only real cross-file linking can. Fed through the **unmodified** Priority 1
`IsolationInferenceEngine`, it correctly resolves the witness as `.globalActor(name: "MainActor")`,
an unrelated method on the same type as `.nonisolated`, and flags the real
`trigger() -> refresh()` call (from IndexStoreDB's real call graph, not fixture data) via
`crossIsolationEdges()`.

The fixture's caller (`trigger`) is `async`, awaiting the cross-actor call, deliberately — an
earlier version called it synchronously, which is a genuine Swift 6 compile **error** (confirmed:
real exit code 1, not just a diagnostic), which would have prevented indexing the file at all.
Confirming this empirically (not assuming a bare synchronous call would "just produce a
diagnostic and still build") is what caught it before it became a silently-broken fixture.

## Two real bugs, both caught by re-running the same test repeatedly, not by first-pass success

- **Flaky test #1:** `swift package describe`/build-based golden-fixture tests that reuse the
  same fixture `.build` directory across runs can silently skip recompilation (SwiftPM's own
  incremental build correctly determines nothing changed) — meaning a freshly-deleted-and-
  recreated index store path is never actually populated on a second run, and the test fails
  intermittently depending on prior state. Fixed by clearing the fixture's own `.build` before
  building it in the test, not just the destination index store path.
- **Flaky test #2:** the golden-fixture test's own assertions used a bare `.first { $0.name ==
  "refresh" }` lookup — but `Refreshable`'s own `func refresh()` *requirement* is a second,
  separate declaration also named `refresh`, and `Dictionary.values` iteration order isn't
  deterministic in Swift. Same class of bug Phase 1's own tests hit once already for an identical
  protocol-requirement-vs-witness collision; fixed the same way, by disambiguating with
  `containingTypeUSR`.

Both were caught specifically by re-running the new test multiple times in a row before trusting
a single green run — consistent with [[feedback_verify_against_independent_real_world_cases]]'s
broader lesson that a single passing run (or a single "clean" re-verification) isn't sufficient
evidence on its own.

## A real, still only partially understood infrastructure bug: debug-build test-suite segfault

Once `indexstore-db` was linked into the combined test bundle (`swift-isolation-mapPackageTests`,
covering every target, not just `IndexStoreIntegrationTests`), the **debug**-configuration test
run started segfaulting (`SIGSEGV`, `EXC_BAD_ACCESS` at address `0x0`) intermittently but
frequently — reproducible even with `IndexStoreIntegrationTests` completely skipped via
`--skip`, and even with `--no-parallel`. The crash report's stack trace is inside
`libswiftCore.dylib`, called from the `Testing` framework's own test-discovery/execution
machinery, not from this project's own code.

**What was ruled out, with evidence, not assumption:**
- Not caused by running this phase's own tests (`--skip IndexStoreIntegrationTests` still
  crashed).
- Not caused by swift-testing's test-level parallelism (`--no-parallel` still crashed).
- Not present at all on `main` (before this dependency existed) — confirmed by checking out
  `main` directly and running the full suite there (102/102, clean).

**What fixed it:** running tests in release configuration (`swift test -c release`) — verified
stable across multiple repeated runs (109/109 every time), where debug configuration crashed on
most runs. CI (`.github/workflows/ci.yml`) now runs `swift test -c release` for this reason,
documented inline at the call site.

**Honestly unresolved:** the exact root cause (why linking this specific C++ dependency into a
debug-configuration combined test bundle destabilizes swift-testing's own runtime machinery) was
not tracked down to a specific line of Swift runtime or IndexStoreDB code — that would require
deeper toolchain-internals debugging than this phase's scope justifies. This is recorded as a
known, worked-around infrastructure issue, not a silently "just fixed" one.
