# Task: fix the accessor USR-granularity mismatch (CLOSED) and the real-scale DeclarationLinker gap (OPEN)

**Status: Gap A (accessor/property USR-granularity mismatch) is CLOSED — implemented, tested,
measured. Gap B (`DeclarationLinker` real-scale linking gap) remains open — superseded by the more
detailed, quantified `docs/task-gap-b-declaration-linker-real-scale.md`, which also documents a
separate whitespace-path-escaping bug found and fixed while measuring Gap B's real cost. Start
there, not here, for Gap B work.** Originally written immediately after
`docs/task-compiled-dependency-isolation-performance.md` was fully implemented (module discovery,
lazy compiler-args, subprocess timeouts, parallel bulk extraction — all landed, tested, 202/202
`swift test -c release`) and real-world-validated against `Project Iris`, where a **new, deeper root
cause** was found: the performance problem was never primarily about missing bulk-module coverage.
It's two separate, pre-existing structural gaps that only manifest at real-project scale.

**Gap A's closure, for the record** (full detail in `docs/priority-3-compiled-dependency-isolation.md`'s
own "Gap A" section — this file's Gap A sections below are kept as the original problem statement,
not rewritten, since the fix matched the diagnosis closely): `IndexStoreQuerying
.owningPropertyUSR(forUSR:)` (`Sources/IndexStoreIntegration/IndexStoreClient.swift`), using
`IndexStoreDB`'s real `.accessorOf` relation (verified directly against the checked-out
`swiftlang/indexstore-db` source, not assumed), applied inside `DeclarationLinker.link(_:)` to
canonicalize both `callerUSR` and `calleeUSR` of every call-graph edge. Measured on `Project Iris`:
edge-level bulk-cache hit rate 4.3%→39.2%, live-query-miss volume down 87.9%. `Swift`/
`CoreFoundation` were also added to `BulkSymbolGraphExtractor.defaultModules` (measured cheap: ~1.2s/
~0.5s respectively) alongside this fix. Gap B, below, is unaffected and still needs its own session.

## 1. How this was found

After the performance task's fixes landed, a full `Project Iris` run still took 15-30+ minutes (target:
low single-digit minutes) despite bulk-cache discovery correctly finding and extracting 52 modules
(7 well-known SDK modules + 45 real CocoaPods/XCFrameworks, confirmed via a live diagnostic run —
discovery itself completes in ~8.5 seconds). Rather than run another 20+ minute cycle blindly, a
temporary diagnostic was added to `ExternalIsolationBackfill`'s edge-level and declaration-level
triggers: right before each would fall through to the (slow) live `cursorinfo` oracle, log whether
the bulk cache had a hit or miss, and short-circuit to `unknown` immediately on a miss (skipping
the live query entirely) so a full pass over the whole project completes in seconds instead of
tens of minutes. This produced exact counts and samples of every residual USR, without waiting
through the expensive live-query loop at all. (The diagnostic itself was temporary and has been
reverted — not present in the codebase; re-add the same shape if useful for verifying a fix.)

Real numbers from that diagnostic run against `Project Iris` (2209 files, 46010 declarations, 137657
call-graph edges):
- **Edge-level trigger**: 850 bulk-cache hits, **18957 misses**.
- **Declaration-level trigger**: **28134 misses**, and — this is the striking part —
  **100% of them** (28134/28134) have a `syntactic:`-prefixed USR in their unresolved
  superclass/protocol need. `syntactic:X` is `SyntaxAnalysis.DeclarationExtractor`'s own internal
  placeholder scheme for a syntactically-recognized-but-not-yet-linked declaration
  (`IndexStoreIntegration/DeclarationLinker.swift`'s job is to resolve these to real index-store
  USRs) — **it is never a real external-dependency USR**. Every single declaration-level "miss"
  this task's whole bulk/live oracle machinery was built to resolve is, on this real project,
  actually a *project-local* type reference the linker itself failed to resolve. Real examples
  captured verbatim: `needs=syntactic:CodingKey`, `needs=syntactic:UICollectionViewCell,syntactic:
  UICollectionViewDelegateFlowLayout,...`, `needs=syntactic:NotificationsListViewInput`,
  `needs=syntactic:ManagerAssembly`, `needs=syntactic:CellConfigurable`. Some of these
  (`UICollectionViewCell`, `UICollectionViewDelegate`) are real UIKit protocols/classes that
  *should* have linked to a real, already-bulk-covered USR; most others
  (`NotificationsListViewInput`, `ManagerAssembly`, `CellConfigurable`, `ReviewsAndFeedbackModule`)
  are unambiguously this project's *own* protocols, which can never be resolved by any external
  oracle (bulk or live) no matter how complete its module coverage is.
