# Research response: oracle query concurrency (`task-oracle-query-concurrency.md`)

Status: check-first research answer, written before any spike code. The task's crux question
(hypothesis 1's "does sourcekitd actually parallelize under concurrent client load?") turns out to
be answerable **from the SourceKit sources of the exact toolchain branch** before running the
experiment — the same way Gap B's `.baseOf` direction and the Attr.cpp carve-out were answered.
All citations below were read this session from `swiftlang/swift` at branch **`release/6.3`**
(matching the machine's Xcode 26.4 / Swift 6.3 toolchain), not recalled from memory. The
confirming micro-spike is still required by the task's own DoD 1 and should still run — but it can
now run with pre-registered, source-derived predictions instead of open-ended exploration, and two
of its failure modes are already known and avoidable.

**TL;DR, in one paragraph.** Concurrent request *issuance* against one sourcekitd session is safe
by design (requests are dispatched onto an explicitly concurrent intake queue), so the "no, unsafe"
outcome is unlikely — but it will barely help, because every AST build in a session funnels through
a single *serial* queue whose doc comment literally says its job is "guaranteeing that only one
ASTBuildOperation builds an AST at a time," and the AST build (the `performSema` typecheck that
dominates each query) executes *on* that queue. Worse: naive concurrent cursor-info issuance is
actively self-destructive, because cursor-info requests default to
`cancel_on_subsequent_request = 1` and share one session-wide cancellation token — concurrent
requests would cancel each other, silently flipping outcomes and violating the byte-identical gate.
Real parallelism therefore requires multiple *sessions*, and a session is process-global, so the
honest shape of hypothesis 2 is a small pool of worker *subprocesses*, not a pool of in-process
actors. But before building even that: the task's fact list is missing the cheapest lever of all —
**AST cache locality via query ordering** — and sourcekitd ships a free instrument
(`source.request.statistics`, exposing `numASTBuilds` / `numASTCacheHits`) that can tell us in one
diagnostic run whether ordering, not concurrency, is the actual dominant fix. The three-phase
restructure the task already plans for concurrency is exactly what ordered sequential execution
needs too, so that restructure pays for itself even if every concurrency variant is rejected.

---

## 1. The crux, answered from `release/6.3` sources

### 1.1 One serial AST-build queue per session — cross-file typechecking does not parallelize

`tools/SourceKit/lib/SwiftLang/SwiftASTManager.cpp`, inside
`SwiftASTManager::Implementation` (i.e. one instance per `SwiftASTManager`, and
`SwiftLangSupport` owns exactly one `SwiftASTManager` per session):

```cpp
/// Queue guaranteeing that only one \c ASTBuildOperation builds an AST at a
/// time.
WorkQueue ASTBuildQueue{ WorkQueue::Dequeuing::Serial,
                         "sourcekit.swift.ASTBuilding" };   // lines 613-616
```

Every new build operation, regardless of which file it is for, is scheduled onto that one queue
(`NewBuildOp->schedule(Mgr->Impl.ASTBuildQueue);`, line 1421), and — decisive detail —
`ASTBuildOperation::schedule` (line 1230) runs `buildASTUnit(Error)` *inside* the lambda
dispatched onto the queue it is given. The typecheck itself, not just its scheduling, is
serialized. There is no per-file or per-compilation-context build queue; the "one queue per
compilation context" architecture the task listed as plausible is **falsified at the source
level** for this toolchain. (There *is* a per-producer `BuildOperationsQueue`, line 475, but it
only serializes bookkeeping of build operations for one invocation — builds still all execute on
the shared `ASTBuildQueue`.)

This also retroactively explains the observed `sample` profile exactly: the
`DispatchQueue_76: sourcekit.swift.ASTBuilding (serial)` thread was not an artifact of our own
single-threaded issuance — it is the only place AST builds can ever run in a session.

**Consequence for hypothesis 1:** on a single session, concurrent issuance can overlap only the
non-AST parts of a query (request parsing, cursor resolution against an already-built AST, symbol
graph generation for the result, response serialization). When the AST for the target file is
already cached, those parts are the whole query and some overlap is real; when it is not, the
build dominates and serializes. Given the current cost profile (queries are slow precisely when
they pay a typecheck), the expected single-session speedup is small — see prediction P1.

### 1.2 Concurrent issuance is safe by design — the actor's caveat can be answered, not just relaxed

`tools/SourceKit/tools/sourcekitd/lib/Service/Requests.cpp`:

```cpp
static WorkQueue SemaQueue{WorkQueue::Dequeuing::Concurrent,
                           "sourcekit.request.semantic"};     // line 637
SemaQueue.dispatch([Fn] { Fn(); }, /*isStackDeep=*/true);
```

Semantic requests (cursor-info included) are dispatched onto an explicitly **concurrent** intake
queue. Concurrent in-flight requests are an architectural assumption of sourcekitd itself —
sourcekit-lsp exercises this in production daily. So `SourceKitDClient`'s documented caveat
("concurrency safety has not been independently verified") can now be answered with a source
citation plus the micro-spike, rather than remaining an assumption in either direction. The
"unsafe / crashes" outcome of the experiment is unlikely; if it occurs, it is a finding worth
reporting upstream, not an expected result.

### 1.3 The trap that would silently break the byte-identical gate: implicit cancellation

Same `Requests.cpp`, cursor-info request handling:

```cpp
// For backwards compatibility, the default is 1.
int64_t CancelOnSubsequentRequest = 1;
Req.getInt64(KeyCancelOnSubsequentRequest, CancelOnSubsequentRequest,
             /*isOptional=*/true);                            // lines 1629-1632
```

and `tools/SourceKit/lib/SwiftLang/SwiftSourceDocInfo.cpp`, in the cursor-info path (the same
pattern repeats across the cursor-family requests):

```cpp
/// FIXME: When request cancellation is implemented and Xcode adopts it,
/// don't use 'OncePerASTToken'.
static const char OncePerASTToken = 0;
const void *Once = CancelOnSubsequentRequest ? &OncePerASTToken : nullptr;
Lang.getASTManager()->processASTAsync(Invok, std::move(Consumer), Once, ...);
```

The token is a **function-local static** — one address shared by *every* cursor-info request in
the session. With the default `cancel_on_subsequent_request = 1`, scheduling a new cursor-info
request implicitly cancels a still-in-flight previous one. Our current strictly sequential
`await`-one-at-a-time loops never trip this (the previous request has always completed), which is
why it has been invisible. Under concurrent issuance it fires constantly: requests would come back
cancelled, be recorded as failures/`unknown`, and the run would even *look* faster — a silent
correctness failure of exactly the kind the task's hard constraint forbids.

**Binding requirement for any concurrent design (and cheap hygiene even for the sequential one):**
the request builder must set `key.cancel_on_subsequent_request: 0` explicitly, with a comment
citing this mechanism. Under sequential issuance it is a behavioral no-op, so adding it does not
touch the correctness gate.

### 1.4 A free instrument: `source.request.statistics` and `DidReuseAST`

Two measurement hooks exist that the task's plan doesn't yet use:

- `source.request.statistics` (`handleRequestStatistics`, Requests.cpp line 1281, registered as
  `RequestStatistics`) returns, among others, `numASTBuilds`, `numASTCacheHits`, and
  `numASTsUsedWithSnapshots` (incremented in SwiftASTManager.cpp lines 1115 / 1331 / 1349). Issue
  it once before and once after the oracle phase and subtract: this yields, for free, the single
  most diagnostic ratio of this whole task — **AST builds per live query**.
- Cursor-info results carry a `DidReuseAST` flag (`Data.DidReuseAST`, SwiftSourceDocInfo.cpp,
  `deliverCursorInfoResults`), giving the same signal per-query if we want to log it.

If AST builds ≈ number of *distinct files touched*, cache locality is already fine and ordering
(§2) will not help — skip it. If AST builds trend toward the number of *queries*, ordering is the
dominant fix and likely cheaper and larger than any concurrency work. One diagnostic run decides.

### 1.5 Why an in-process session pool is off the table

A sourcekitd session is process-global: `sourcekitd_initialize` / `getGlobalContext()` (see
Requests.cpp's use of `getGlobalContext()` throughout) manage one global context, and
`sourcekitdInProc` dlopen'd twice resolves to the same image with the same globals. The only way
to get a second genuinely independent `ASTBuildQueue` is a second *process*. (The tempting hack —
copy the dylib to two paths and dlopen both — would double-register the Swift and Objective-C
runtimes in one process; undefined behavior, and disqualified outright by this project's "an
incorrect result is worse than no tool" principle.) So hypothesis 2's honest shape is a **worker
subprocess pool**, §3 — and it has a major side benefit: each worker keeps today's serial
`SourceKitDClient` actor *unchanged*, so the design introduces **zero new thread-safety
assumptions** instead of relaxing a documented one.

---

## 2. The unlisted lever 0: AST cache locality via query ordering (sequential, zero risk)

Cost model, from the same sources: a cursor-info query is cheap iff the AST for its
`(file, compiler args)` invocation is in `ASTCache` (SwiftASTManager.cpp line 585). That cache is
backed by `swift/Basic/Cache.h` — on Darwin, libcache with *memory-cost-based* eviction
(`CacheValueCostInfo<ASTProducer>` keys eviction to the AST's memory footprint), not a fixed entry
count. With 2209 files and queries issued in call-graph/declaration-table order, nothing
guarantees that consecutive queries share a file; every file switch risks a full typecheck, and
under memory pressure previously built ASTs are evicted and rebuilt.

The fix is precisely the restructure the task already plans for concurrency, minus the
concurrency: **collect the complete deduplicated work-item set first (single-threaded, exactly as
the task specifies to preserve Phase I3's per-pair guarantee), then execute sequentially but
sorted by `(file, offset)`, then apply outcomes in canonical deterministic order.** Same file's
queries become adjacent; each file's typecheck is paid at most once per pass instead of
potentially many times. Semantics are untouched by construction — same queries, same session, same
serial issuance, different order — and outcome application is order-independent once the merge
phase sorts by canonical key (mirroring `BulkSymbolGraphExtractor.extractAll`'s established
slot-merge precedent, as the task already mandates).

This means the three-phase restructure is worth implementing *first and unconditionally*: it is
required infrastructure for every hypothesis on the table, and with ordering alone it may deliver
most of the win with none of the risk. Measure it standalone before adding any concurrency, so the
decision record can attribute the speedup honestly.

Two auxiliary notes:

- **Sort by args too.** Files from different targets have different compiler args → different
  `ASTKey`s. Group by (args-hash, file, offset) so a target's files cluster.
- **Interaction with G4 timeouts:** with ordering, the first query per file is predictably the
  slow one (cold AST) and the rest are fast. Any per-query wall-clock timeout should account for
  that shape rather than a uniform budget — see §4's timeout hazard.

---

## 3. If more speed is still needed after lever 0: worker subprocess pool (revised hypothesis 2)

Design sketch, deliberately mirroring existing precedent:

1. Parent runs phases 1 and 3 (collect+dedup, deterministic merge) exactly as in §2. Phase 2
   partitions the work-item list **at file-group granularity** — never split one file's queries
   across workers, or the pool multiplies AST builds and destroys the locality §2 just bought —
   into K contiguous chunks balanced by estimated cost (query count per file is a fine first
   proxy).
2. Each worker is our own CLI binary in a hidden mode (e.g. `swift-isolation-map _oracle-worker
   --work-list items.json --out results.json`), dlopen'ing `sourcekitdInProc` exactly as today,
   running the *unchanged* serial `SourceKitDClient` actor, executing its chunk sorted as in §2,
   writing structured results (including per-item `unknown`-with-reason). Workers inherit the G4
   subprocess-timeout discipline the codebase already has; the parent supervises with the existing
   machinery.
3. Parent merges K result files by canonical work-item key — deterministic regardless of worker
   completion order — then applies outcomes in the fixed order of phase 3.

Properties: true cross-file parallelism (K independent `ASTBuildQueue`s); no change to the
documented actor decision; failure isolation (a worker crash loses one chunk, retryable
sequentially in-parent as a fallback rather than flipping outcomes to `unknown` — a crashed
worker's items must be re-executed, never recorded as `unknown`, or the gate breaks); testable
with a fixture work-list without any real project. Costs: K× resident memory (sourcekitd + AST
cache per worker — measure RSS and start at K=2..4, sweep, don't assume), serialization overhead
(negligible at ~7k items), and one more process-lifecycle surface.

Decision rule: build this only if §2's measured result still leaves the oracle phase as the
dominant wall-clock cost and the remaining cost is AST-build-bound (statistics will say so). If
post-ordering cost is dominated by per-query non-AST work on warm ASTs, single-session concurrent
issuance with `cancel_on_subsequent_request: 0` (§1.3) becomes the cheaper thing to try — that is
the one configuration where hypothesis 1 as originally written could still pay.

---

## 4. Hazards specific to the byte-identical correctness gate

1. **Implicit cancellation** (§1.3) — mandatory `key.cancel_on_subsequent_request: 0` in any
   concurrent variant.
2. **Wall-clock timeouts flip outcomes nondeterministically.** A query finishing in 40s alone can
   exceed a 60s budget when K workers load the machine; `resolved → unknown` flips are exactly the
   forbidden semantic change, and a single A/B diff run may not surface them reliably. Mitigation:
   during the gate's A/B comparison, log every timeout and require **zero on both sides** for the
   comparison to count; in production paths, prefer generous per-*chunk* budgets over tight
   per-query ones, and never cache or record a timeout as a definitive `unknown` (carry a distinct
   `timedOut` reason so reruns retry it).
3. **Merge order.** Outcome application must be sorted by canonical key, never
   completion/iteration order — the task already mandates this; restating because conformance
   updates touch shared declarations and are where a nondeterminism would hide.
4. **Memory pressure.** libcache evicts by cost under pressure (§2); an oversized K can make every
   worker thrash its AST cache and *lose* to K=2. Sweep K with RSS logged; report the curve in the
   decision record.

---

## 5. Hypotheses 3 and 4 (endorsed as scoped, with two corrections)

**Persistent cross-run cache (hyp. 3):** endorse as a separate follow-up; for the iterative-dev
loop it is the largest win available and is untouched by everything above. Keying should reuse the
already-designed option-D scheme (7th doc, `performance-research-response.md`): content hash of
the module artifact ⊕ SDK ProductBuildVersion ⊕ toolchain version — Podfile.lock under-invalidates
and must not be the key. Two accuracy-critical rules: (a) cache only *definitive* outcomes — a
timeout- or crash-`unknown` must never be persisted, or a transient failure rots into a permanent
wrong answer; (b) the gate diff for this feature is cold-run vs warm-run on the same tree,
byte-identical, plus a `--no-oracle-cache` escape hatch alongside the existing manifest
conventions.

**Coverage measurement (hyp. 4):** do the measurement before any fix, and it costs almost
nothing: the module of most live-queried/`unknown` USRs is recoverable from the mangling
(`s:<len><module>` rule, plus the `s:So`/`c:` membership-resolution rule, both already established
in the 7th doc and its demangler histogram tooling). Bucket the 3208 unknowns + residual live-hit
USRs by module, diff against `FrameworkModuleDiscovery`'s discovered set; any bucket belonging to
an undiscovered module (static-lib Pods without `use_frameworks!` being the predicted culprit,
discoverable instead via `SWIFT_INCLUDE_PATHS` / `HEADER_SEARCH_PATHS` / `-fmodule-map-file`) is
quantified evidence for the separate follow-up the task already scopes. Note this fix would
*change outcomes* (more resolved, fewer unknown) — by design, and per the task's own text it
therefore lives outside this task's gate, in its own follow-up with its own before/after.

---

## 6. Pre-registered predictions for the confirming micro-spike

Spike harness: extend the fourth-addendum dlopen harness (it already does multi-query in-process;
keep the index `-1` array rule). Matrix: {1, 2, 4, 8} concurrent issuing threads × {same file
different offsets, N different files} × {cancel flag default, cancel flag 0}, byte-diff of result
sets vs a sequential run of the same items, plus one `sample` capture under load.

- **P1 (crux):** with `cancel_on_subsequent_request: 0`, concurrent issuance on one session is
  crash-free and byte-identical, but wall-clock speedup on cold-AST different-file queries is
  ≤ ~10–15% (non-AST overlap only); `sample` shows exactly one `sourcekit.swift.ASTBuilding`
  thread ever building. On warm ASTs (second pass over the same items) speedup is real and larger.
- **P2 (cancellation):** with the default flag, the concurrent runs return cancelled/failed
  results for a large fraction of in-flight requests — the silent-gate-violation mechanism of
  §1.3 demonstrated, justifying the mandatory flag.
- **P3 (ordering):** on the real `Project Iris` corpus, `source.request.statistics` shows current
  `numASTBuilds` per oracle phase substantially exceeding the number of distinct trigger files;
  file-sorted sequential execution alone cuts oracle wall-clock by an integer factor. (Falsifiable
  cheaply: if the statistics show builds ≈ distinct files already, drop §2's expectation and lean
  on §3.)
- **P4 (end state):** ordering + K=4 worker pool brings the 29:41 run into low single-digit
  minutes with a clean gate diff; if only ordering ships, the run still lands well under half the
  baseline.

## 7. Proposed execution order

0. **Instrument first** (trivial, no behavior change): statistics request before/after oracle
   phase + per-query file/duration/DidReuseAST logging → one diagnostic `Project Iris` run. Decides §2
   vs §3 weighting with data.
1. **Three-phase restructure with file-sorted sequential execution** (+ the I3 pair-dedup test
   extended to the restructured shape) → gate diff → measured `Project Iris` number. Possibly done here.
2. **Micro-spike** per §6 → answers DoD 1 with source citations + experiment, honestly, whichever
   way it lands.
3. **Worker pool** per §3 only if step 1's number still isn't acceptable and statistics show
   AST-build-bound residual cost → K sweep → gate diff (zero-timeout rule) → measured number.
4. Separate follow-ups, own gates: persistent cache (hyp. 3), module-coverage measurement→fix
   (hyp. 4).

Decision record: whichever subset ships, `docs/priority-3-compiled-dependency-isolation.md` gets
the source citations of §1 verbatim — the serial `ASTBuildQueue` fact and the
`cancel_on_subsequent_request` default are permanent constraints on this codebase's relationship
with sourcekitd and belong in the record even if every concurrency variant is rejected.
