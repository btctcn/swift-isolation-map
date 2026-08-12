# Investigation: intermittent `sourcekitd` live-fallback failures on Swiftfin

**Status: SOLVED. Real root cause found in §8, fix implemented and verified clean across 12
repeated real Swiftfin runs — zero catastrophic failures (was previously ~12-30% per run,
depending on the sample). The `sourcekitd`/cooperative-pool investigation in §1-§7 below was a
genuine, well-evidenced, but ultimately wrong trail — kept in full since the disproof technique
(a minimal C reproducer) and the real, independent `SourceKitDClient` fix it produced are both
still worth keeping. Read §8 first if you just want the actual answer; §1-7 are the record of how
it was ruled out.** Written up per this project's standing "durable write-up for real
investigations" convention (`docs/motivation.md`, `docs/priority-2-phase-0-spike.md`, etc.).

## 1. The symptom

Running `swift-isolation-map` against the real Swiftfin corpus (773 Swift files) intermittently
produces `Live fallback resolved 0 of 6804 unresolved declaration(s)` — every one of 6804 real,
in-scope local-declaration `cursorinfo` queries silently fails, with **zero** visible errors or
warnings anywhere in the verbose log (each individual `resolveOne` failure is swallowed by design,
matching this project's "never let one optional-enrichment component abort the whole run"
precedent — see `LocalDeclarationLiveFallback.swift`). A healthy run resolves ~1300+/6804. The
same corpus's *compiled-dependency* oracle phase (`External oracle: ...`) is unaffected even
during a bad run — only the local-declaration-fallback phase goes to zero.

Never observed on WordPress-iOS (3208 files), always run with `--oracle-workers 4` (§4 explains
why that matters).

## 2. Hypotheses tested and disproved, in the order tried

1. **"Only the first invocation after a fresh `swift build -c release` fails."** Disproved: the
   *third* invocation of an unrebuilt binary, run fully solo (nothing else running), reproduced
   the same 0/6804 failure.
2. **Resource contention with a concurrently-running WordPress-iOS analysis.** Disproved: a
   Swiftfin run launched *while* WordPress-iOS was actively running got a healthy 1312/6804; a
   later solo run (nothing else running) got the 0/6804 failure. Concurrency correlates with
   neither outcome.
3. **"Padding the extraction phase's wall-clock duration raises the odds of the later failure."**
   An early data point (4 runs, 3 bad) suggested this. Directly tested twice more and disproved
   both times: a plain 30-second `Thread.sleep` before client construction (no other change) ran
   healthy, and re-running the *exact* instrumentation that produced the original 3-bad-of-4
   cluster also came back healthy on a fresh attempt. The original cluster was very likely
   coincidental — those runs were launched close together in time, some genuinely concurrent with
   WordPress-iOS.
4. **Calling `sourcekitd_initialize()` twice in one process without an intervening
   `sourcekitd_shutdown()`.** This project's own code does this for real (see §3), and
   `sourcekitd.h`'s own doc comment says it's undefined behavior — but a targeted, minimal C
   reproducer (§4) could not turn this into an observable failure under any condition tested.
   Weakened almost to the point of ruled-out; kept as background context since it's still a real,
   independent code-quality issue worth fixing regardless (not yet done).

## 3. A real, confirmed contract violation — that turned out not to be the cause

`sourcekitd.h` (fetched from the real, open-source `apple/swift` repo — clone with `git clone
--depth 1 --filter=blob:none --sparse https://github.com/apple/swift.git` then `git
sparse-checkout set tools/SourceKit`, much faster than fetching file-by-file via `gh api
repos/.../contents/...`) documents, verbatim:

> Can be called multiple times as long as it is matched with a `sourcekitd_shutdown` call.
> **Calling `sourcekitd_initialize` a second time without an intervening `sourcekitd_shutdown` is
> undefined.**

`grep -rn shutdown Sources/` confirms this project's code never calls `sourcekitd_shutdown`
anywhere. `SwiftIsolationMap.swift`'s `resolveLocalDeclarationFallback` and
`resolveExternalIsolation` each unconditionally construct their own `SourceKitDClient` — so every
plain Swiftfin run (both phases in one process, `--oracle-workers` at its default of 1) genuinely
calls `sourcekitd_initialize()` twice with no shutdown in between. WordPress-iOS never hits this:
run with `--oracle-workers 4`, both phases route their real queries through fresh per-worker
subprocesses instead, so the two main-process clients (still constructed, per the same
unconditional code) are simply never queried.