- Of the 18957 edge-level misses, **11400 (60%) have a USR beginning with the project's own module
  prefix** (`s:9Ls_net_ru...`, confirmed via the mangling-embeds-module-name rule already verified
  in the performance task) — e.g. `s:9Ls_net_ru29ProductReturnSuccessTableCellC15cellConstraints...
  LLSaySo18NSLayoutConstraintCGvg` (note the trailing `vg` — a synthesized property-getter mangling
  suffix). The **other 7557** are real external USRs, but many are *also* accessor-suffixed and
  *still* miss a bulk cache that successfully extracted the owning module — e.g.
  `s:10Foundation4DateV21timeIntervalSince1970Sdvg` (`Foundation` was bulk-extracted this session's
  fix specifically added, yet this exact symbol still misses) and
  `s:7Mindbox20InappScheduleManagerC012presentationD0...pvs` (`Mindbox` was discovered and
  bulk-extracted, confirmed present in the discovery diagnostic's own module list, yet this
  property's *setter* still misses). A large separate slice of the external misses are bare Swift
  standard-library symbols never covered by any list at all: `s:Sa12arrayLiteralSayxGxd_tcfc`
  (`Array`'s literal initializer), `s:Sb1nopyS2bFZ` (`Bool`'s `!` operator),
  `s:14CoreFoundation7CGFloatV14integerLiteralACSi_tcfc` (`CGFloat` integer-literal init) — `Swift`
  itself (and `CoreFoundation`) are not in `BulkSymbolGraphExtractor.defaultModules`.

**Conclusion**: the dominant cost driver is not "which modules get bulk-extracted" — it's two
separate, structural gaps:

### Gap A — accessor/property USR-granularity mismatch (performance *and* completeness)

`swift symbolgraph-extract`'s output (and, separately, `sourcekitd`'s live `cursorinfo` response)
both key a property by its own single, canonical USR (e.g. `Date.timeIntervalSince1970`'s own
USR). `IndexStoreDB`'s call-graph, by contrast, records a call to a property read/write as a call
to that property's *synthesized accessor* — a **separate, distinct USR** (mangling-suffixed `vg`
get / `vs` set / `vM` modify / etc., appended after the property's own mangled name). Neither the
bulk cache (`ExternalIsolationBackfill.bulkSymbolGraphCache`, dictionary-keyed by exact USR) nor
the live oracle's `USRMatching.select` (exact-USR match against `cursorinfo`'s candidate results)
can ever match these two different strings, no matter how completely the owning module is
extracted or how correctly the live query resolves the call site. This was already noted, in
miniature, as an accepted limitation during Phase C's capstone-test regression
(`docs/priority-3-phase-c-oracle-triggers.md`: "a real granularity mismatch... IndexStoreDB's own
getter/setter USRs and sourcekitd's property-level USR") — but at real-project scale, every single
property/subscript read or write anywhere in the analyzed code becomes one of these permanently
unmatchable misses, which is both a real performance cost (every one of them is attempted against
the live oracle before landing in `unknown`, today) and a real completeness gap (each one becomes
an `unknown` edge that might, if resolved, turn out to be a real cross-isolation risk or might not
— currently indistinguishable).

### Gap B — `DeclarationLinker` real-scale linking coverage (a pre-existing, unrelated bug)

Every declaration-level miss on `Project Iris` traces to an unresolved `syntactic:`-prefixed placeholder
USR — meaning `IndexStoreIntegration/DeclarationLinker.swift`'s own linking pass (Priority 1/2 era
code, predates the entire compiled-dependency-isolation feature) is failing to resolve a large
number of project-local protocol/superclass references on a real, ~46000-declaration project, even
though the exact same mechanism works correctly on every existing fixture
(`Tests/Fixtures/*`, all far smaller). This is **not** a compiled-dependency problem at all — fixing
it doesn't need `sourcekitd`, bulk extraction, or anything this feature built. It needs its own
investigation into why `DeclarationLinker`'s disambiguation logic (name-based matching among
`IndexedSymbol` candidates at a given source location, see
`Tests/IndexStoreIntegrationTests/DeclarationLinkerUnitTests.swift` for the existing, small-scale
tested cases) breaks down at real scale. Until fixed, **every** declaration-level oracle trigger on
a real project is wasted, expensive work chasing something that was never externally resolvable in
the first place.

## 2. What "done" must mean

