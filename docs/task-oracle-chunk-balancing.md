# Task: balance oracle worker chunks by distinct file count, not item count

Tracks [issue #35](https://github.com/btctcn/swift-isolation-map/issues/35), found while validating
`--oracle-workers` (`docs/task-process-tree-optimization.md`) against Project Iris.

## Step 1 — Hypothesis

`OracleWorker.resolveInParallel` split the file-sorted merged work-item list into `N` equal-sized
contiguous chunks by **item count**. Real per-chunk cost varies a lot even at equal item count,
because chunks are contiguous slices of a file-sorted list (hypothesis 0's own ordering): a chunk
landing on a dense cluster of repeated queries into a handful of files gets strong AST-cache reuse
(cheap); a chunk spanning many single-query files gets little reuse (expensive, closer to one real
AST build per item). Hypothesis: balancing chunks by **distinct file count** instead would produce
meaningfully more even real per-worker cost, since file count is what actually drives AST-cache
reuse per hypothesis 0's own logic.

## Step 2 — Spike

Simulated both strategies against Project Iris's real, already-captured merged plan (6924 items,
1812 distinct files, `N=8`) — no code changed yet, no real run needed for this part:

| Strategy | Per-chunk distinct-file counts | Spread (max/min) |
|---|---|---|
| Equal item count (existing) | 77, 120, 234, 194, 146, 277, 391, 377 | **5.08x** |
| Equal distinct-file count (proposed) | 226, 226, 226, 226, 226, 226, 226, 230 | **1.02x** |

Decisive enough to proceed to implementation directly.

## Step 4 — Code

`OracleWorker.balancedChunks(items:workerCount:)` (`Sources/swift-isolation-map/OracleWorker.swift`):
walks the already file-sorted `items` once, closing the current chunk whenever adding the next
item's file would push its distinct-file count over an equal `N`-way share, capped at
`workerCount - 1` cuts so the final chunk absorbs whatever remains. Replaces the old
`stride(from:to:by:)`-based equal-item-count split in `resolveInParallel`. Item counts per chunk
are now deliberately uneven (that's the whole point); file counts are balanced instead.

## Step 5 — Tests and verification

- New unit tests, `Tests/swift-isolation-mapTests/OracleWorkerTests.swift`: an exact, hand-computed
  case (a 4-item dense file followed by five 1-item sparse files, `N=2`) asserting the precise
  expected chunk boundaries and distinct-file balance; a chunk-count-never-exceeds-`N` case; an
  all-items-preserved-in-order case.
- **Real, full-scale, end-to-end re-verification against Project Iris**, same methodology as the
  parent task:
  - Timing: live-query phase **240.1s → 211.5s** with `--oracle-workers 8` — real, but more modest
    than the 5.08x → 1.02x distinct-file-spread improvement alone might suggest (~12%, not
    proportional). Overall speedup vs. the unchanged sequential baseline (792.3s): **~3.30x → ~3.75x**.
  - Correctness: diffed against the same sequential baseline used throughout this project's
    process-tree work — **zero isolation differences, edges identical, every summary counter
    identical**.
  - Full `swift test -c release`: 252/252 passing (249 + 3 new).

**Why the real improvement is smaller than the simulation's balance numbers alone would suggest**:
distinct file count is a good proxy for AST-cache-reuse cost, but not a complete one -- each live
query still carries real per-item IPC/parsing overhead regardless of cache state, and the balanced
chunks deliberately have very uneven item counts (as low as ~500, as high as ~1800 in the earlier
simulation). A chunk with many items but few distinct files trades away some of its cache-reuse
advantage to a higher fixed per-item cost. Not measured further here; a combined
cost metric (file count *and* item count) is a plausible follow-up if this gap matters enough to
revisit -- not pursued in this pass.

## Step 6 — Documenting results

Done — this document. `docs/README.md`'s index points here.

## Step 7 — PR

Merged as [#37](https://github.com/btctcn/swift-isolation-map/pull/37).

## Noted, not part of this task

The user separately floated auto-detecting a sensible `--oracle-workers` default from the local
core count, instead of requiring the caller to pick `N` explicitly. Not implemented here --
recorded for a future pass.
