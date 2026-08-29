# Task: parallelize the external-oracle live-query phase across processes

Tracks the user's process-tree optimization idea (see memory note from the session that raised
it). Two real spikes, both against Project Iris (see `docs/reference-project-corpora.md`), decided
the shape before any production code was written, per this project's own workflow (hypothesis →
spike → ...).

## Step 1 — Hypothesis

Original framing: spawn a tree of `swift-isolation-map` processes, one per dependency (Pod/SPM),
aggregated by a root process. Two things needed confirming before designing anything: (a) does the
live-query phase actually dominate wall-clock, or would parallelizing the cheaper bulk-extraction
phase already capture most of the win; (b) does real OS-process-level parallelism for `sourcekitd`
work actually deliver a real speedup, or is there some other shared, serializing resource (disk,
toolchain locks, etc.) that would defeat it the way hypothesis 1's *intra-process* concurrency was
defeated by `sourcekitd`'s own process-wide `ASTBuildQueue`
(`docs/task-oracle-query-concurrency.md` §7.7).

## Step 2 — Spike 1: which phase actually dominates

Added temporary env-gated timing (`SWIFT_ISOLATION_MAP_PHASE_TIMING`,
`Sources/swift-isolation-map/ExternalIsolationBackfill.swift`) around the three real phases of
`ExternalIsolationBackfill.resolve`, then ran a real, full, live invocation against Project Iris:

| Phase | Wall-clock | Share |
|---|---|---|
| Bulk symbol-graph (`bulkSymbolGraphCache`) | 19.3s | 2.4% |
| **Merged live-query loop** | **792.3s** (6924 items, 1631 distinct live-query files) | **97.6%** |
| Syntactic-placeholder phase | 0.3s (3282 items) | ~0% |

**Confirmed decisively**: the live-query phase is the whole game. Parallelizing the bulk phase
alone (the cheaper, originally-floated first step) would save at most ~2.4% of total oracle time —
not worth pursuing on its own.

**Refinement to the original framing, forced by this data**: the live-query phase's 1631 files
don't naturally partition along "one dependency" boundaries — a live-query file can belong to any
Pod, SPM package, or SDK module the bulk cache didn't already cover. The dependency-tree framing
(and its Pods-vs-SPM structural mismatch — Pods have no independent scheme/index store to run a
recursive `swift-isolation-map` invocation against, SPM packages do) stops being the right question
once the bottleneck is known to be a flat list of live queries, not a tree of dependencies. The
better question: can that flat, already-file-sorted list (hypothesis 0's own ordering, kept intact)
be split into N contiguous chunks and processed by N independent workers?

## Step 2 — Spike 2: does real process-level parallelism actually deliver

Built a real, throwaway multi-process harness (not committed): cached real compiler arguments for
75 real Project Iris files to a JSON file (avoiding the cost of re-running `xcodebuild` per worker
— see the note below), took a real 800-item contiguous slice of the actual file-sorted merged plan
(`SWIFT_ISOLATION_MAP_DUMP_MERGED_PLAN`), and ran three real `SourceKitDClient.cursorInfo` test
scenarios, each a genuinely separate OS process (`swift test --filter <name>` launches its own
`swiftpm-testing-helper` process per invocation, confirmed via `ps aux`):

| Run | Items | Elapsed |
|---|---|---|
| Sequential, one process, full 800 | 800 | 25.6s |
| Half A, solo | 400 | 6.47s |
| Half B, solo | 400 | 7.77s |
| Half A, **concurrent** with B | 400 | 6.98s |
| Half B, **concurrent** with A | 400 | 7.90s |

**Confirmed decisively**: each half's concurrent time (6.98s / 7.90s) is within ~5-8% of its own
*solo* time (6.47s / 7.77s) — not anywhere close to the ~14.2s (6.47+7.77) two fully-serialized
runs would sum to. Two independent `sourcekitd` instances in two separate processes genuinely run
in parallel with negligible cross-process contention. This is the opposite result from hypothesis
1's intra-process finding, for the reason expected going in: separate processes get separate
`ASTBuildQueue`s.

**Correctness, not just timing, was checked**: timing alone answers "is it fast," not "is it still
right" -- a separate, real check recorded each query's actual returned data (the primary symbol's
USR and `fullyAnnotatedDeclXML`, not just success/failure) for the sequential run and for both
concurrent halves, then diffed the sequential file against the two concurrent halves' files
concatenated back together. Result: **byte-for-byte identical, 802/802 lines** (800 data lines +
trailing newline handling). Two independent `sourcekitd` processes running concurrently against the
same real project produced exactly the same real answers a single sequential process did — no
corruption, no cross-process interference, nothing silently dropped or reordered.

