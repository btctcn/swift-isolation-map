# Research task: speed up the external-isolation oracle without changing any result

**Status: research task, not yet designed or implemented. Hard constraint from the user, load-
bearing for the whole task: no reduction in analysis quality/accuracy is acceptable — a speedup
that resolves fewer USRs, changes any `.resolved`/`.unknown` outcome, or silently skips work is not
a valid solution, however fast.** Written immediately after Gap B closed and a real,
non-diagnostic-shortcut `~/ios` run was measured end to end (`docs/priority-3-compiled-dependency-
isolation.md`'s Gap B section) — this task starts from that real, current baseline, not a guess.

## 1. The real, current baseline

A full `~/ios` run (2209 files, 46007 declarations, 137657 call-graph edges) finishes in **29
minutes 41 seconds** wall-clock (`86% cpu`) post-Gap-B — down from an estimated 35-40 hours before
it, and a genuinely usable number today. The remaining cost is now overwhelmingly the **live
`sourcekitd` oracle queries**: `External oracle: 2434 resolved, 10898 conformance(s) updated, 3208
unknown` on that run, against a diagnostic-measured trigger volume of **3782 distinct edge-level
USRs + 3388 declaration-level triggers (3262 distinct (nominal, protocol) pairs) = up to ~7170
live query attempts**, whatever fraction of those the bulk symbol-graph cache doesn't already
satisfy for free. This task is about making *those* queries finish faster, not about reducing how
many facts get resolved.

## 2. Confirmed, verified facts (read directly this session, not assumed)

1. **Both oracle trigger loops are strictly sequential, with zero concurrency.**
   `Sources/swift-isolation-map/ExternalIsolationBackfill.swift`: `resolveEdgeLevelTriggers`
   (`for edge in linked.callGraph { ... await query(...) }`) and `resolveDeclarationLevelTriggers`
   (`for declaration in linked.declarations.values { ... await query(...) }`) are both plain `for`
   loops awaiting one query at a time, and `resolve(_:)` runs the edge-level loop, then the
   declaration-level loop, one after the other — never overlapping.
2. **`SourceKitDClient` is a Swift `actor`, deliberately, which unconditionally serializes every
   call regardless of what calls it concurrently.** Its own doc comment (verbatim,
   `Sources/SourceKitDIntegration/SourceKitDClient.swift`, lines 3-10) states this was a conscious
   choice: *"unlike `IndexStoreClient`... raw `sourcekitd_send_request_sync` concurrency safety
   has **not been independently verified** (the research spike ran every query single-threaded).
   An `actor` serializes every call unconditionally — the simpler, safer default."* This is the
   single most important existing fact for this task: **even if the two trigger loops above were
   rewritten to issue concurrent requests, every one of them would still funnel through this one
   actor and be serialized exactly as today**, until/unless this documented, deliberate assumption
   is itself revisited — which requires exactly the kind of empirical verification this project has
   done for every other real change this session (Gap A's `.accessorOf` direction, Gap B's
   `.baseOf`/`.extendedBy` direction and shape), not assumed from first principles.
3. **A real, live `sample` profile taken this session** (during the actual 29:41 `~/ios` run, not a
   synthetic test) showed the actual parsing/type-checking work
   (`swift::CompilerInstance::performSema()`, `swift::Parser::parseDecl`, etc., all running as
   library code inside `sourcekitdInProc`, dlopen'd into our own process — confirmed no separate
   `swift-frontend` process is spawned for this path) happening on a thread explicitly labeled
   **`DispatchQueue_76: sourcekit.swift.ASTBuilding (serial)`**. This is a real, directly-observed
   data point, not a guess — but it was captured during our *own* single-threaded query issuance,
   so it does **not** by itself prove sourcekitd would still serialize AST-building work across
   *genuinely different files* under concurrent client load (a plausible sourcekitd architecture has
   one such queue *per compilation context*, allowing real cross-file parallelism; an equally
   plausible one has a single global queue, in which case concurrency would buy little to nothing).
   **This is the crux fact this task must resolve empirically before writing any production code.**
4. **`compilerArguments(forFile:)` is already memoized** (`LiveXcodeCompilerArgumentsProvider`'s
   `cachedArguments: [String: [String]]?`) — the expensive part (parsing the real xcodebuild
   verbose log) happens once, not once-per-query. Not a source of the current cost; ruled out,
   not guessed.
5. **Third-party CocoaPods/XCFramework bulk-cache coverage already exists**
   (`Sources/ProjectResolution/FrameworkModuleDiscovery.swift`, confirmed empirically against
   `~/ios` per its own doc comment: "each CocoaPods/XCFramework dependency gets its own directory"
   under `FRAMEWORK_SEARCH_PATHS`) — narrows, but doesn't rule out, "bulk-cache coverage is
   incomplete" as an explanation for the residual live-query volume; worth a real measurement (see
   hypothesis 3 below), not an assumption either way.

