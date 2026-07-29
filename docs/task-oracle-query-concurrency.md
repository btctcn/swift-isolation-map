# Research task: speed up the external-isolation oracle without changing any result

**Status: research task, not yet designed or implemented. Hard constraint from the user, load-
bearing for the whole task: no reduction in analysis quality/accuracy is acceptable — a speedup
that resolves fewer USRs, changes any `.resolved`/`.unknown` outcome, or silently skips work is not
a valid solution, however fast.** Written immediately after Gap B closed and a real,
non-diagnostic-shortcut `Project Iris` run was measured end to end (`docs/priority-3-compiled-dependency-
isolation.md`'s Gap B section) — this task starts from that real, current baseline, not a guess.

## 1. The real, current baseline

A full `Project Iris` run (2209 files, 46007 declarations, 137657 call-graph edges) finishes in **29
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
3. **A real, live `sample` profile taken this session** (during the actual 29:41 `Project Iris` run, not a
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
   `Project Iris` per its own doc comment: "each CocoaPods/XCFramework dependency gets its own directory"
   under `FRAMEWORK_SEARCH_PATHS`) — narrows, but doesn't rule out, "bulk-cache coverage is
   incomplete" as an explanation for the residual live-query volume; worth a real measurement (see
   hypothesis 3 below), not an assumption either way.

## 2.5. External research response, critically checked against the real local binary (not accepted on authority)