### Gap A (accessor granularity) — CLOSED, all four items below done
1. A real, verified mapping from a synthesized-accessor USR back to its owning property's own USR
   -- likely via Swift name-demangling (no existing dependency on `libswiftDemangle` in this
   project; investigate whether `swift demangle` as a subprocess, or a small hand-written
   suffix-stripping parser validated against a real corpus of captured accessor USRs, is the right
   level of investment) or via re-deriving the mapping from `IndexStoreDB`'s own richer symbol
   metadata (check whether `IndexedSymbol`/the underlying `indexstore-db` API already exposes an
   accessor's "owning property" relationship directly, which would avoid demangling entirely — this
   should be checked *first*, before building any demangler).
2. Apply this mapping *before* consulting either the bulk cache or the live oracle, for both the
   edge-level and declaration-level triggers in `ExternalIsolationBackfill.swift` — so
   `Date.timeIntervalSince1970`'s getter resolves via the *already bulk-extracted* `Foundation`
   entry instead of falling to (and failing) the live path.
3. Add `Swift` (the standard library) itself to `BulkSymbolGraphExtractor.defaultModules` (or a
   verified-equivalent bulk source) — confirmed cheap and fast to extract this session, just never
   added. `CoreFoundation` may be worth the same treatment; verify.
4. A real before/after count of edge-level bulk-cache hit rate against `Project Iris` (850/19807 ≈ 4.3%
   today) — the fix should move this dramatically, and that number itself is the acceptance
   criterion, not a vibe.

### Gap B (DeclarationLinker real-scale coverage)
1. Root-cause why the linker's disambiguation fails at scale on `Project Iris` specifically — reproduce
   with a *minimal* real extracted case (one of the captured `syntactic:NotificationsListViewInput`
   / `syntactic:ManagerAssembly` examples is a concrete, real starting point — find the actual
   source declaration and trace why `DeclarationLinker` never resolves it), not by guessing.
2. Fix it, or if there's a structural reason real-scale linking can't reach 100% (e.g. a genuine
   IndexStoreDB query-volume/ordering issue), document the real, evidenced ceiling.
3. Re-run the same diagnostic-style pass (temporarily re-instrument `ExternalIsolationBackfill` the
   same way, or build a small standalone linking-coverage report) against `Project Iris` and confirm the
   `syntactic:`-prefixed miss count drops to near zero.

### Combined acceptance
- Full `Project Iris` run (real, complete, not diagnostic-short-circuited) lands in low single-digit
  minutes, per the original performance task's target — this task's fixes are very likely what
  actually gets there, since the performance-task's own module-discovery work (correct, tested, and
  landed) turned out not to be the dominant cost.
- `External oracle: N resolved` meaningfully nonzero and the `unknown` count meaningfully smaller
  than today's.
- Full `swift test -c release` suite green, no regression.
- A decision record in this project's `docs/priority-3-*.md` convention, with real before/after
  numbers from both `Project Iris` and `~/SQLumen`.

## 3. Relevant existing architecture

- `Sources/swift-isolation-map/ExternalIsolationBackfill.swift` — both trigger loops
  (`resolveEdgeLevelTriggers`, `resolveDeclarationLevelTriggers`); the exact code shape used for
  this session's temporary diagnostic (log a hit/miss right where `bulkCache[targetUSR]` is
  checked, short-circuit under an env-var guard) is a fast, cheap way to re-verify any fix without
  a full 20+ minute run.
- `Sources/SourceKitDIntegration/USRMatching.swift` — the live oracle's exact-match selection logic
  ; any accessor-to-property mapping needs to compose with this, not bypass its `"::SYNTHESIZED::"`
  handling.
- `Sources/SourceKitDIntegration/BulkSymbolGraphExtractor.swift` — `defaultModules`; add `Swift`
  once verified.
- `Sources/IndexStoreIntegration/DeclarationLinker.swift` — Gap B's actual bug lives here;
  `Tests/IndexStoreIntegrationTests/DeclarationLinkerUnitTests.swift` for the existing, passing,
  small-scale coverage that doesn't yet reproduce the real-scale failure.
- `docs/priority-3-phase-c-oracle-triggers.md` — the original, smaller-scale sighting of Gap A.
- `docs/task-compiled-dependency-isolation-performance.md` — the sibling task this one supersedes
  as "the thing actually gating real-world usability"; its own fixes (module discovery, laziness,
  timeouts, parallelism) remain correct and necessary, just not sufficient alone.

## 4. Explicitly out of scope

- Re-doing any of the performance task's module-discovery/laziness/parallelism work — it's done,
  tested, and should be reused as-is.
- Changing `IsolationInferenceEngine` — still untouched, still the right invariant.
- Anything about the risk heuristic or report schema.