Reading `sourcekitdInProc.cpp`/`Requests.cpp` (same sparse clone) explains why this is likely
harmless in practice for this project's usage: `sourcekitd::initializeClient()` is a
`gInitRefCount`-guarded no-op on the 2nd+ call, so the real backend (`GlobalCtx`, a
`SourceKit::Context`) is safely shared, not reinitialized. The only thing a second
`sourcekitd_initialize()` call visibly breaks is replacing the global `msgHandlingQueue` — but
that queue is only used by the *async* `sourcekitd_send_request` path; this project only ever
calls the *sync* `sourcekitd_send_request_sync`, which never touches it.

## 4. Minimal C reproducer: confirms the sourcekitd double-init theory is not the cause

Built a standalone C program (kept in scratch, not the repo — same "throwaway repro, durable
write-up" convention as every other empirical check this project does) that `dlopen`s
`sourcekitdInProc` directly via raw `dlsym`, with zero Swift/`async`/`actor` involved — mirroring
`RawSourceKitD.swift`'s own shape.

Tested, each condition run against both a trivial 1-file module and a real 3-file module with
genuine cross-file references:
- Single `sourcekitd_initialize()`, baseline: 500/500 succeeded.
- A **second** `sourcekitd_initialize()` with no shutdown (this project's own exact bug shape):
  500/500 succeeded.
- `sourcekitd_shutdown()` then re-`sourcekitd_initialize()` (the documented-safe path): 500/500.
- 10x rapid re-`sourcekitd_initialize()` calls back to back, then 500 more requests (stress):
  500/500.

**2000+ requests, zero failures, under every variant tested.** This is strong negative evidence:
double-init, by itself, does not appear to break `sourcekitd_send_request_sync` in practice — at
least not at any scale a minimal repro can reach. **Given this, filing an upstream sourcekitd
Issue/PR about the double-init behavior is not warranted** — there is no positive evidence of an
actual defect to report, only a documented-UB contract violation on this project's own side that
appears harmless for sync-only usage.

## 5. The actual hypothesis, and the shipped fix

The C repro's cleanest, most informative property: it involves **no Swift Concurrency at all**.
The real, Swift-wrapped tool does. Re-examining `SourceKitDClient`:

- It's a Swift `actor`. Actor method bodies run on Swift Concurrency's shared, limited-width
  cooperative thread pool by default (no custom executor is configured).
- `cursorInfo(_:)` called `raw.sendRequestSync(dictionary.object)` directly inside the actor's
  method body. `sourcekitd_send_request_sync`'s own real implementation
  (`Requests.cpp`, confirmed by reading it) is `Semaphore sema(0); sourcekitd::handleRequest(...);
  sema.wait(); return ReturnedResp;` — a genuine OS-level blocking wait, not a `Task`-suspension
  point Swift Concurrency can schedule around.
- **This project already found and fixed the identical shape of bug once before**, in
  `LiveProcessRunner` (`Sources/ProjectResolution/ProcessRunning.swift`'s own doc comment, kept
  in place, well worth re-reading directly): dispatching blocking work to `DispatchQueue.global()`
  and then synchronously waiting on it (`DispatchGroup.wait()`) can starve the cooperative pool
  once enough concurrent callers do it at once — every pool thread ends up parked in the wait,
  with none left to run the work being waited *for*. The confirmed fix there was a real
  `Thread.detachNewThread` (never drawn from the cooperative pool) bridged back with a
  `DispatchSemaphore`.

`sourcekitd`'s own in-process backend is, itself, effectively the real Swift compiler
(`performSema`, `Parser::parseDecl`, etc. — confirmed via a live `sample` profile in an earlier,
separate investigation, `docs/task-oracle-query-concurrency.md` §2's point 3) linked directly into
our process. It is entirely plausible that its own internal AST-building work draws on shared
dispatch/Concurrency machinery somewhere — meaning a caller parked on the cooperative pool waiting
for `sourcekitd_send_request_sync` to return could, under the right timing, be waiting for work
that itself needs a cooperative-pool thread to make progress. This is a completely ordinary,
well-precedented starvation shape, not a stretch.

**Fix**: `SourceKitDClient.blockingSendRequestSync(_:)` now dispatches the actual
`sourcekitd_send_request_sync` call onto a real `Thread.detachNewThread`, bridged back into
`async` via `withCheckedContinuation` (not a synchronous `DispatchSemaphore.wait()`, which would
just reintroduce the same problem one level up — blocking *this* actor method's own
cooperative-pool thread while it waits for the detached thread). `SourceKitDObject`/
`SourceKitDResponse` (raw C pointers) aren't `Sendable`, so both directions go through a small,
locally-scoped `UnsafeSendableBox<Value>: @unchecked Sendable` — safe here for the same reason
`RawSourceKitD: @unchecked Sendable` already is (exactly one call in flight per value, this
actor's own serialization guarantees no concurrent access to the same pointer).

## 6. Post-fix verification: the fix did NOT resolve the bug

Ran 8 repeated real Swiftfin analyses back to back against the post-fix binary, no rebuild in
between:

| Run | `Live fallback resolved` | `highRiskBoundaries` |
|-----|---------------------------|------------------------|
| 1   | 1312/6804                 | 136 |
| 2   | **0/6804**                 | **903 (catastrophic failure, unchanged)** |
| 3   | 1312/6804                 | 136 |
| 4   | 1312/6804                 | 136 |
| 5   | 1316/6804                 | 122 (true historical baseline) |
| 6   | 1312/6804                 | 136 |
| 7   | 1312/6804                 | 136 |
| 8   | 1312/6804                 | 136 |

1/8 (12.5%) still hit the full catastrophic failure — statistically consistent with the pre-fix
rate (small samples throughout this investigation ranged roughly 1-in-4 to 1-in-8), not lower.
**The cooperative-pool-starvation hypothesis in §5, despite being well-precedented and a genuine
independent correctness improvement, is not the (or not the only) cause of this bug.**

A second, smaller, separate non-determinism is visible in this same data and worth its own note:
6 of the 7 non-catastrophic runs landed on `1312/136`, only 1 landed on the true historical
baseline `1316/122` — a handful of individual queries are flaky run-to-run even among "healthy"
runs, shifting the final high-risk count by double digits. This was already noted once earlier in
this project's memory as a "separate, milder" issue; this data reinforces that it's real and
common (86% of healthy runs in this sample), not a rare edge case. Whether it shares a root cause
with the catastrophic failure is unknown.

## 7. What's not yet done

- **The actual root cause is still unknown.** Every specific hypothesis tested so far (first-run,
  concurrency, extraction-phase duration, sourcekitd double-init, cooperative-pool starvation) has
  been disproved or shown not to be the (sole) cause. No open hypothesis remains untested as of
  this writing.
- The independent, still-real `sourcekitd_initialize()`-called-twice code smell (§3) is not fixed
  — `resolveLocalDeclarationFallback` and `resolveExternalIsolation` still each construct their own
  `SourceKitDClient`. Worth sharing one client across both phases regardless of whether it's ever
  proven load-bearing for this bug, simply because the double-init is real, documented-undefined
  behavior with a cheap, obvious fix (thread one client through both call sites instead of two).
  Now a slightly *more* interesting angle given §6: since it's confirmed NOT the cause, fixing it
  is purely a hygiene improvement, not a bug-fix attempt — don't oversell it if done.
- `requestStatistics()` (diagnostic-only, `SourceKitDClient.swift`) was fixed identically for
  consistency (it shares the same actor and the same underlying blocking-call shape), but has no
  known real-world flakiness report of its own — nothing to verify there specifically.
- **Next avenues, genuinely untried:** (a) a live `sample`/`spindump` profile of an actual failing
  run, captured *during* the failure (this project has done exactly this kind of live profiling
  successfully once before for a different question, `docs/task-oracle-query-concurrency.md` §2
  point 3 — the same technique, aimed at a bad run instead of a healthy one, would show what every
  thread is actually doing at the moment of failure, rather than guessing from source reading
  alone); (b) instrument with the categorized `resolveOne` diagnostic (no-compiler-args /
  offset-failure / cursorinfo-failure, plus the actual thrown error text) and specifically
  reproduce with it in place — this was tried but abandoned after only 3 healthy repro attempts in
  the immediately-preceding follow-up session, not nearly enough attempts given the now-confirmed
  ~12.5% real failure rate (expect to need on the order of 10+ attempts for a fair chance of
  catching one with full diagnostics active).

## 8. Avenue (b), tried for real — and the actual root cause, unrelated to `sourcekitd` entirely

Followed §7(b) through properly this time: added the categorized `resolveOne` diagnostic (index +
elapsed time + real error text per query), then ran Swiftfin repeatedly until catching a bad run.
Took only 3 attempts this time (this bug is common, not rare — small samples are simply noisy).

**The caught bad run logged zero `DIAG-REAL` lines at all** — the diagnostic was placed just after
`compilerArguments.compilerArguments(forFile:)` and `UTF8OffsetLocator.utf8Offset` both succeed,
right before the `sourcekitd` call itself. Zero lines means **not one of the 6804 declarations
ever got that far** — every single one failed at `compilerArguments(forFile:)` with
`argumentsNotFound`, including files that are genuinely in-scope and normally resolve fine. This
immediately reframed the question: it was never a `sourcekitd` problem, it's about how this
project obtains real compiler arguments in the first place.

Cross-checked against the "External oracle" numbers, which had been sitting in every log the whole
time without being looked at closely enough: **every bad run this entire investigation ever
produced showed the exact same `External oracle: 845 resolved, 305 conformance(s) updated, 9784
unknown`** — a fixed, non-varying number, vs. ~2892 resolved on a healthy run. 845 is consistent
with being *entirely* the bulk symbol-graph cache's own contribution (module-level, e.g.
`Foundation`/`UIKit`/`SwiftUI`, doesn't need per-file compiler args at all) with **zero** live
per-USR queries succeeding — because `resolveExternalIsolation` shares the exact same
`compilerArguments` provider instance as `resolveLocalDeclarationFallback` (one instance, created
once in `SwiftIsolationMap.swift`, passed to both). Both phases were failing from the same root
cause the whole time; local-declaration-fallback's `0 of 6804` summary line was just the one that
happened to be checked first.

Added temporary logging directly to `LiveXcodeCompilerArgumentsProvider.runVerboseBuild`/
`loadArgumentsIfNeeded` and reproduced again (caught on the very first attempt this time). The
plain (non-`clean`) build attempt: `exitCode=0`, `stdoutLen=523545` (substantial, not an empty
log) — but **2 `builtin-Swift-Compilation` invocations, expanding to only 1 file total**. Real
mechanism: on a Swiftfin checkout that's already been analyzed (hence built) many times in a row
by earlier attempts, Xcode's incremental build system correctly determines the main app target
(hundreds of files) is fully up to date and skips it — but some other small, unrelated target
(judging by "2 invocations, 1 file", something with a batch-mode split of a near-single-file unit)
gets rebuilt for unrelated reasons every time. `loadArgumentsIfNeeded`'s existing "empty means
up-to-date, retry with `clean`" fallback (added for a *different*, previously-fixed bug — see the
doc comment's own citation of `docs/priority-3-compiled-dependency-isolation.md`) checks
`parsed.isEmpty` — and `parsed` has exactly 1 entry, so `.isEmpty` is `false`, the clean-rebuild
retry never fires, and this near-useless 1-file map gets cached (`cachedArguments`) for the rest
of the entire run. Every one of the 6804 declaration lookups (and every external-oracle lookup)
then correctly throws `argumentsNotFound` against a map that's real, non-empty, and utterly
insufficient.

**Fix**: `loadArgumentsIfNeeded` now retries with `clean` when `parsed.count <
minimumUsableFileCount` (10, a deliberately conservative heuristic — high enough to reliably catch
"only a stray unrelated target rebuilt" the way the real failure did), not just `parsed.isEmpty`.
**Not free**: a genuinely tiny real project (fewer real Swift files than the threshold) now
triggers this same retry every run, unconditionally — one harmless but unnecessary extra `clean`
rebuild (a one-time cost per tool invocation, this method is memoized). The retry is exactly one
attempt, not a loop — whatever the `clean` rebuild itself returns, even if still under the
threshold, is accepted as final; any file missing from that map still fails soft with
`argumentsNotFound`, one file at a time, same as before this fix. Six existing unit tests in
`XcodeCompilerArgsTests.swift` used small (1-2 file)
stub fixtures that now correctly trip this same retry path; fixed by padding the shared
`sampleFileListContents`/`sampleFileListContentsWithEscapedSpace` fixtures to 9-10 files each
(padding entries never referenced by name in any assertion) so their original intent — verifying
unrelated behavior (escaping, arg-sharing, `skipMacroValidation`, partial-failure recovery, a
missing-file lookup, destination-threading) — is preserved rather than each test needing its own
retry-path stub.

**Verified clean**: 12 repeated real Swiftfin runs post-fix, zero catastrophic failures (previously
this same 12-ish-run sample size reliably showed 1-4 catastrophic failures every time this session).
5 runs landed on the true historical baseline exactly (`1316/6804`, `122` high-risk); 7 landed on
the "borderline" `1312/6804`/`136` shape from §6 — **that smaller, separate non-determinism (§6)
is still unexplained and was not touched by this fix**, but it's a small, cosmetic-scale
discrepancy next to the catastrophic failure this section actually resolves, not a new regression.

**How this relates to §1-7**: the cooperative-pool-starvation fix (§5) is unrelated to the actual
bug and is being kept anyway (correct practice on its own merits, matches `LiveProcessRunner`'s own
precedent) but should not be described as fixing anything. The double-`sourcekitd_initialize()`
code smell (§3) is also still real, still unfixed, and still just a hygiene item — not this bug
either. The real lesson for next time: when a symptom shows up in one specific phase
(`local-declaration-fallback`'s `0 of 6804`), check whether a *shared* upstream dependency
(here, one memoized `compilerArguments` provider instance feeding both phases) is the actual
common cause before chasing theories specific to that one phase's own code.
