# IndexStoreDB silently drops a fraction of a large project's own declarations under full-project load

Tracks [issue #51](https://github.com/btctcn/swift-isolation-map/issues/51) (and is closely related
to #48/#49 — same underlying theme, different specific symptom each time). Found continuing the
medium/low-risk audit against Project Iris after #50's severity-filter/suppression fix shipped.

**Status: root cause not fully isolated; reproduction attempts abandoned as not cost-effective;
mitigation shipped instead of waiting on an upstream fix.**

## Step 1 — Hypothesis

A fresh, clean, single-build run against Project Iris turned up 9 new high-risk-edge callee
patterns, all from one file: `OldPurchaseReturnViewController: UIViewController` resolved as
`nonisolated` end to end — including every one of its own methods — instead of inheriting
`@MainActor`. Same real class, same real symptom already fixed once before (commit `23334d7`,
`docs/task-baseof-duplicate-occurrence-collision.md`) — so the working hypothesis going in was
"regression in that fix." That hypothesis was wrong.

## Step 2 — Spike

Traced precisely, not guessed:

1. `commit 23334d7`'s fix (only treat a *different*-USR repeat as a real name collision) is present
   and correct in the current code — confirmed by reading it.
2. A direct, standalone `IndexStoreClient.baseTypeUSRs(forUSR:)` call for this exact class, against
   Project Iris's real, current index store, in isolation, returns the correct single entry:
   `[(usr: "c:objc(cs)UIViewController", name: "UIViewController")]`. No duplicate.
3. `DeclarationExtractor` + `DeclarationLinker.link()` run in isolation (only this file's own
   `ExtractionResult`, same real `IndexStoreClient`) resolves `superclassUSR` correctly.
4. A real, full `swift-isolation-map` run against the whole project (2251 files, 46895
   declarations) does **not** resolve it. Temporarily instrumented
   `resolveInheritanceViaBaseOfRelation`'s own `resolved(_:for:)` closure (removed before this
   landed) and observed, in that exact run: `baseTypeNames(forNominal: <this class's real USR>)`
   returned an **empty dictionary** — the identical query that returned one correct entry in
   isolation returned nothing under full-project load. `IndexStoreClient` itself holds no mutable
   state (confirmed by reading it), so this points at `IndexStoreDB`'s own C++ layer being
   state/load-dependent, not at anything in this project's Swift code.
5. Broadened the search: counted every node in a real full report that's a synthesized
   "referenced but never declared" placeholder (`location: {file: "", line: 0}`) whose USR is a
   real Swift-native, app-module symbol (`s:...Ls_net_ru...`) — not SDK, not Pod, not a `syntactic:`
   placeholder. **803 such declarations**, out of ~46895+4834 total. Confirmed two of them
   independently (`MainPageInteractorImpl.loadSets(style:completion:)`,
   `BlogAuthorCell.configure(model:)`) resolve correctly via the exact same isolated-single-file
   `DeclarationLinker.link()` probe, and are simply absent from `declarations` in the full run.
   Same shape as the `.baseOf` case, but this time the declaration's *own* identity resolution
   (location-based USR rewriting — no relation query involved at all) is what's failing to survive
   into the final linked result.