**Real operational note found along the way, not the point of this spike but worth recording**:
`LiveXcodeCompilerArgumentsProvider` tries a plain `xcodebuild -verbose build` first and only falls
back to a real `clean build` if that yields zero parseable compile lines (already documented,
existing, deliberate behavior). On an already-fully-built project (the common case right after a
normal run), the plain attempt finds nothing to compile and triggers the `clean` fallback — a real,
expensive cost every time compiler args are needed against an up-to-date project. This is why the
spike's own compiler-args cache was built once and shared, rather than letting each worker rebuild
it independently (which would have made the comparison meaningless — dominated by clean-build time,
not query throughput). Whether this same cost is already being paid once per normal
`swift-isolation-map` run today (inside the existing single-process live-query phase) or represents
its own separate, currently-hidden optimization opportunity was not measured here and is worth a
follow-up.

## Step 3 — Design direction

Both hypotheses confirmed. Shape chosen: split the already file-sorted merged work-item list into
N contiguous chunks (preserving hypothesis 0's file-adjacency win *within* each chunk), run N
worker processes each with their own `sourcekitd`, merge the N sets of outcomes back into one
`ExternalIsolationResolution` in the root process.

1. **Worker process shape**: a hidden CLI mode of `swift-isolation-map` itself
   (`--oracle-worker-input`/`--oracle-worker-output`, both hidden from `--help`), spawned by the
   root process with a slice of work plus only the compiler arguments its own files need. Reuses
   the existing `query(...)` logic unchanged (`Sources/swift-isolation-map/OracleWorker.swift`).
2. **IPC shape**: temp-directory JSON files per worker (`OracleWorkItemWire`,
   `OracleWorkerInput`/`OracleWorkerOutput`). Compiler arguments are resolved once in the root
   (via the same `CompilerArgumentsProviding` already in hand) and handed to each worker as a
   `StaticCompilerArgumentsProviding` — a worker never triggers its own `xcodebuild`/`swift build`.
   Bulk-cache hits are resolved in the root directly and never sent to a worker at all.
3. **Choosing N**: user-controlled via `--oracle-workers <N>` (default `1`, today's exact
   sequential behavior — opt-in, not a silent default change). No auto-detection of core count
   implemented; left to the caller for now.
4. **Failure handling**: a worker whose process exits non-zero, or whose output file is
   missing/unparseable, has every one of its assigned items fail soft to `.unknown` — the same
   "never let one optional-enrichment component abort the whole run" precedent as the rest of the
   external-oracle machinery, not a hard failure of the whole analysis.

## Step 4 — Code (done)

Implemented as described above. New file `Sources/swift-isolation-map/OracleWorker.swift`
(wire types, `StaticCompilerArgumentsProviding`, `OracleWorker.run` for worker mode,
`OracleWorker.resolveInParallel` for root-side dispatch). `IsolationKind` gained `Codable`
conformance (needed to cross the process boundary). `ExternalIsolationBackfill.QueryOutcome` and
`query(...)` were relaxed from `private` to internal so `OracleWorker` (same target) can reuse them
directly — no duplicated query logic between the sequential and parallel paths.
`SwiftIsolationMap`'s `path`/`scheme` arguments were defaulted to `""` (rather than required)
specifically so the hidden worker-mode invocation can be parsed without also needing a real
project path/scheme; `run()` validates both are non-empty itself in every path except worker mode.

## Step 4.5 — A real, unrelated bug found and fixed along the way (return to step 1, briefly)

The first full, real end-to-end run with `--oracle-workers 4` against Project Iris **hung
indefinitely** (twice, reproducibly, at the same point — right as workers began real live
queries). Not a resource/environment issue (ruled out via a stack sample, `sample <pid>`): the
worker process was blocked inside `sourcekitd`'s own internal diagnostic logger
(`SourceKit::Logger::~Logger()` → `fprintf` → `write()`), and the *root* process was blocked in
`Foundation.Pipe`'s `readDataToEndOfFile()` on the worker's **stdout**.

Root cause, found in `Sources/ProjectResolution/ProcessRunning.swift`'s pre-existing
`LiveProcessRunner.run(...)` (used by every subprocess invocation in this project, not just oracle
workers): it read `stdoutPipe` to completion, *then* `stderrPipe`, sequentially. A worker
processing real live queries produces substantial real `sourcekitd` diagnostic noise on stderr
(the `error creating ASTInvocation: warning: option '-incremental' is only supported in
swift-driver` lines visible in every real run's log). Once that noise exceeds the kernel's pipe
buffer (~64KB on macOS) while the root is still reading stdout first, the worker's own `write()`
to stderr blocks, the worker can never finish (or produce more stdout), and the root's
`readDataToEndOfFile()` on stdout can never see EOF — a real, textbook `Process`/`Pipe` deadlock,
not a hang specific to this feature. No earlier caller of `LiveProcessRunner` had ever produced
enough concurrent dual-stream output to trigger it.

**Fixed, attempt 1**: both pipes drained concurrently, via two `DispatchQueue.global()` tasks
joined with a `DispatchGroup.wait()`, rather than one read to completion before the other.

**Verification, both directions**: a new regression test,
`Tests/ProjectResolutionTests/LiveProcessRunnerTests.swift`
(`doesNotDeadlockOnLargeDualStreamOutput`), spawns a real child (`sh -c "yes o | head -c 200000;
yes e | head -c 200000 1>&2"`) writing 200,000 bytes to both streams. Confirmed the fix passes it
(0.08s); confirmed the *pre-fix* code genuinely hangs on it too (`git stash` the fix, re-run: fails
after the full 15s timeout, `exitCode == -1`, stderr truncated to 29 bytes) — not just reasoned
about, both directions empirically demonstrated.

## Step 4.6 — A second, real deadlock, this time in the fix itself (return to step 1 again)

Running the *full* `swift test` suite (not just the one new regression test) with attempt 1's fix
in place hung indefinitely too — reproducibly, every full run. A stack sample (`sample <pid>`) of
the stuck `swiftpm-testing-helper` process found **multiple different, unrelated tests**
(`extensionOfExternalTypeResolvesEndToEndWithRealAppKit`,
`linkMergesRealCrossFileTypeAndExtensionRegardlessOfOrder`) all blocked at the exact same place:
`_dispatch_group_wait_slow` inside `LiveProcessRunner.run(...)`'s own `pipeReadGroup.wait()` —
attempt 1's fix, not the original bug.

**Root cause**: `DispatchQueue.global()` schedules onto libdispatch's limited-width cooperative
thread pool -- the same pool Swift Concurrency's own executors use. Swift Testing runs many
`@Test`s concurrently by default; each one calling `LiveProcessRunner.run(...)` submits two more
tasks to that *same* pool and then *synchronously blocks* the calling thread on
`DispatchGroup.wait()` until they finish. Once enough concurrent callers do this at once, every
thread in the pool ends up parked in `wait()`, so the newly-submitted read tasks that `wait()` is
blocking on can never get a thread to actually run on -- a real thread-pool-exhaustion deadlock,
distinct from the original pipe-buffer deadlock, caused by the fix for it.

**Fixed, attempt 2**: real OS threads (`Thread.detachNewThread`), signaled via
`DispatchSemaphore`, instead of `DispatchQueue.global()` + `DispatchGroup`. A `Thread` is never
drawn from libdispatch's cooperative pool, so blocking the calling thread while waiting on one
can't shrink the pool available to any other concurrent caller.

**Verification**: the same regression test still passes (0.09s) -- proving attempt 2 still fixes
the original bug, not just the second one. The decisive check is the *full* suite, run under its
own real concurrent load, twice: both a clean run (57.5s, no hang) and one with a single
unrelated, non-reproducing flake (a real `swift build -v` invocation that failed with an empty
stderr and exit 1 once, passed cleanly in isolation and on a subsequent full run -- consistent
with this project's already-documented real-toolchain flakiness elsewhere, not a regression from
this fix).

## Step 5 — Tests and verification

- New unit-level regression test for the pipe-deadlock fix (above, both attempts) — 249/249
  passing on a clean full-suite run.
- **Real, full-scale, end-to-end verification against Project Iris** (not a small fixture):
  - Timing: live-query phase went from **792.3s** (sequential, `--oracle-workers 1`, the
    unchanged default) to **431.6s** with `--oracle-workers 4` — a real **~1.84×** speedup (not
    the near-linear 4× the small-scale spike's own numbers might suggest; real overhead exists at
    this scale — uneven per-chunk query cost and/or real machine resource contention, not measured
    further here). Total wall-clock: 17:11.56 → 10:49.78.
  - Correctness: the resulting report was diffed against a real sequential baseline run on the
    same project — **51,087/51,087 nodes identical, 55,042/55,042 edges identical, every summary
    counter identical, zero isolation differences**. Real process-level parallelism produces
    exactly the same real answers a sequential run does, at real full-project scale, not just on
    a small spike slice.

## Step 6 — Documenting results

Done — this document. `docs/README.md`'s index and the process-tree memory note both point here.

## Step 7 — PR

Merged as [#34](https://github.com/btctcn/swift-isolation-map/pull/34).