## 3. Hypotheses, ranked, each requiring empirical verification before implementation

1. **(Primary, highest expected payoff) Concurrent oracle query issuance, IF sourcekitd's real
   thread-safety and internal parallelism allow it.** The verification step, before any design
   work: build a small, dedicated experiment — issue N `cursorInfo` requests concurrently against
   a *single* real `sourcekitdInProc` session (bypassing the `actor`'s serialization deliberately,
   in an isolated test), across (a) the same file at different offsets and (b) several different
   files, and check both **correctness** (do results match a sequential run byte-for-byte? does
   anything crash, hang, or return malformed data under concurrent load?) and **actual wall-clock
   speedup** (does it get faster at all, and does that speedup come from cross-file parallelism,
   from something else, or not materialize). If, and only if, this comes back positive: redesign
   query issuance as three explicit phases, not one interleaved loop, both to enable concurrency
   safely and to *preserve* Phase I3's per-pair dedup guarantee under it (two concurrent tasks must
   never both attempt the same still-unresolved (nominal, protocol) pair or the same edge-level
   USR — collect the complete, already-deduplicated set of distinct work items *first*, single-
   threaded, exactly as today; only the second phase — executing those already-distinct items —
   should run concurrently; the third phase, applying each item's resolved outcome back to every
   declaration/edge that shares it, is a deterministic merge, mirroring
   `BulkSymbolGraphExtractor.extractAll`'s own established precedent in this codebase (per-slot
   writes from `DispatchQueue.concurrentPerform`, merged back in a fixed, deterministic order
   afterward, never a shared dictionary mutated from parallel closures)). If sourcekitd turns out to
   genuinely serialize everything regardless, this hypothesis's payoff may be small or zero —
   report that honestly rather than forcing a rewrite that doesn't help.
2. **A necessary corollary of hypothesis 1, not a separate hypothesis**: revisiting
   `SourceKitDClient`'s `actor` isolation itself (e.g., a pool of several independent
   `sourcekitdInProc` sessions/instances, each its own actor, work distributed across them) *only*
   if verification confirms multiple concurrent `sourcekitd_send_request_sync` calls — whether on
   one shared session or several independent ones — are actually safe and actually parallelize.
   Prefer the simplest design the verification data supports; don't build a session pool if a
   single session already parallelizes internally once its own serialization is relaxed.
3. **(Secondary, lower priority, genuinely different lever) Persistent cross-run caching of
   resolved external-USR isolation facts**, keyed by real USR, written to disk next to the existing
   `.swift-isolation-map-manifest.json` staleness manifest (same established location/precedent).
   This doesn't help a first, cold run (this task's own stated baseline) but could make *repeated*
   runs during iterative development dramatically cheaper, since external SDK/Pods symbols' own
   isolation facts don't change between two runs of the same project on the same machine/toolchain.
   Needs an honest invalidation story so accuracy never silently rots (e.g., scope the cache per
   toolchain version + SDK path + discovered-module set fingerprint, and provide an explicit
   `--force-reindex`-style escape hatch) — a correctness risk this hypothesis introduces that
   hypothesis 1 does not, so it should be designed and reviewed with that risk explicit, not
   glossed over just because the win is real.
4. **(Worth a measurement, not an assumed fix) Is `FrameworkModuleDiscovery`'s `.framework`-bundle-
   only detection missing any real dependencies?** CocoaPods without `use_frameworks!` (a static-
   library-only integration) would not produce a discoverable `.framework` bundle at all — worth
   checking, on a real project, whether any of the "3208 unknown" declaration-level results (or
   their edge-level equivalent) trace back to a Pod that was never discovered for this reason. If
   so, this is a coverage gap independent of concurrency, with its own, separate fix shape (likely
   parsing `SWIFT_INCLUDE_PATHS`/other build settings for statically-linked module names) — treat
   as its own follow-up, not bundled into this task's own Definition of Done unless the measurement
   shows it's actually contributing meaningfully to the residual live-query cost.