**Read of `indexstore-db`'s own source** (`.build/checkouts/indexstore-db`, real checked-out
version this project builds against): `IndexStoreClient`'s `waitUntilDoneInitializing: true` at
construction plumbs through to `IndexDatastoreImpl::init` → `IdxStore->startEventListening(...)`,
which is an async, event/delegate-driven mechanism (`OnUnitsChange` callback,
`UnitProcessingSession`, a separate explicit `pollForUnitChangesAndWait` documented as "a fairly
costly operation" for a *full* rescan). The actual unit-file processing (`libIndexStore`) lives
outside this repo, in the toolchain — not something `indexstore-db` alone can be blamed for or
fixed in. Structurally, this is consistent with `IndexStoreDB` being designed for `sourcekit-lsp`'s
own use case: live editing, incremental, eventually-consistent — not a strict, immediately-complete
database. The everyday experience of Xcode's own navigation/syntax highlighting occasionally
needing a restart or a DerivedData wipe is the same fact observed from the IDE-UX side.

## Step 3 — Documentation (this document)

## Attempted reproduction (4 tries, none succeeded)

Goal: a minimal, shareable project reproducing "isolated single-file resolution succeeds, full-project resolution silently drops the same declaration," as the basis for either a confident upstream report or a confidently-scoped internal fix.

| # | Shape | Scale | Result |
|---|---|---|---|
| 1 | Plain SPM executable, one shared local base class | 1500 files / 7503 declarations | 0 lost |
| 2 | Same, scaled up | 6000 files / 30003 declarations | 0 lost |
| 3 | Real `xcodebuild` + real `UIViewController` (not a local base class), single target | 1500 files / 7500 declarations | 0 lost |
| 4 | Same, scaled to match Project Iris's real declaration count | 9000 files / 45000 declarations | 0 lost |
| 5 | Two Xcode targets (app + embedded framework, imitating app+Pod) | 9000 files / 40502 declarations | 0 lost |

Every attempt used the identical verification method (isolated `DeclarationLinker.link()` per
declaration vs. checking the same declaration after linking the *entire* synthetic project) that
reliably found the real bug on Project Iris. None reproduced it, even at a declaration count
matching or exceeding Project Iris's own (46895). Two of the attempts (#4 and the first pass at #5)
ran the local disk out of space (`ENOSPC`) before completing, from `xcodebuild`'s per-file
intermediate object/module-cache output at this file count — itself a data point on how
resource-heavy exercising `IndexStoreDB` at this scale really is, independent of the bug.

**Conclusion**: the bug isn't a simple function of declaration count, of `xcodebuild` vs. `swift
build`, or of single- vs. multi-target structure alone (at least not the two-target shape tried
here). Whatever combination of factors in Project Iris's real structure triggers it — dozens of
real CocoaPods as separate targets, genuine code complexity/compile time per file, or something
else not yet identified — isn't captured by any of these attempts. Given two near-disk-exhaustion
incidents and four consecutive failed tries, further reproduction attempts were judged not
cost-effective relative to just building a mitigation directly (see Step 4) and were stopped.
**No upstream bug report is being filed** without a reliable minimal reproduction — reporting "it's
flaky under load, no repro" to `indexstore-db` maintainers would not be actionable for them, and
per the design-philosophy point below, may not even be treated as a defect.

## A structural conclusion, independent of root cause

`IndexStoreDB` is the reference data source `sourcekit-lsp` uses for navigation, find-references,
symbol search, and code completion — a best-effort, eventually-consistent index built for a live
editing session, not a formally verified, guaranteed-complete database. That it occasionally serves
incomplete data under load is consistent with its own design (see the async/event-driven
initialization path above) and with everyday experience of the tools built on it. This means the
gap found here (and in #48, #49) is not "a bug Apple will fix on request" so much as a **structural
property of the chosen data source** that any tool built on top of it — including this one — has to
design around, not wait out.

## Step 4 — Mitigation (code)

This project already has exactly the right shape of fix in production, just scoped too narrowly:
`ExternalIsolationBackfill` already does "trust the fast bulk source first; fall back to a live,
authoritative `sourcekitd` `cursorinfo` query for what the bulk source didn't resolve" for
*compiled-dependency* isolation. The same pattern extends naturally to this gap: when
`DeclarationLinker`'s location-based `usrRewriteMap` construction fails to match a `SyntaxAnalysis`-
extracted declaration in the *analyzed project's own source* (not a compiled dependency) to a real
IndexStoreDB USR at its own (file, line, column), that's the same kind of "bulk source didn't
answer" case — not a signal the declaration is genuinely external or nonexistent. Falling back to a
live `cursorinfo` query at that exact location before giving up (instead of leaving a permanently
unresolved `syntactic:` placeholder) reuses infrastructure this project already has and trusts,
rather than inventing a new data source or waiting on `indexstore-db`/`libIndexStore` upstream.

`DeclarationLinker` gained `unresolvedPlaceholders(for:)` (a cheap, `buildUSRRewriteMap`-only pass
returning every syntactic placeholder that never resolved, paired with its own real location) and
`link(_:usrRewriteMapOverrides:)` (an optional `[placeholder: realUSR]` map, taking priority over
whatever the bulk index's own location match found or didn't). `SwiftIsolationMap.run()` calls
`unresolvedPlaceholders(for:)` right after the first `link()` call, resolves those against a live
`cursorinfo` query (`LocalDeclarationLiveFallback.resolveOne`, taking the primary result's own USR
directly -- no `USRMatching` needed, since discovering the real USR *is* the point), and re-links
with the overrides applied.

**Performance turned out to matter as much as correctness.** A real run against Project Iris found
**10954** unresolved placeholders -- an order of magnitude more than the 803-declaration finding
that motivated this, since it also includes every declaration legitimately outside the analyzed
scheme's own compilation (a different target/scheme, `#if`-excluded code) that simply has no
compiler arguments to query with; those fail near-instantly and aren't the real cost. The genuine
`cursorinfo` round trips are: each can require building a file's AST from scratch, and
`sourcekitd`'s own `ASTBuildQueue` serializes that *within one process*
(`docs/task-oracle-query-concurrency.md`'s own finding). Confirmed by a real timed run: purely
sequential, this measurably exceeded 15 minutes and was still running when deliberately stopped --
impractical for a tool meant to run on every invocation, not once. Fixed the same way
`ExternalIsolationBackfill`'s own live-query phase already was (`docs/task-process-tree-
optimization.md`): `LocalDeclarationLiveFallback.resolveInParallel` reuses the identical
`--oracle-workers`-driven, separate-OS-process dispatch (`OracleWorker.balancedChunks`, unmodified)
-- a new `LocalDeclarationWorker`/`--local-declaration-worker-input`/`-output` pair mirrors
`OracleWorker`'s own shape with a simpler wire format (no `targetUSR`-based `USRMatching` or
isolation-parsing needed, since the primary cursor-info result's own USR is the answer).

## Step 5 — Tests

`Tests/IndexStoreIntegrationTests/DeclarationLinkerUnitTests.swift`: `unresolvedPlaceholders(for:)`
reports a location-match miss with its real location, omits a successfully-resolved declaration
and one with no real location at all; `link(_:usrRewriteMapOverrides:)` rescues a declaration the
bulk index missed, using the override in place of the unresolved placeholder. Full
`swift test -c release`: 295/295 passing.

## Step 6 — Documenting results

Real-corpus re-run against Project Iris, before vs. after this fix (both post-#50's suppression
fix, so directly comparable):

| | before | after |
|---|---|---|
| App-module declarations missing entirely (the original 803 finding) | 803 | **401** (-50%) |
| `highRiskBoundaries` | 853 | **933** (+80, +9.4%) |
| `unspecifiedIsolation` | 2145 | 1501 (-30%) |
| `crossActorBoundaries` | 27498 | 24616 |
| Live-fallback resolution rate | n/a | 8746 of 10954 (79.9%) |

The `highRiskBoundaries` *increase* is the expected, correct direction for this project's own
fail-safe philosophy: these 80 edges weren't newly-introduced false positives -- they were real
risk previously hidden behind an `.unspecified` caller/callee (or missing from the call graph
entirely, since a callee IndexStoreDB's own reverse `callGraphEdges(forUSR:)` lookup was never
queried for at all if that USR never made it into `usrRewriteMap`'s values -- the real call-graph
edge count itself grew from 123318 to 137133 for the same reason). Surfacing previously-invisible
risk, not manufacturing new noise.

The remaining 401 (of the original 803) are declarations the live fallback also failed to resolve
-- out of scope for this pass to chase further; plausibly the same category of `sourcekitd`-side
instability at a different layer, or a real, legitimate "no compiler arguments available" case this
count doesn't yet distinguish from the genuine miss.

## Step 7 — PR

Next.
