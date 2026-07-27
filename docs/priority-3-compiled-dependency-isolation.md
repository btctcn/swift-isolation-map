# Priority 3: compiled-dependency isolation — correctness (A-F), performance (G1-G6), Gap A (H1-H4), Gap B (I1-I5)

This closes out the whole compiled-dependency-isolation effort: the original correctness task
(`docs/task-compiled-dependency-isolation.md`, Phases A-F, implemented and tested earlier this
session — 187/187 `swift test -c release`), the follow-on performance task
(`docs/task-compiled-dependency-isolation-performance.md`, Phases G1-G6), the accessor-USR-
granularity fix spun out of G6's own real-world validation
(`docs/task-compiled-dependency-isolation-usr-granularity.md`'s Gap A, Phases H1-H4), and Gap B
itself — the `DeclarationLinker` real-scale linking gap
(`docs/task-gap-b-declaration-linker-real-scale.md`,
`docs/task-gap-b-implementation-plan.md`'s Phases I1-I5, this document's newest section) — now
closed. See "Gap B" below for the real, measured before/after result.

## What G1-G5 built (all landed, tested, 202/202 `swift test -c release`)

- **G1** — `BulkSymbolGraphExtractor.extract` now merges every `*.symbols.json` file in a bulk
  `symbolgraph-extract` output directory, not just the module's own primary file. Confirmed
  empirically (a real two-module build) that a `@MainActor` extension member added by one module to
  another module's type — exactly the shape of the original motivating bug
  (Kingfisher's `captionImageView.kf.indicatorType`) — is serialized *only* into a sibling
  `<Module>@<ExtendedModule>.symbols.json` file, never the primary one.
- **G2** — Real module discovery, additive to the existing hardcoded well-known SDK-module list:
  `BulkExtractionEnvironmentProviding` (`LiveXcodeBulkExtractionEnvironmentProvider` /
  `SwiftPMBulkExtractionEnvironmentProvider`) gets SDK path, target triple, and every real
  third-party framework/module a project actually depends on from a fast, read-only
  `xcodebuild -showBuildSettings` call (Xcode) or `.build/<triple>/Modules` enumeration (SwiftPM) —
  never a build. `FrameworkModuleDiscovery` resolves each framework's *real* module name (preferring
  a `Modules/<Name>.swiftmodule` directory, falling back to parsing `module.modulemap`) since a
  search-path directory's basename isn't reliable (confirmed: `ActionSheetPicker-3.0`'s real module
  is `ActionSheetPicker_3_0`). Confirmed live against `~/ios`: discovers all 45 real CocoaPods
  dependencies (Kingfisher, Alamofire, Moya, Firebase*, ...) in ~8.5 seconds.
- **G3** — Wired into `ExternalIsolationBackfill.bulkSymbolGraphCache`, which now gets its
  environment from the new provider instead of from `compilerArguments.compilerArguments(forFile:)`
  — the same expensive, `clean`-build-capable provider the live fallback needs. This is the entire
  fix for the "bulk phase accidentally pays the live path's build cost" problem: that provider is
  now only ever touched inside `query(...)`'s live fallback, which only runs on a genuine bulk-cache
  miss.
- **G4** — `ProcessRunning.run` gained a real `timeout: TimeInterval?` protocol requirement (not
  just an extension default, which would dispatch statically and never enforce anything on a
  protocol-typed parameter — verified this matters). `BulkSymbolGraphExtractor.extract` passes 60s,
  so one hung/pathological third-party module can't stall the whole bulk phase.
- **G5** — `BulkSymbolGraphExtractor.extractAll` parallelizes per-module extraction via
  `DispatchQueue.concurrentPerform` (real OS threads, each writing to its own preallocated result
  slot, merged back in deterministic order afterward) instead of a sequential loop.
- A late but necessary sixth addition: `BulkSymbolGraphExtractor.defaultModules` grew from
  `["UIKit", "AppKit", "SwiftUI"]` to include `Foundation`, `ObjectiveC`, `CoreGraphics`, `Dispatch`
  — these SDK modules aren't discoverable via G2's framework-search-path scan (they're
  implicitly available via `-sdk` alone, not separate `-F` directories, the same as UIKit), so they
  need explicit listing; each confirmed to extract in well under 5 seconds.

## G6 — real-world validation: what actually happened

### `~/SQLumen` — a full, successful, completed run

`~/SQLumen/SQLumen.xcodeproj`, scheme `SQLumen` (61 files, 1050 declared types). Completed in
**~2 minutes wall-clock**, `--auto-build --output json --verbose`:
```
External oracle: 528 resolved, 185 conformance(s) updated, 1013 unknown
```
A real, meaningfully nonzero resolved count — not the "fast but 0 resolved" trap this session hit
once earlier (see below). Summary before → after:

| | before (pre-Phase-A) | after (G1-G5) |
|---|---|---|
| `crossActorBoundaries` | 216 | 4661 |
| `highRiskBoundaries` | 38 | 93 |
| `mainActorTypes` | 19 | 256 |
| `unspecifiedIsolation` | 30 | (folded into `External oracle`'s 1013 unknown) |

The large jump in `crossActorBoundaries`/`mainActorTypes` matches the same, already-understood
mechanism documented in Phase C (`callSites` folding surfacing many more real call-graph edges,
plus previously-`.nonisolated`-by-default externals now correctly resolving to real
`@MainActor`/actor facts). The `highRiskBoundaries` change (38→93) was **not** individually
audited finding-by-finding against real `swiftc` ground truth this session — flagged here
honestly as real, plausible, but not yet manually spot-checked at the individual-finding level the
way the golden-fixture matrix is.

### `~/ios` — architecturally correct, but did not complete in a reasonable time

`~/ios/lsboutique.xcworkspace`, scheme `ls.net.ru` (2209 files, 46010 declarations, 137657
call-graph edges). Multiple full-run attempts this session took 15-30+ minutes and were killed
before completion — not the original task's 70+-minute unfinished baseline, but nowhere near the
"low single-digit minutes" target either.

**A temporary diagnostic** (added to `ExternalIsolationBackfill`'s two trigger loops, logging every
bulk-cache hit/miss and short-circuiting misses to `unknown` without a live query — reverted after
use, not present in the committed code) ran a full pass over `~/ios` in seconds instead of tens of
minutes and revealed the *real* root cause, which is not what this phase's own fixes targeted:

- **Edge-level**: 850 bulk-cache hits, 18957 misses. 11400 of those misses (60%) carry the
  project's *own* module prefix (`s:9Ls_net_ru...`) — not external dependencies at all.
- **Declaration-level**: 28134 misses, **100% of which** have a `syntactic:`-prefixed unresolved
  need — `SyntaxAnalysis.DeclarationExtractor`'s internal placeholder scheme for a
  not-yet-linked *project-local* declaration, never a real external-dependency USR.

In other words: on a project this large, the overwhelming majority of what this whole
compiled-dependency-isolation feature's oracle is being asked to resolve isn't actually about
compiled dependencies at all. Full detail, root-cause analysis, and a concrete follow-up task
specification: `docs/task-compiled-dependency-isolation-usr-granularity.md`. Two distinct,
pre-existing structural gaps, both real, both scoped for a dedicated follow-up:

1. **Accessor/property USR-granularity mismatch** — `IndexStoreDB`'s call graph targets a
   property's *synthesized accessor* USR; both the bulk symbol-graph cache and the live
   `sourcekitd` oracle key by the property's own single canonical USR. Neither can ever match the
   other for any property read/write anywhere in the codebase — confirmed even for symbols in
   modules this phase's own work successfully bulk-extracted (`Foundation`, `Mindbox`). Already
   noted in miniature during Phase C; only visible as *the* dominant cost at real scale.
2. **`DeclarationLinker` real-scale linking gap** — a pre-existing, unrelated bug: many
   project-local protocol/superclass references never resolve past their `syntactic:` placeholder
   on a real, large project, even though the same mechanism works on every existing (much smaller)
   fixture. Not a compiled-dependency problem at all; needs its own root-cause investigation.

**This phase's own fixes (G1-G5) are not wrong or wasted** — they're necessary, verified-correct
infrastructure (module discovery, laziness, timeouts, parallelism), and they are what took a
`~/ios` run from "70+ minutes, unfinished, and secretly always failing everything (before the
clean-build fallback fix)" to "a real, working oracle that successfully resolves hundreds of real
externals on `~/SQLumen`." They're just not *sufficient alone* on a project the size of `~/ios`,
because the dominant cost there turned out to be two things this task never targeted.

## Gap A (accessor/property USR-granularity) — closed this session

A follow-up research response (`/Users/ab/Downloads/usr-granularity-research-response.md`)
proposed using `IndexStoreDB`'s own `.accessorOf` symbol relation to map a synthesized accessor's
USR back to its owning property's canonical USR — no demangling needed. **Verified directly
against the real checked-out `swiftlang/indexstore-db` source** (not accepted on authority):
`SymbolRole.accessorOf` and `SymbolOccurrence.relations` are both real; one correction to the
researcher's claim — the Swift-facing `IndexSymbolKind` enum has no accessor-related cases at all
(the C-level `AccessorGetter`/`AccessorSetter` subkinds aren't bridged into Swift), so the
`.accessorOf` lookup must be attempted unconditionally, never gated behind a cheap pre-check.

Implemented as `IndexStoreQuerying.owningPropertyUSR(forUSR:)`
(`Sources/IndexStoreIntegration/IndexStoreClient.swift`), mirroring the existing
`callGraphEdges(forUSR:)` pattern exactly. **The relation's direction was verified empirically
first**, per this project's standing discipline, via a real live test
(`DeclarationLinkerTests.swift`'s `owningPropertyUSRMapsRealAccessorToItsProperty`, using a real
stored property added to the `cross-file-witness` fixture) — the direction matched the
implementation's assumption on the first attempt, no inversion needed.

Applied inside `DeclarationLinker.link(_:)`, canonicalizing **both** `callerUSR` and `calleeUSR`
of every call-graph edge (not just the callee — a real correctness gap caught in a second
Plan-agent design review: a call originating inside a property observer body could plausibly have
its own accessor-suffixed `callerUSR`, and `IsolationInferenceEngine.resolveIsolation(for:)` has
no special-casing between the two sides), memoized per `link()` call. This is the *only* change
needed — every downstream consumer (`ExternalIsolationBackfill`, `IsolationInferenceEngine
.crossIsolationEdges()`, both report writers) benefits automatically.

Also added `Swift`/`CoreFoundation` to `BulkSymbolGraphExtractor.defaultModules` (measured: ~1.2s/
51MB and ~0.5s/5MB respectively — cheap, despite `Swift` being plausibly "the largest module there
is," not assumed cheap just because every other module was) — real diagnostic samples
(`Array`'s literal initializer, `Bool`'s `!` operator, `CGFloat` literal inits) were bare stdlib
symbols uncovered by any prior module.

**Real, measured result on `~/ios`** (same short-circuit diagnostic technique as before —
temporarily re-added, reverted after use): edge-level bulk-cache hit rate went from **850/19807 ≈
4.3%** to **1481/3782 ≈ 39.2%**. More importantly, the *total* edge-level oracle-candidate volume
dropped from 19807 to 3782 (an 80.9% reduction) — most of the previous 11400 project-local
accessor misses now resolve as ordinary internal declarations *before* the oracle is ever
consulted at all (the `linked.declarations[targetUSR] == nil` check in
`ExternalIsolationBackfill` now sees the already-canonicalized property USR). Live-query misses
specifically dropped from 18957 to 2301 — an 87.9% reduction in exactly the work that was slow.
`CapstoneCLITests.swift`'s fixture assertions changed too, for a genuinely positive reason: two of
the three previously-`unknown` edges (`Counter.increment()`'s own synthesized property
getter/setter calls) now correctly resolve as same-actor, non-boundary edges; the third
(`Int.+=`, a real stdlib call) now resolves via the newly-bulk-extracted `Swift` module to a real
`.nonisolated` fact, correctly classified `medium` risk instead of `unknown`.

Gap B (the `DeclarationLinker` real-scale linking gap — 28134 declaration-level misses, 100%
`syntactic:`-prefixed) remains open and untouched by this work; see
`docs/task-compiled-dependency-isolation-usr-granularity.md`.

## Whitespace-path-escaping bug — found and fixed this session

While attempting a real, complete (non-diagnostic-shortcut) timed run against `~/ios` to get an
honest current wall-clock number, the previously-dismissed-as-"cosmetic" stderr noise
(`sourcekit: ... failed to stat file: .../News/News/ List/...`, present in every real `~/ios` run
this whole session, mentioned in earlier drafts of this doc as "never root-caused") turned out to
be a **real, serious performance bug**, not cosmetic at all: **238 live `cursorinfo` queries
produced 30932 total `failed to stat file` occurrences — an average of ~130 failed file loads on
every single query.**

Root cause, found by inspecting a real `SwiftFileList` byte-for-byte: `~/ios` has genuine,
legitimate directory names containing spaces (`UI/News/News List`, `UI/Side/Side Menu`). Xcode's
real `SwiftFileList` response files backslash-escape such paths
(`/Users/ab/ios/lsboutique/UI/News/News\ List/NewsController.swift`), but
`XcodeBuildLogCompilerArgumentsProvider.expandFileList` did a naive per-line split with no
unescaping at all, leaving a literal backslash character in the resulting path string — which then
never matches the real filesystem entry, for *every* file in the entire compile unit's sibling-file
list, on *every single query* that compile unit's compiler arguments get attached to.

Fixed: `XcodeBuildLogCompilerArgumentsProvider.unescaped(_:)`, mirroring
`CompilerArgsLogParser.tokenize`'s own existing backslash-handling (drop the escape character,
keep whatever it precedes literally), applied to each file-list line before returning it.
**Measured, real result**: a fresh real run against `~/ios` with the fix produced **zero**
`failed to stat file` occurrences (previously 30932). Full unit + live-integration test coverage
added (`XcodeCompilerArgsTests.swift`).

**This resolved a real performance drag, but it fully unmasked Gap B as the sole remaining
blocker**: with both Gap A and the path-escaping bug fixed, live-query throughput on a real `~/ios`
run measured at **~13 queries/minute**. The declaration-level trigger alone has 28134 USRs needing
this same query, **100% of which are Gap B (`syntactic:`-prefixed, destined to fail no matter
what)** — at the observed rate, running all of them to completion would take on the order of
**35-40 hours**. This is the full, quantified, now-unambiguous case for why Gap B, not anything
this document's own work touched, is the entire remaining reason a full `~/ios` run cannot complete
in a reasonable time. Full detail, real captured examples, and a concrete follow-up task
specification: `docs/task-gap-b-declaration-linker-real-scale.md`.

## Gap B (`DeclarationLinker` real-scale linking gap) — closed this session

Full problem statement, real captured corpus examples, and the two independent research/review
passes that shaped the fix: `docs/task-gap-b-declaration-linker-real-scale.md` and
`docs/task-gap-b-implementation-plan.md` (the latter is the authoritative implementation record —
Phases I1-I5, each with its own verification). Summary:

- **I1** — `DeclarationExtractor`'s inheritance-entry placeholder normalization widened from a
  single `@unchecked Sendable`-only fix to four real shapes (attribute-stripping, generic-argument-
  stripping, qualified-reference rightmost-name, suppression-entry skipping), each with its own
  unit test.
- **I2** (the core fix) — `IndexStoreClient.baseTypeUSRs(forUSR:)`, backed by IndexStoreDB's
  `.baseOf` relation, resolves a declaration's superclass/conformance placeholders to their real,
  compiler-assigned USRs directly from the index — project-local and external/SDK references
  alike, no `SyntaxAnalysis` changes, no name tables. Direction and shape verified empirically
  against a real index store (not assumed): a direct inheritance clause's base type surfaces via
  `occurrences(relatedToUSR: usr, roles: .baseOf)` directly, but an **extension-declared
  conformance** (confirmed the corpus's dominant real shape) requires one extra hop through the
  type's own `.extendedBy` relation first — a real mechanism, found only by inspecting raw
  relation data, not guessed. `DeclarationLinker.link(_:)` queries once per distinct real nominal
  USR (memoized), matches by name, and skips (never guesses) a same-bare-name collision. A
  nesting-mismatch fallback (qualified declaration placeholder vs. bare-name reference to it) was
  added to the shared `rewritten(_:)` closure alongside it.
- **I3** — per-member conformance-need duplication (the same clause counted once per member of a
  conforming type/extension) deduped in `ExternalIsolationBackfill.resolveDeclarationLevelTriggers`
  by (nominal-type USR, unresolved-protocol) pair, cache-and-apply (not skip-and-leave) so every
  member sharing a pair gets the resolved outcome, not just the first one queried.
- **I4** — end-to-end trace of the specific `NotificationsListViewInput` case (real `~/ios` file,
  real index store) found a *third*, deeper failure mode than any hypothesis in the prior research:
  `DeclarationExtractor` never emits a `DeclarationInfo` for a `protocol` declaration at all (only
  classes/structs/enums/actors get one — confirmed by direct reading, no `ProtocolDeclSyntax`
  override exists in the main `DeclarationVisitor`). This is `DeclarationExtractor`'s own existing,
  deliberate design (a protocol's isolation contribution is modeled entirely through a separate
  `protocolGlobalActorNames` merged map), not a new bug — but it does mean
  `ExternalIsolationBackfill`'s "already known locally, zero oracle cost" short-circuit can never
  fire for a conformance to a plain protocol with no global-actor attribute of its own, even after
  I2 correctly resolves its real USR. Documented as a real, narrower residual limitation per this
  phase's own explicit escape hatch, not further patched (a larger, separate architecture change,
  out of Gap B's own scope).
- **I5 — real, measured result on `~/ios`** (same env-gated short-circuit diagnostic technique used
  throughout this effort, reverted after use): declaration-level oracle triggers dropped from
  **28134 (100% `syntactic:`-prefixed) to 3388 raw triggers / 3262 distinct (nominal, protocol)
  pairs** — an **88% reduction** in trigger volume, with the `syntactic:`-prefixed-miss fraction
  falling from 100% to **802/3388 ≈ 23.7%** (the residue Phase I4 explains: protocol conformances
  whose own `DeclarationInfo` was never extracted). **A real, complete, non-diagnostic-shortcut run
  against `~/ios` finished in 29 minutes 41 seconds** (`29:41.44` wall-clock, `86% cpu`) — down from
  the pre-Gap-B estimate of 35-40 hours, per this document's own "honest wall-clock" discipline
  established by the whitespace-path-escaping fix above. `External oracle: 2434 resolved, 10898
  conformance(s) updated, 3208 unknown`. The resulting real analysis: 34730 types analyzed, 4
  actors, 11948 `@MainActor` types, 51711 cross-actor boundaries, **129 confirmed high-risk
  boundaries** (plus 149 more that would be high-risk but are correctly excluded from that count
  because one side's isolation couldn't be determined -- `isUnknown: true`, an existing, tested
  distinction, not new). Spot-checked one file (`UIViewController+Navigation.swift`, 5 of the 129):
  every finding traced to a real, genuine chain -- a project-local `UIViewController` extension
  method (no isolation of its own) calling into `CartBadgeButton`/`ApplicationViewController`,
  neither explicitly `@MainActor` in their own source but both isolated via inheritance from a real
  `@MainActor` UIKit base class (`UIBarButtonItem`/`UITabBarController`) -- resolved only because of
  Gap B's own fix. Noted, honestly, as a separate finding **not yet verified**: the caller side of
  these specific findings (a project-local extension of an *external* type, `UIViewController`)
  might itself be a false positive of a distinct, out-of-scope limitation (whether an extension of
  an external type inherits that external type's own isolation is a different question than
  anything Gap B resolves, which is purely about inheritance-clause references) -- worth a future,
  dedicated look, not conflated with Gap B's own, otherwise clean result.
- Full `swift test -c release`: 220/220 passing (207 pre-Gap-B plus 13 new: 5 for I1's per-shape
  normalization, 6 for I2's `.baseOf` resolution/nesting-fallback/collision-skip, 1 for I2's real
  direction-verification live test extended with an extension-declared-conformance fixture, 1 for
  I3's cache-and-apply dedup).

## Extension-of-an-external-type fix — closed this session

Full problem statement, mechanism trace, and two independent external-review rounds (both
independently re-verified before being trusted, per this project's standing discipline):
`docs/task-external-type-extension-isolation.md`. Summary:

- **The fix**: a two-hop IndexStoreDB relation chain (`.childOf` -> the member's own enclosing
  extension's synthetic USR, then `.extendedBy` -> the extension's own real extended-type USR),
  added to `IndexStoreClient` and consumed by a new `DeclarationLinker` pass that rewrites an
  extension member's `containingTypeUSR` to that real USR whenever the extended type has no
  primary declaration among the linked files (a genuinely external SDK/Pods type, or a project-
  local type simply outside this analysis run). `ExternalIsolationBackfill` gained a third
  "unresolved need" (alongside the existing superclass/conformance ones) that backfills the
  extended type's own isolation via the *same* bulk-cache-first, live-oracle-fallback machinery
  already used for external superclasses — `IsolationInferenceEngine` itself needed **zero**
  changes, confirmed by tracing its containing-type-propagation branch directly. Two rounds of
  external review caught a real design-shape flaw (resolving per shared bare-name placeholder
  would have silently reintroduced the exact collision-blindness the fix exists to close) before
  any code was written; the shipped design resolves per-member (`.childOf`, free, in-memory) with
  hop 2 memoized per distinct extension USR, giving correct per-extension identity for free.
- **Real, measured result on `~/ios`, and it is larger than originally scoped — reported
  honestly, not just the number that was predicted.** The pre-registered baseline (before any
  fix, from the already-captured real run) was 20 of 129 confirmed high-risk boundaries matching
  the false-positive shape on the *caller* side. The real before/after diff of confirmed
  high-risk edges:
  - **22 resolved (removed)** — the pre-registered 20 (`UIViewController+Navigation.swift`'s 5,
    plus `UICollectionViewLayoutAttributes`/`WKWebViewConfiguration`/`UITabBarController`/
    `MKMapView` extensions elsewhere), plus 2 more found only by running the real diff (an
    `AppDelegate` extension method in the test target, and a Pods-internal `Mindbox` case) —
    confirming the fix's own scope note that it closes the general "no primary declaration among
    linked files" case, not just the genuinely-external one.
  - **156 newly appeared** — traced, not just counted: 144 of 156 (92%, and effectively all once
    an ObjC-category USR shape a diagnostic regex missed is accounted for) are the *same root
    cause, the other direction*. The original bug affected the *caller* side of an extension-of-
    external-type method (reported `.nonisolated` when it should inherit the extended type's real
    isolation) — but it affected the **callee** side identically: a call *into* a project-local
    extension method of `UINavigationController`/`UIApplication`/`UIViewController`/etc. (e.g.
    `pushViewController(_:animated:)`, `topViewController(base:)`) previously saw that callee
    report `.nonisolated` too, so a `nonisolated`-caller-into-`nonisolated`-callee edge was never
    flagged at all — a **false negative**, the strictly worse failure class this tool's whole
    value proposition cannot tolerate. Fixing the callee's own isolation the same way as the
    caller's necessarily un-masks every one of these real, previously-invisible risks at once.
    Net: **129 → 253 confirmed high-risk boundaries** (unique caller/callee pairs) — a real,
    substantial increase, and a *correct* one: every sampled case traced to a genuine, previously
    wrong `.nonisolated` classification on one side of a real UIKit/AppKit-derived type, not a new
    bug in the fix itself.
  - `External oracle: 2606 resolved, 11005 conformance(s) updated, 3234 unknown` (up slightly from
    Gap B's own 2434/10898/3208, consistent with the new containingTypeUSR need triggering a
    modest number of additional resolutions).
- Full `swift test -c release`: 230/230 passing (220 pre-fix plus 10 new: 5 `DeclarationLinker`-
  level unit tests for the two-hop chain and per-extension grouping, 2 real golden-fixture tests
  covering V1-V4 including the two new nested/generic shapes, 1 `ExternalIsolationBackfill` unit
  test for the new containing-type need, 1 real end-to-end test combining `DeclarationLinker` +
  `ExternalIsolationBackfill` + a real `AppKit` bulk extraction + the unmodified
  `IsolationInferenceEngine`, plus one real, subtle path-identity bug found and fixed along the
  way: macOS's `/var` is an APFS *firmlink* to `/private/var`, invisible to `Foundation`'s
  `URL.resolvingSymlinksInPath()` but resolved by the real compiler/index-store machinery and by
  POSIX `realpath(3)` — test fixtures built under `NSTemporaryDirectory()` now resolve via
  `realpath(3)` before use, fixing a real (if test-only) location-matching failure).
- **Residual, evidenced limitation** (per the task's own DoD): an extension none of whose members
  ever resolved to a real USR has no hop-1 entry point into this fix at all — left exactly as
  before (placeholder containing type, `.nonisolated`, false-positive-only, never worse). Not
  separately re-measured this session; expected near-zero post-Gap-B, worth a future check if a
  suspiciously-nonisolated extension member is ever reported.

## What's still open

- The `~/ios` `highRiskBoundaries` before/after diff, now that Gap B is closed and a full run can
  actually complete — see the Gap B section's own real-run result above.
- `~/SQLumen`'s `highRiskBoundaries` 38→93 change is real output but not yet individually audited
  against `swiftc` ground truth the way the golden-fixture matrix's cases are.
- The Pods/Carthage-in-scope question (`docs/task-pods-in-scope-research.md`) — explicitly deferred,
  a product decision, not a Gap B correctness fix.

## Verification

- `swift test -c release`: 207/207 passing (202 from G1-G6, H1's direction-verification live test,
  H2's two `DeclarationLinker` unit tests, and the whitespace-path-escaping fix's own unit + live
  tests), including new unit/live tests for `G1` (sibling-file merging), `G2`
  (`XcodeBuildSettingsParser`, `FrameworkModuleDiscovery`, `BulkExtractionEnvironmentProviding` —
  both Xcode and SwiftPM variants), and the existing golden-fixture matrix (unaffected, still
  passing, proving no correctness regression from any of this). `CapstoneCLITests.swift` was
  updated, not just re-passed unchanged, to reflect Gap A's genuinely improved fixture output (see
  above).
- `~/SQLumen`: a real, complete, successful end-to-end run, `External oracle: 528 resolved`.
- `~/ios`: architecture validated (discovery, extraction, laziness all independently confirmed
  correct via live tests and the diagnostic pass); Gap A's edge-level hit-rate improvement measured
  directly (4.3%→39.2%, 87.9% fewer live-query misses); full-run completion still blocked on Gap B
  (declaration-level misses, untouched by this phase).