A research response (`oracle-concurrency-research-response.md`) was submitted, citing C++ source
from `swiftlang/swift` at `release/6.3` (claimed to match this machine's Xcode 26.4 / Swift 6.3
toolchain) for architecture facts it says answer this task's crux question. Per this project's
standing discipline, its claims were checked against real evidence before being trusted — but no
local `swiftlang/swift` checkout exists on this machine (only `indexstore-db`/`swift-syntax` are
vendored via SPM), so a line-by-line source diff wasn't possible. Instead, every identifier the
response's argument depends on was checked for **literal presence in the real, installed
`sourcekitdInProc` binary this project actually dlopen's** (`.../Xcode-26.4.0.app/.../
sourcekitdInProc.framework/Versions/A/sourcekitdInProc`, via `strings -a`) — a different, genuinely
independent form of verification than re-reading the same cited source, and arguably more directly
relevant since it confirms the facts against the exact toolchain this tool runs against, not just
"a branch that should match."

**Confirmed present, exactly as cited:**
- `sourcekit.swift.ASTBuilding` — the serial AST-build queue's label (§1.1's crux claim). This also
  matches, independently, this project's own earlier real `sample` profile capture (section 2 item
  3 above) — two unrelated forms of evidence (a live profiler capture from an earlier session, and
  a binary string search this session) now agree.
- `sourcekit.request.semantic` — the concurrent semantic-request intake queue (§1.2).
- `ASTProducer.BuildOperationsQueue` — the per-producer bookkeeping queue the response says is a
  distinct, non-serializing concern from `ASTBuildQueue` (§1.1's parenthetical).
- `sourcekit.swift.ASTCache` — the AST cache the response says backs cache-locality/eviction (§2).
- `key.cancel_on_subsequent_request` — the implicit-cancellation request key (§1.3's hazard).
- `source.request.statistics` and `DidReuseAST: ` — the two measurement hooks (§1.4).
- The exact statistics UIDs, found by a broader `strings -a` pass (more precise than the response
  itself, which only named the C++-side variable identifiers, not the wire UIDs):
  `source.statistic.num-ast-builds`, `source.statistic.num-ast-cache-hits`,
  `source.statistic.num-ast-snapshot-uses`, `source.statistic.num-asts-in-memory` /
  `max-asts-in-memory`, `source.statistic.num-open-documents` / `max-open-documents`,
  `source.statistic.num-requests`, `source.statistic.num-semantic-requests`,
  `source.statistic.instruction-count`. This makes §1.4's "free instrument" claim concretely
  actionable, not just plausible: `source.request.statistics` really does return (at minimum) a
  `num-ast-builds` and `num-ast-cache-hits` pair on this exact toolchain.

**What this does and doesn't prove.** String presence confirms the response didn't invent these
identifiers and that they exist in the real binary this project depends on — strong evidence the
architecture it describes is real. It does **not** by itself prove the response's *control-flow*
narrative (e.g., "every build operation, regardless of file, is scheduled onto that one queue") --
that's a claim about code paths, not symbol tables, and strings can't confirm it. That narrative
remains consistent with, and is the most likely explanation for, this project's own real `sample`
profile evidence (a single `DispatchQueue_76: sourcekit.swift.ASTBuilding (serial)` thread doing all
observed AST-building work) — but the task's own crux (does this hold under genuinely concurrent,
cross-file load, not just our historical single-threaded issuance?) is unchanged and still requires
the live micro-spike this task's DoD already mandates. The response does not shortcut that
requirement — it explicitly says so (§0 and §6 step 2) — and this review agrees.

**Net assessment: the response's architecture claims are well-grounded and its two structural
recommendations are adopted into this task's plan below** (re-ranking hypotheses, not just adding
to them):
1. **Lever 0 (ordering) ships first, unconditionally, before any concurrency work.** It is provably
   semantics-preserving by construction (same queries, same session, same serial issuance, only
   sorted differently, deterministic merge already mandated by this task's own DoD 2/3) — zero new
   correctness risk, so it does not need to wait on the concurrency-safety spike at all. It is also
   exactly the "collect distinct work first" restructuring hypothesis 1 already required, so it is
   not wasted effort even if concurrency is later rejected.
2. **The mandatory `key.cancel_on_subsequent_request: 0` requirement is adopted as a hard rule**
   for any future concurrent design (and as cheap, harmless hygiene even for the current sequential
   one) — a real, confirmed request key (see above) whose documented default would otherwise
   silently cancel in-flight cursor-info requests under concurrent issuance, corrupting results in
   exactly the way this task's hard gate forbids, while *looking* faster. This is a correctness trap
   this task's original hypothesis 1 write-up did not anticipate.
3. **The subprocess-pool reframing of hypothesis 2 is adopted**: a sourcekitd session is
   process-global (`sourcekitd_initialize`/`getGlobalContext()`), and on macOS, dlopen'ing the same
   dylib path twice from one process resolves to the same loaded image and shares its globals (a
   general dynamic-loader fact, not sourcekitd-specific, and not something that needs its own
   spike) — so genuine cross-file AST-build parallelism, if wanted, requires multiple *processes*,
   not an in-process actor/session pool. This changes hypothesis 2's design shape but not its
   priority (still gated on the micro-spike showing concurrency helps at all).
4. **The `source.request.statistics` instrument is adopted as a required, trivial first step**
   ("instrument first") — before implementing anything else, capture `num-ast-builds` /
   `num-ast-cache-hits` before/after the oracle phase on a real `Project Iris` run. If builds already track
   distinct files touched, lever 0 (ordering) won't help and effort should shift straight to the
   concurrency spike; if builds trend toward the query count, ordering is very likely the dominant,
   cheapest fix and should be measured standalone before concurrency is attempted at all.

This changes the task's execution order (see revised section 3/4 below) but changes nothing about
its hard constraint or its DoD's correctness gates.

## 2.6. Follow-up amendments (`oracle-concurrency-task-amendments.md`), confirmed by real execution, not just reasoning

A second document offered three small amendments to §2.5's review, plus a closing note. All were
checked before being accepted — two by real code-search, one by actually building and running the
exact smoke test it proposed (not by evaluating its reasoning alone).

1. **"The `source.statistic.*` counters are cumulative (session-lifetime), not per-phase, so the
   instrument must subtract two snapshots" — confirmed by direct execution, exceeding what the
   amendment itself claimed.** The `CSourceKitD` shim was extended with the missing accessors
   (`sourcekitd_variant_dictionary_get_int64`, `sourcekitd_variant_int64_get_value`,
   `sourcekitd_variant_uid_get_value`, `sourcekitd_uid_get_string_ptr`, and a generic recursive
   `sourcekitd_variant_dictionary_apply_f`-based dumper — all real, exported `sourcekitd` C API
   functions, present in `/private/tmp/sourcekitd.h`, the vendored header this project's shim
   already builds against), and `SourceKitDClient.requestStatistics()` was added
   (`Sources/SourceKitDIntegration/SourceKitDClient.swift`). A live smoke test
   (`Tests/SourceKitDIntegrationTests/SourceKitDClientTests.swift`, folded into the file's one
   existing shared-client test — see point 5 below for why) issued one real
   `source.request.statistics` request, one real cursor-info query, then a second statistics
   request, against a real `sourcekitdInProc` session. Real result: nothing reset between the two
   snapshots — `num-requests` strictly increased, `instruction-count` strictly increased, and
   (in this test's actual shape, where the query re-hits an already-warm AST from an earlier
   assertion in the same test) `num-ast-cache-hits` strictly increased while `num-ast-builds`
   correctly stayed flat. A standalone throwaway run against a genuinely cold cache (before the
   fixture-sharing fix in point 5) additionally showed `num-ast-builds` go `0 → 1` for exactly one
   cold-cache query. Every counter was monotonically non-decreasing across both snapshots, none
   reset. The amendment's arithmetic guidance (`after − before`) is correct and now has a passing
   regression test behind it, not just a citation.
2. **"Log `max-asts-in-memory` in the same snapshots, as hazard 3.5-item-4's own instrument" —
   adopted as written**; the real response dump (below) confirms this counter exists and is
   populated (`source.statistic.max-asts-in-memory`, alongside `num-asts-in-memory` and
   `num-open-documents`/`max-open-documents`), so it costs nothing extra to include in the same
   before/after pair the real `Project Iris` diagnostic run will capture.
3. **"A smoke test should pin the response shape before the diagnostic run depends on it" — done,
   and the real shape turned out richer than either document assumed.** Neither the response nor
   the amendments predicted the exact nesting; the real, confirmed shape is:
   ```
   { key.results: [ { key.kind: <source.statistic.* uid>,
                      key.description: <human string>,
                      key.value: <int64> }, ... ] }
   ```
   Critically, **`key.kind` (a UID) is the correct machine-stable identifier per entry — not
   `key.description`** (a human sentence like `"# of ASTs built or rebuilt"`, workable but far more
   fragile to key production code on). `SourceKitDClient.requestStatistics()` parses by `key.kind`,
   confirmed against the real values (`source.statistic.num-ast-builds`,
   `source.statistic.num-ast-cache-hits`, etc. — exactly the UID strings the §2.5 `strings -a` pass
   found, now confirmed to be the literal per-entry identifiers, not merely present somewhere in
   the binary). This is exactly the kind of surprise the amendment predicted a smoke test would
   catch cheaply, before the real 30-minute `Project Iris` diagnostic run depended on a wrong assumption.
4. **Closing note (the spike already falsifies the control-flow claim, no swift-repo checkout
   needed) — endorsed, no action required beyond what DoD 3 already mandates.** Restated here only
   to record agreement: the still-outstanding concurrent-issuance micro-spike's own `sample`
   capture is the correct, sufficient falsifier for the one claim binary strings could never settle
   (§2.5's own caveat).
5. **Not from either document — a real regression found and fixed while building the smoke test,
   directly relevant to this task's own subject matter.** The new smoke test was first added as its
   own separate `@Test func`, each constructing its own `SourceKitDClient()`. A full
   `swift test -c release` run crashed the entire test process (`exited with unexpected signal code
   11`, i.e. `SIGSEGV`) partway through — not a test failure, the whole `swiftpm-testing-helper`
   process died, taking down every in-flight test with it. This is the *exact* class of bug this
   test file's own pre-existing doc comment already warns about: two `SourceKitDClient` instances
   constructed concurrently (which is exactly what two separate `@Test` functions are, under Swift
   Testing's default parallel execution) race on process-wide `sourcekitd` state and crash — first
   discovered while building the cursor-info path itself, and now confirmed a second, independent
   time by this task's own new test. Confirmed the mechanism (not just pattern-matched on the
   symptom): both tests' "started" log lines appeared, neither ever printed a result, before the
   process died. Fix: merged the new test's body into the file's one existing test function so both
   share the same single `SourceKitDClient` instance, exactly as the file's own established
   discipline already prescribes — not a new synchronization mechanism, since the actual production
   code path (this task's whole subject) already only ever constructs one `SourceKitDClient` per
   analysis run and the test should mirror that, not exercise an unsupported multi-instance shape.
   Re-ran the full suite twice after the fix: 235/235, no crash, both times. **Directly relevant to
   this task's hypothesis 1/2 concurrency work**: any future concurrent design must keep this
   "exactly one `SourceKitDClient`/session" invariant intact regardless of how many *queries* it
   issues concurrently through that one instance — this crash is fresh, real evidence for why
   hypothesis 2's subprocess-pool shape (independent processes, each with its own single session)
   is the correct way to get more sessions, not an in-process pool of several `SourceKitDClient`
   actors sharing the one real process-wide `sourcekitd` state.

**Net effect on the plan**: none of this changes hypothesis ranking or the hard constraint — it
makes the already-adopted "instrument first" step (§2.5 point 4) concretely implemented and tested,
not just designed. The real `Project Iris` diagnostic run (still pending) can now be built directly on
`SourceKitDClient.requestStatistics()` as-is.

**Two follow-up notes on this instrument, both adopted:**

- **Persist the full `byKind` result, not just the two headline counters, in the real `Project Iris`
  diagnostic run.** `requestStatistics()` already parses every `key.results` entry generically (not
  a hardcoded subset), so this costs nothing extra — the diagnostic run's own logging/output should
  write out the complete before/after `byKind` dictionaries (or the raw `dump` string), not just
  `num-ast-builds`/`num-ast-cache-hits`. In particular, `num-ast-snapshot-uses` sitting right next
  to them is worth keeping even though this task doesn't have an immediate use for it: `builds +
  cache-hits + snapshot-uses` need not sum exactly to the request count (one request can consume an
  AST via a snapshot instead of either a build or a plain cache hit), so having the full picture up
  front avoids having to re-run a 30-minute real corpus just to retrieve a counter that turned out
  to matter for interpretation.
- **The smoke test's cache-hit assertion is a deliberate strict-growth (`>`) check, not exact-`+1`
  equality — a conscious choice, not an oversight.** The real, observed value on this toolchain
  (Xcode 26.4 / Swift 6.3) *is* exactly `+1` for one already-warm query (recorded here for the
  record), but the test itself only asserts the counter grew, not by how much: pinning the exact
  secondary count would make the test fail on a future toolchain change (e.g., one that starts
  touching two cache entries per query) that would not itself falsify the cumulative-counter claim
  this test exists to check — a false regression signal in the wrong place. The one exception kept
  as strict, zero-tolerance equality is `num-ast-builds` staying unchanged on an already-warm
  file/args pair — that tests a real caching-correctness invariant this project actually depends
  on, not an incidental magic number, so it should keep failing loudly if it ever regresses.

## 2.7. Real `Project Iris` diagnostic instrument run — decisive result, hypothesis 0 confirmed worth building

The "instrument first" step (§2.5 point 4, §2.6) was run for real: the CLI took a temporary,
env-gated (`SWIFT_ISOLATION_MAP_ORACLE_STATS=1`) `requestStatistics()` snapshot immediately before
and after `ExternalIsolationBackfill.resolve`'s oracle phase, on the real `Project Iris` corpus (2209
Swift files), hooked at the CLI call site in `SwiftIsolationMap.swift` rather than inside
`ExternalIsolationBackfill` itself (avoids adding `requestStatistics()` to the `SourceKitDQuerying`
protocol for a diagnostic that isn't staying in the codebase). Real delta:

```
num-requests:        4825
num-semantic-requests: 4824
num-ast-builds:       4780
num-ast-cache-hits:     44
num-ast-snapshot-uses:   0
max-asts-in-memory:      8
```

**Interpretation, decisive without needing a second run.** `num-ast-builds` (4780) is ~99% of
`num-requests` (4825) — almost every live oracle query pays a fresh typecheck, essentially no reuse
(only 44 cache hits, 0 snapshot uses). Critically, the real corpus has exactly **2209** total Swift
files (confirmed by the CLI's own `verbose` file count) — so by simple pigeonhole, at least `4780 -
2209 = 2571` of those 4780 builds *must* be redundant rebuilds of a file whose AST had already been
built at least once earlier in the same run, since builds cannot exceed the number of distinct
files even in the worst case of zero query-to-query file sharing. In reality the true redundancy is
almost certainly far larger than this floor, since declaration-level triggers cluster at a
comparatively small set of declaring files and edge-level triggers cluster at a comparatively small
set of caller files — but the floor alone already settles the question the instrument was built to
answer: this is squarely the "`num-ast-builds` trends toward the number of queries, not distinct
files" case §1.4/§2.5 predicted, meaning **hypothesis 0 (file-sorted ordering) is confirmed to be
worth building**, not just plausible.

`max-asts-in-memory: 8` also confirms amendment 2's prediction: eviction pressure is already severe
under today's *sequential*, unordered issuance (only 8 ASTs ever resident at once against a corpus
this large) — reinforcing, not just permitting, hypothesis 0's core mechanism (grouping a file's
queries contiguously so they land before that file's own AST gets evicted by unrelated files'
activity in between).

Real run otherwise came back clean and consistent with the last confirmed `Project Iris` run (`
highRiskBoundaries: 329`, `typesAnalyzed: 34825` — matching the cross-file-collision fix's own
closing numbers, no regression from the diagnostic instrumentation itself).

**Decision, per this section's own data**: proceed directly to implementing hypothesis 0 (§3 item
0) next — the diagnostic step has done its job and does not need to be repeated before that work
starts. The diagnostic instrumentation in `SwiftIsolationMap.swift` remains temporary and
env-gated; revert it once hypothesis 0's own before/after measurement (which can reuse the same
`requestStatistics()` hook to confirm the *post*-ordering `num-ast-builds`/`num-ast-cache-hits`
ratio actually improved) is captured for the decision record.

## 3. Hypotheses, ranked, each requiring empirical verification before implementation

0. **(New, promoted to first — ships unconditionally, before the concurrency spike) AST cache
   locality via query ordering.** Cost model, from the confirmed real `sourcekit.swift.ASTCache`
   (§2.5): a query is cheap iff the AST for its `(file, compiler args)` is already cached; with
   2209 files queried in call-graph/declaration-table order, nothing guarantees consecutive queries
   share a file, so every file switch risks paying a fresh typecheck, potentially more than once
   per file over a whole run. Fix: collect the complete deduplicated work-item set first (single-
   threaded, exactly as Phase I3's dedup already requires), execute it **sequentially but sorted by
   (compiler-args hash, file, offset)**, then apply outcomes in a fixed canonical order (mirroring
   `BulkSymbolGraphExtractor.extractAll`'s existing merge precedent). This is the same three-phase
   restructure hypothesis 1 below needs anyway — implementing it with sequential, sorted execution
   first means it's required infrastructure regardless of what the concurrency spike concludes, and
   it carries **zero new correctness risk** (same queries, same session, same serial issuance,
   provably order-independent outcome application) — so unlike every hypothesis below it, it does
   not need to wait on any empirical safety spike. Ship it first; measure its own standalone
   before/after on `Project Iris`; only then decide whether hypothesis 1 is still worth pursuing (guided by
   the `source.request.statistics` `num-ast-builds` vs. distinct-file-count instrument from §2.5 —
   if builds already track distinct files, hypothesis 1's expected payoff shrinks a lot).
1. **(Conditional on hypothesis 0's measured result, no longer assumed to be the primary lever)
   Concurrent oracle query issuance, IF sourcekitd's real
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
   report that honestly rather than forcing a rewrite that doesn't help. **Binding requirement,
   confirmed real (§2.5), for any concurrent variant of this experiment or design:** the request
   builder must explicitly set `key.cancel_on_subsequent_request: 0`. The confirmed real default
   (`1`) makes a new cursor-info request implicitly cancel a still-in-flight previous one sharing
   the same session-wide cancellation token — under concurrent issuance this fires constantly,
   silently turning resolved results into cancelled/`unknown` ones while making the run *look*
   faster, which is exactly the kind of silent correctness regression this task's hard gate forbids.
   Under today's sequential issuance this flag is a behavioral no-op and safe/cheap to add anyway.
2. **A necessary corollary of hypothesis 1, not a separate hypothesis, and only in a subprocess
   shape** — a single sourcekitd session is confirmed process-global
   (`sourcekitd_initialize`/`getGlobalContext()`; dlopen'ing the same dylib twice from one process
   just returns the same loaded image and shares its globals, a general dynamic-loader fact). So if
   hypothesis 1's spike shows genuine cross-file AST-build parallelism is worth pursuing, the only
   way to get a second, truly independent `ASTBuildQueue` is a second **process** — a small pool of
   worker subprocesses (this project's own CLI binary in a hidden mode, dlopen'ing
   `sourcekitdInProc` exactly as today, each running today's *unchanged* serial `SourceKitDClient`
   actor over its own contiguous, file-grouped chunk of the ordered work list from hypothesis 0,
   writing results the parent merges deterministically by canonical key) — never an in-process
   session/actor pool, which cannot achieve real parallelism no matter how it's built. This is a
   bigger design/ops surface (K× resident memory, one more process-lifecycle concern, careful
   never-split-one-file's-queries-across-workers chunking to not destroy hypothesis 0's own
   locality win) than the original in-process pool idea implied, and should only be built if
   hypothesis 0's measured result still leaves the oracle phase dominant *and*
   `source.request.statistics` shows the residual cost is AST-build-bound, not just non-AST
   per-query overhead on already-warm ASTs (in that latter case, single-session concurrent issuance
   per hypothesis 1 — not a subprocess pool — would be the cheaper thing to try).
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
   glossed over just because the win is real. **Two corrections adopted from the reviewed
   response**: (a) the cache key must **not** be `Podfile.lock` (under-invalidates — the same lock
   file can correspond to different actually-resolved module artifacts) but a content hash of the
   module artifact itself, combined with SDK `ProductBuildVersion` and toolchain version; (b) the
   cache must store **only definitive outcomes** — a timeout- or crash-derived `unknown` must never
   be persisted, or one transient failure rots into a permanently-wrong cached answer on every
   future run. The gate for this feature is its own cold-run-vs-warm-run byte-identical diff, plus a
   `--no-oracle-cache` escape hatch, when it's actually taken up as its own follow-up task.
4. **(Worth a measurement, not an assumed fix) Is `FrameworkModuleDiscovery`'s `.framework`-bundle-
   only detection missing any real dependencies?** CocoaPods without `use_frameworks!` (a static-
   library-only integration) would not produce a discoverable `.framework` bundle at all — worth
   checking, on a real project, whether any of the "3208 unknown" declaration-level results (or
   their edge-level equivalent) trace back to a Pod that was never discovered for this reason. If
   so, this is a coverage gap independent of concurrency, with its own, separate fix shape (likely
   parsing `SWIFT_INCLUDE_PATHS`/other build settings for statically-linked module names) — treat
   as its own follow-up, not bundled into this task's own Definition of Done unless the measurement
   shows it's actually contributing meaningfully to the residual live-query cost. **Correction
   adopted from the reviewed response**: this measurement is nearly free and should happen *before*
   any fix is attempted — the module of most live-queried/unknown USRs is recoverable straight from
   the mangled name (the `s:<len><module>` mangling rule, plus the `s:So`/`c:` membership-resolution
   rule already established in this project's own demangler-histogram tooling from earlier work);
   bucket the 3208 unknowns + residual live-hit USRs by module and diff against
   `FrameworkModuleDiscovery`'s actually-discovered module set. Note explicitly: unlike hypotheses
   0-3, a fix here would *change outcomes* (more resolved, fewer unknown) by design — it therefore
   cannot ship under this task's own "zero semantic change" gate and must live in its own follow-up
   task with its own separate before/after accounting, never bundled into this task's diff.

## 3.5. Hazards specific to the byte-identical correctness gate (from the reviewed response, adopted)

1. **Implicit cancellation** (hypothesis 1's binding requirement above) — mandatory
   `key.cancel_on_subsequent_request: 0` in any concurrent variant; harmless under sequential
   issuance.
2. **Wall-clock timeouts can flip outcomes nondeterministically under load.** A query that would
   finish in, say, 40s alone can exceed a fixed budget when several workers/threads load the
   machine at once; a `resolved → unknown` flip from a timeout is exactly the forbidden semantic
   change, and it may not reproduce reliably run-to-run. Mitigation for any concurrent design:
   during the correctness-gate A/B comparison, log every timeout and require **zero timeouts on
   both sides** for the comparison to count at all; never record a timeout as a definitive
   `unknown` (carry a distinct `timedOut` reason internally so a rerun retries it rather than
   silently accepting the weaker answer).
3. **Merge order must be canonical-key order, never completion/iteration order** — already implied
   by this task's own three-phase design (hypothesis 0 and 1 both), restated here because it's
   exactly where a hard-to-reproduce nondeterminism would hide (conformance updates touch shared
   declarations).
4. **Memory pressure can make more workers/threads slower, not faster.** The real, confirmed
   `sourcekit.swift.ASTCache` (§2.5) evicts by memory cost, not a fixed entry count, under pressure
   — an oversized worker/thread count can make each one thrash its own AST cache and net-lose to a
   smaller count. Any concurrency variant that ships should sweep its concurrency parameter with
   RSS logged, not assume "more is faster," and report the curve in the decision record.

## 4. Definition of done

1. **Hypothesis 0 (ordering) ships first, unconditionally** — the three-phase (collect distinct
   work → execute sequentially, sorted by (args-hash, file, offset) → deterministic merge)
   restructuring is implemented for both trigger loops, Phase I3's per-pair dedup guarantee
   preserved (already true by construction: phase 1 still collects the fully-deduplicated set
   single-threaded, exactly as today). This alone gets a full correctness-gate diff (item 3 below)
   and a real `Project Iris` before/after measurement, and does not wait on item 2.
2. **A diagnostic instrument run** (per §2.5's adopted "instrument first" step) captures
   `source.statistic.num-ast-builds` / `num-ast-cache-hits` before and after the oracle phase, once
   before hypothesis 0 ships and once after, against the real `Project Iris` corpus — reported honestly
   even if it shows ordering already made builds track distinct-file-count closely (meaning further
   concurrency work per hypothesis 1 has little left to gain).
3. The sourcekitd concurrency-safety question (hypothesis 1's crux) is answered empirically, with
   the real experiment's method and result written up plainly — "yes, safe and parallelizes
   across files," "yes safe but doesn't parallelize," or "no, unsafe" are all acceptable, valid
   outcomes; the task is not done by *assuming* an answer. Per the adopted execution order, this
   spike runs regardless of hypothesis 0's result (it answers a standing architecture question this
   task's DoD has always required), but whether its result is *acted on* with a real implementation
   is conditional on item 2's instrument showing AST-build-bound residual cost after ordering ships.
4. If concurrency (hypothesis 1, or the subprocess pool of hypothesis 2) is adopted: the same
   three-phase shape from item 1 is extended, not replaced, with concurrent execution in phase 2
   under the §3.5 hazard mitigations (mandatory cancellation flag, zero-timeout gate requirement,
   canonical merge order, swept concurrency parameter with RSS logged) — plus a dedicated test: two
   declarations sharing one still-unresolved pair, run concurrently, assert the live query fires
   exactly once (mirroring this session's own existing
   `declarationLevelTriggerDedupesPerMemberConformanceCopies` test, extended for the concurrent
   path).
5. **The hard correctness gate**: running the *exact same real project* through both the old
   (sequential, pre-this-task) and new code paths produces byte-identical
   `backfilledDeclarations`/`updatedDeclarations`/`unknownUSRs` — a diff, not an eye-ball check, run
   separately for hypothesis 0 alone and again for whatever (if anything) ships from hypotheses 1/2.
   If a future non-determinism is discovered (e.g., a race that occasionally resolves a collision
   differently), that is a blocking correctness bug in this task's own work, not an acceptable
   "usually fine" tradeoff.
6. A real, honest, measured before/after wall-clock number on `Project Iris` for each shipped phase
   separately (ordering alone; then, if applicable, concurrency on top), the same way every other
   change this session has been measured (not extrapolated from a partial or diagnostic run).
7. Full `swift test -c release` green throughout.
8. A decision record appended to `docs/priority-3-compiled-dependency-isolation.md`, matching this
   project's established convention, explicit about which hypotheses actually shipped and why,
   including an honest report if the concurrency experiment came back negative or wasn't acted on
   because ordering alone already closed most of the gap — and including, verbatim, the §2.5
   binary-string-verified facts (the serial `ASTBuildQueue`, the `cancel_on_subsequent_request`
   default, and the `source.statistic.*` UIDs) as permanent, citable constraints on this codebase's
   relationship with sourcekitd, regardless of which hypotheses ship.

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

## 7. Decision record: hypothesis 0 shipped, three real bugs it exposed, and the language-mode contract

Hypothesis 0 (file-sorted, single merged execution pass across both trigger kinds) shipped. Getting
it to a state that passes the hard correctness gate against real `Project Iris` took four real, non-
hypothetical problems, each found by the gate itself and each requiring its own empirical
arbitration (a real `swiftc` compile, never reasoning alone) to resolve — not a smooth, one-shot
implementation. Recorded here in full because the investigation's own false starts are as
instructive as its conclusions (see also the retrospective note planned for `docs/`).

### 7.1 Conformance-pair claim representative: `declaredInSameContextAsWitness`, not "type vs. member"

The file-sorted merge made claim-once dedup for conformance pairs (`ConformancePairKey`) pick a
*consistent* representative declaration to query, where the old, unordered-`Dictionary`-iteration
code picked one at random per run. Two real, opposite-shape regressions on `Project Iris` proved neither
"the type's own entry always wins" nor "a member always wins" is correct:

- **`PhotoServiceImpl`** (project source): conforms to `PHPickerViewControllerDelegate` via a
  *separate*, same-file `extension`. Hovering the type's own primary-declaration line does not
  reliably reflect a conformance added later via a different `extension` block (confirmed via real
  `swiftc -swift-version 6`: the compiler's own diagnostic explicitly named the conformance as the
  inference source for `@MainActor`, but a hover at the primary line alone returned `nonisolated`).
  A member declared *inside* that extension resolves correctly.
- **`KFImageRenderer`** (Kingfisher pod): conforms to `View` directly on the primary type. A member
  (`binder`, `@StateObject`) resolves *incorrectly* here — not because member-location hovering is
  wrong in general, but because of a separate parser bug (§7.2).

**Fix**: the representative for a `(nominal, protocol)` pair is the declaration whose own copy of
that conformance has `ProtocolConformance.declaredInSameContextAsWitness == true` — a real member
physically declared inside the same syntactic construct (primary body or a specific `extension`)
that introduces the conformance; already computed by `SyntaxAnalysis.DeclarationExtractor`, not a
new signal. A declaration lacking that signal for a pair (the type's own entry, or a member from a
different context) defers to a fallback pass that only claims a pair if no witness-context
declaration ever does — this correctly resolves both shapes above, and is the documented, known
limitation for an empty marker extension (`extension Foo: P {}`, no members): no witness-context
declaration exists by construction, so the fallback (a member/type entry with no locality guarantee)
is the best available answer, not a bug to chase further.

(Bookkeeping note: `KFImageRenderer`'s family is reported as 8 nodes in the final gate's per-node
diff (§7.6) but was tracked as "7 regressed nodes" earlier in this investigation — no discrepancy
in the data. The 8th node, a synthesized `init(binder:context:)`, is `nonisolated` in both baseline
and every intermediate state and never regressed; 7 was always the count of nodes that *changed*
at the time of that specific regression, 8 is the full family size.)

### 7.2 Parser bug: any resolvable attribute was accepted as a global-actor name

Once `KFImageRenderer`'s `binder` became a genuine claim candidate (§7.1), it exposed a real, latent
bug in both isolation parsers (`SymbolGraphIsolationParser`, `FullyAnnotatedDeclParser`): a `@Foo`
attribute fragment/XML element was accepted as naming a global actor merely because `Foo` resolved
to a real type via USR — true of `@MainActor`, but equally true of `@StateObject` (a SwiftUI
property wrapper, never an actor). Hovering `binder`'s own declaration returned
`globalActor(name: "StateObject")`, a fabricated fact. **Fix**: `GlobalActorNameValidation` adds a
positive check before accepting an attribute as a global actor — `MainActor`'s own USR (`s:ScM`) is
a fast path; a small, documented denylist of known SwiftUI/Combine/Observation property wrappers
(`State`, `StateObject`, `Published`, `ObservedObject`, `Binding`, `EnvironmentObject`,
`Environment`, `AppStorage`, `SceneStorage`, `FocusState`, `GestureState`, `Namespace`,
`ScaledMetric`, `Bindable`, `Observable`) covers the rest. This is a deliberately narrow, named-list
fix, not a live `@globalActor`-attribute verification against the referenced type's own declaration
(which would need a second live query per candidate) — a real custom global actor sharing one of
these names would be a false negative (`.nonisolated`, an undercount), not the fabricated-isolation
failure mode this closes; no such collision is known in this project's real corpus.

### 7.3 Edge-level query-order non-determinism: a real, confirmed instability, not a hypothesis

Independently of §7.1/§7.2, three back-to-back runs of the *identical* binary against the identical
`Project Iris` corpus produced three different resolved/`unspecified` combinations for a small family of
synthesized (implicit, no explicit `init` in source) `.init()` declarations
(`MindboxSDKInitializer`, `YandexPaySDKInitializer`, `ProductNotificationSchedulerInitializer`,
`URLNormalizer`, `SupportedLinksValidator`). Traced to the **edge-level trigger**
(`collectEdgeLevelWorkItems`), a code path entirely independent of §7.1's conformance-pair logic:
these synthesized inits have no `DeclarationInfo` at all (nothing in source to extract), so they're
referenced only via call-graph edges, and the pre-fix dedup picked whichever edge's location was
*first-encountered in `linked.callGraph`'s own iteration order* — an order this project's own
`IndexStoreDB`-backed pipeline does not guarantee stable across runs. **Fix**: the canonical
representative for a shared `calleeUSR` is now the lexicographically-smallest `(file, line, column)`
among every edge referencing it, computed independently of iteration order
(`collectEdgeLevelWorkItems`) — the plan is a pure function of the *set* of edges, never of visiting
order. Verified with a dedicated unit test (an edge with a *later* location placed first in the
input array must not win).

**A second, narrower non-determinism was found by the same discipline (a cheap, no-live-query
plan-dump diff — see §7.5) before it ever reached a real gate run**: two genuinely distinct USRs can
legitimately share one exact `(file, line, column)` on real code (e.g. a synthesized property
getter and its setter counterpart at the same call-site token, confirmed on `Project Iris`). Sorting only
by location left such ties' relative order dependent on `merged`'s own pre-sort array order, which
itself traces back to `Dictionary` iteration (both `bestLocationByUSR` and `linked.declarations`) —
not guaranteed stable across process launches. **Fix**: `targetUSR`/`usr` added as the final
tie-breaker in both sorts (`resolve()`'s merged sort; `collectDeclarationLevelWorkItems`'s
`orderedDeclarations`), making the merged plan a pure function of file-sort with no
order-dependent step left anywhere in it.

### 7.4 The language-mode contract, and the near-miss it prevents

Arbitrating §7.3's resolved answers against real `swiftc` initially (wrongly) concluded the oracle
was fabricating an answer for `MindboxSDKInitializer.init()` (`globalActor(MainActor)`, matching its
`@MainActor`-attributed class) — a real `swiftc -typecheck -swift-version 6` run against the whole
real module + a probe file calling all five constructors from a synchronous nonisolated context
raised **no diagnostic** for any of them, seemingly confirming all five should be `nonisolated`
(SE-0411: a class's synthesized zero-argument `init()` is only isolated to its type's global actor
if some stored property's default value actually requires that isolation to evaluate; none of these
five classes have any stored properties at all). **This conclusion was wrong, caught only because it
was checked against an independent arbiter twice, at two language modes, not once.** The real
project's own build genuinely compiles this module at `-swift-version 5`, not 6 — re-running the
identical probe at `-swift-version 5` (the real, extracted build arguments, action changed from `-c`
to `-typecheck` only) produced a real, hard **error** for `MindboxSDKInitializer()` specifically:
`call to main actor-isolated initializer 'init()' in a synchronous nonisolated context`. The other
four constructors stayed clean under both versions. **SE-0411's synthesized-init exemption is itself
gated to Swift 6 language mode** — under 5, the class's `@MainActor` attribute propagates to its
synthesized init unconditionally, exactly as the oracle (which queries `sourcekitd` with the real
build's real, `-swift-version 5` compiler arguments) had reported all along. The oracle was never
wrong; the first arbitration attempt was, because it checked the answer against the wrong language
mode's semantics.

**Decision, made explicitly (2026-07-29) rather than left implicit: this tool computes isolation as
each module actually compiles today** — real per-module `-swift-version` from real build arguments,
never a hardcoded or assumed mode (see the README's own "Language-mode contract" section, added as
part of this decision). It does not predict what a future migration to a newer language mode would
report. A companion methodology rule follows directly and is binding for every future arbitration
in this codebase: **an arbiter compile must run at the same language mode the oracle's own query
used, or its verdict is not comparable.** Checking only one mode when the two differ is not a
shortcut — it is exactly the failure this section describes narrowly avoiding.

A second spot-check, run for the same reason (confirm no language-mode divergence was missed
elsewhere), compiled `PhotoServiceImpl`'s `PHPickerViewControllerDelegate`-witnessing call
(`picker(_:didFinishPicking:)`, §7.1) at both language modes: `-swift-version 6` raises the expected
`ActorIsolatedCall` warning; `-swift-version 5` raises none for that specific call, while *other*
real files in the same corpus (`AuthenticationService`, `YandexWidgetManager`) do surface a related
but distinct diagnostic (`ConformanceIsolation`, explicitly labeled "this is an error in the Swift 6
language mode") under 5. This shows actor-isolation checking is genuinely active under `-swift-version
5` in this build, just at a different enforcement granularity per diagnostic category than 6 — it
does **not**, by itself, show the underlying isolation *fact* `sourcekitd`'s hover would report for
`picker(_:didFinishPicking:)` differs between modes (a diagnostic's absence is not the same claim as
a hover-reported fact's absence, unlike §7.3's item, which was a hard compile error). Treated as an
open, secondary observation, not a second confirmed divergence: the original 4b verdict (baseline
`globalActor(MainActor)` was correct) stands, independently confirmed via a real Sendable-violation
compile against the real PhotosUI/UIKit SDK during the original investigation. If a future,
targeted `sourcekitd`-hover-level (not `swiftc`-diagnostic-level) check is ever done for this
specific declaration under `-swift-version 5`, record the result here.

### 7.5 Net result

- `Sources/swift-isolation-map/ExternalIsolationBackfill.swift`: canonical edge-level representative
  (§7.3) + `declaredInSameContextAsWitness`-based conformance-pair claim (§7.1). All temporary
  diagnostic instrumentation added during this investigation (`SING-TRACE`/`PSI-TRACE`/`MBP-TRACE`,
  side-channel probe queries) has been removed. Two instruments are kept **permanently**, both
  re-worded to drop the original "reverted after use" framing since neither is staying temporary:
  `SWIFT_ISOLATION_MAP_DUMP_MERGED_PLAN` (prints `(targetUSR, location)` for the whole merged plan
  and exits before any live query — the cheap tool that actually caught the tie-breaker bug in
  §7.3's addendum, before it ever reached a real gate run) and the "distinct live-query file
  groups" count inside `SWIFT_ISOLATION_MAP_ORACLE_STATS` (§7.6's own acceptance denominator).
- `Sources/SourceKitDIntegration/{SymbolGraphIsolationParser,FullyAnnotatedDeclParser}.swift` +
  new `GlobalActorNameValidation.swift`: positive validation (§7.2).
- `swift test -c release`: 243/243 green, including new regression tests for all three fixes
  (witness-context claim priority in both primary-body and extension shapes, the no-witness
  fallback, the canonical edge-representative, and both parsers' property-wrapper/custom-actor
  cases).
- **Real `Project Iris` full-corpus gate: closed.** Per-node diff against baseline
  (`oracle-stats-diagnostic-run.json`, `8cdb474`): 64 node differences, every one attributed —
  57 `MBPersistenceStorage` (problem 4a, baseline bug, already closed), 6 synthesized-`.init()`
  singleton improvements (`unspecified → resolved`, matching real `swiftc` arbitration at the
  oracle's own real language mode — `MindboxSDKInitializer`, `YandexPaySDKInitializer`,
  `ProductNotificationSchedulerInitializer`, `URLNormalizer`, `SupportedLinksValidator`, plus a
  sixth not seen in earlier, narrower diffs, `MainPage2Api`, now resolved thanks to the edge-level
  determinism fix), and 1 unrelated artifact (a stray index-store record from this investigation's
  own `/tmp` arbitration probe files, sharing the real project's `-index-store-path` — harmless,
  will clear on the next real Xcode rebuild, left as-is by explicit user decision). Zero
  unexplained residual. **`KFImageRenderer` (8 nodes) and `PhotoServiceImpl` (12 nodes) both fully
  match baseline** — the two opposite-shape regressions §7.1 exists to fix are both closed by the
  one `declaredInSameContextAsWitness` rule, confirmed on the real corpus, not just in unit tests.
  Same-binary determinism re-run (two full real runs, live queries included, not just the
  plan-dump): **0 node diffs**, identical summary counters — the edge-level non-determinism (§7.3)
  is fixed on the real pipeline, not only at the planning level.

### 7.6 Hypothesis 0 acceptance numbers (DoD items 2 and 6)

Measured on a **release** build (matching the original baseline measurement's own methodology),
real full `Project Iris` run, `SWIFT_ISOLATION_MAP_ORACLE_STATS=1` before/after snapshots plus manual
wall-clock:

| Metric | Before hypothesis 0 (§2.7) | After hypothesis 0 |
|---|---|---|
| Wall-clock | 29:41 (1781s, 86% cpu) | **20:00 (1200s)** — **≈33% faster** |
| `num-requests` | 4825 | 4794 |
| `num-ast-builds` | **4780** (~99% of requests) | **1764** |
| `num-ast-cache-hits` | 44 | **3029** |
| `max-asts-in-memory` | 8 | 8 |

`num-requests` shifted slightly (4825 → 4794) — expected, not noise: the canonical edge-level
representative and witness-context claim fixes (§7.1, §7.3) change *which* declaration/location
represents a shared work item, and bulk-cache coverage of the corpus can differ trivially run to
run — the set of distinct *targets* resolved is what should (and does, per the closed gate above)
stay the same, not the literal request count issued to reach them.

**The decisive acceptance signal, pre-registered before this fix (§2.5, §3 item 0):**
`num-ast-builds` should track the number of *distinct files* actually reaching `sourcekitd` (the
merged plan's own "distinct live-query file groups" count, computed independently of the
statistics instrument, from a separate zero-live-query plan-dump run), not the number of queries.
That denominator: **1595**. `1764 / 1595 ≈ 1.11` — builds now sit within ~11% of the theoretical
minimum, a complete reversal from the pre-fix ~99% (builds tracking requests almost 1:1). The small
residual is explained, not unexplained: `max-asts-in-memory: 8` still bounds how many files can
stay resident under eviction pressure switching between large Pod modules, and
`resolveSyntacticPlaceholderNeeds` is a deliberately sequential, unreordered pass that runs *after*
the main merged pass (§ `resolve`'s own doc comment) and can revisit a file outside the main pass's
file-sorted locality — a documented, accepted limitation, not a bug.

Cross-check confirming the before/after snapshots themselves are sound (no requests leaking past
accounting): `num-ast-builds + num-ast-cache-hits = 1764 + 3029 = 4793 ≈ num-requests (4794)`.

Release vs. an equivalent debug build: 0 node diffs, identical summary — the optimizer does not
change behavior.

### 7.7 Hypothesis 1 closed: concurrent issuance rejected, on an architectural ceiling, not measurement

**Attribution first, because it matters for how much to trust this closure**: the decisive fact
below — `sourcekitd` serializes all real AST building through one process-wide serial queue,
regardless of client-side concurrency — was **not** discovered during this closure's own spike. It
was already established, from the same source citations, in
`docs/research/12-oracle-concurrency-research-response.md`, written *before* any spike code existed
(§1.1 there). This closure's own source-reading (independently, against the same
`swiftlang/swift` `SwiftASTManager.cpp`) reproduced that document's citations exactly — a second,
independent confirmation of an already-known fact, not a new finding. The research response's own
predictions (P1: modest, non-multiplicative single-session speedup; P3: ordering dominates
concurrency) are exactly what this closure measured.

A real, opt-in spike (`Tests/SourceKitDIntegrationTests/ConcurrentIssuanceSpike.swift`,
`SWIFT_ISOLATION_MAP_RUN_CONCURRENCY_SPIKE=1`) issued concurrent `cursorInfo` requests directly
against a raw `sourcekitd` session, bypassing `SourceKitDClient`'s actor:

- **Correctness**: 0 mismatches against a sequential baseline, across small-fixture and real
  cold-cache (`Project Iris`) runs. No crash, no hang.
- **Speed**: an early, small-fixture measurement showed 17-19x — later shown to be a cache-warmth
  confound (sequential and concurrent phases shared one un-cleared AST cache). A corrected,
  genuinely cold-cache measurement (two disjoint, never-before-queried real file/offset groups, one
  run purely sequentially, one purely concurrently) gave **~1.3-2x** across two independent runs —
  real, but capped, exactly matching the research response's own pre-registered P1.
- **Why not chase it further**: `sourcekitd`'s `ASTBuildQueue` (`SwiftASTManager.cpp:613-616`,
  `WorkQueue::Dequeuing::Serial`) guarantees only one AST builds at a time, process-wide, no matter
  how many concurrent requests a client issues. The ~1.3-2x observed is not parallel compilation
  (architecturally impossible inside `sourcekitd`) — it is some overlap of non-AST-build work
  (request marshaling, response serialization) with the one AST build still in flight. This ceiling
  cannot be raised by any client-side redesign (shared queue vs. file-sharded work distribution,
  worker count, etc.) — a synthetic dataset built specifically to test that question (`Phase E`,
  same test file) was written and verified compiling, then **not run**: the question it would
  answer no longer has a practical answer that changes the decision.
- **The real reason not to chase even the capped 1.3-2x**: concurrent issuance changes the actual
  order ASTs are built/evicted in, which is exactly the mechanism hypothesis 0's own byte-identical
  gate depends on (§7.1/§7.3 — this project's own recent, hard-won determinism). The price of a
  ≤2x win, on top of hypothesis 0's already-shipped 33%, is real risk to a gate this project just
  finished earning. Rejected on that basis, not because the measured gain was zero.

**`key.cancel_on_subsequent_request: 0` reverted from `SourceKitDClient.cursorInfo`.** It was
originally added unconditionally (§3.5, §7's own earlier framing) as a binding safeguard for
concurrent issuance. With concurrent issuance rejected, the only code path that still needs it is
the spike's own raw requests (`ConcurrentIssuanceSpike.swift`, which sets it directly) — in
`SourceKitDClient`'s actual, permanently-sequential issuance, the actor already guarantees no two
requests are ever in flight at once, so the flag is a strict no-op there by construction, not by
coincidence. Kept as a documented key definition in `SourceKitDKeys` for the spike's own use;
removed from `SourceKitDClient.cursorInfo` itself. `git diff` on that file is empty relative to
before this investigation began.

**Separately, found and fixed while gating this closure** (unrelated to the flag decision, a real,
independent bug in pre-existing code): `LiveXcodeCompilerArgumentsProvider`'s `runVerboseBuild`
threw on any non-zero `xcodebuild` exit code, even when the log still contained valid, parseable
compiler invocations for targets that compiled successfully — one unrelated broken target (a
notification extension with an unresolved dependency, in `Project Iris`) poisoned the in-memory
compiler-args cache forever, forcing every subsequent distinct file lookup to repeat the whole
build from scratch. Fixed: only a hard failure when nothing at all could be parsed from the log.