## 4. Definition of done

1. The sourcekitd concurrency-safety question (hypothesis 1's crux) is answered empirically, with
   the real experiment's method and result written up plainly — "yes, safe and parallelizes
   across files," "yes safe but doesn't parallelize," or "no, unsafe" are all acceptable, valid
   outcomes; the task is not done by *assuming* an answer.
2. If concurrency is adopted: the three-phase (collect distinct work → execute, possibly
   concurrently → deterministic merge) restructuring is implemented for both trigger loops,
   Phase I3's per-pair dedup guarantee holds under concurrency (a dedicated test: two declarations
   sharing one still-unresolved pair, run concurrently, assert the live query fires exactly once —
   mirroring this session's own existing `declarationLevelTriggerDedupesPerMemberConformanceCopies`
   test, extended for the concurrent path).
3. **The hard correctness gate**: running the *exact same real project* through both the old
   (sequential) and new (concurrent, or whatever the chosen design is) code paths produces
   byte-identical `backfilledDeclarations`/`updatedDeclarations`/`unknownUSRs` — a diff, not an eye-
   ball check. If a future non-determinism is discovered (e.g., a race that occasionally resolves a
   collision differently), that is a blocking correctness bug in this task's own work, not an
   acceptable "usually fine" tradeoff.
4. A real, honest, measured before/after wall-clock number on `~/ios`, the same way every other
   change this session has been measured (not extrapolated from a partial or diagnostic run).
5. Full `swift test -c release` green throughout.
6. A decision record appended to `docs/priority-3-compiled-dependency-isolation.md`, matching this
   project's established convention, explicit about which hypothesis (if any) actually shipped and
   why, including an honest report if the concurrency experiment came back negative.

## 5. Relevant existing architecture

- `Sources/swift-isolation-map/ExternalIsolationBackfill.swift` — both trigger loops
  (`resolveEdgeLevelTriggers`, `resolveDeclarationLevelTriggers`), Phase I3's own
  `conformancePairOutcomes` per-pair dedup cache (the exact mechanism a concurrent redesign must
  preserve the guarantee of, restructured into a collect-then-execute-then-apply shape).
- `Sources/SourceKitDIntegration/SourceKitDClient.swift` — the `actor`-based serialization and its
  own explicit "not independently verified" caveat; `docs/priority-3-phase-b-sourcekitd-client.md`
  for the full original decision record behind that choice.
- `Sources/SourceKitDIntegration/BulkSymbolGraphExtractor.swift`'s `extractAll` — the established,
  already-tested precedent for "parallelize independent work via `DispatchQueue.concurrentPerform`,
  write to per-index slots, merge deterministically afterward" that any concurrent redesign here
  should mirror, not reinvent.
- `Sources/ProjectResolution/FrameworkModuleDiscovery.swift` — for hypothesis 4's coverage
  question.
- `docs/task-gap-b-implementation-plan.md` / `docs/task-gap-b-declaration-linker-real-scale.md` —
  the verify-before-trust discipline and documentation shape this task should follow; both were
  closed successfully this session using it.

## 6. Explicitly out of scope

- Anything that changes *which* USR resolves to *what* isolation, or *whether* something resolves
  at all versus falls to `unknown` — this task is pure latency, zero semantic change, by the user's
  own explicit constraint.
- Re-touching Gap A, Gap B, or the extension-of-external-type isolation gap
  (`docs/task-external-type-extension-isolation.md`) — all separate, already-scoped work.
- The bulk symbol-graph extraction phase's own internal concurrency
  (`DispatchQueue.concurrentPerform` in `extractAll`) — already implemented, tested, and not the
  bottleneck this task is about (it runs once, up front, and finishes in seconds per the module
  extraction times already documented in `docs/priority-3-compiled-dependency-isolation.md`).
- Any reduction in what gets bulk-extracted or live-queried in the name of speed (e.g., skipping a
  module, sampling instead of resolving every USR) — explicitly ruled out by the user's own stated
  constraint.
