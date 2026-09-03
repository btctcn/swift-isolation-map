# SwiftPM compiler-args provider: retry-with-clean when the build log looks incomplete (issue #142)

**Status: PARTIALLY CLOSED — the SwiftPM-path mechanism is fixed and real-corpus verified. The
original, Xcode-path (`SwiftBuildCompilerArgumentsProvider`) Swiftfin finding that motivated issue
#142 in the first place remains open and unexplained** (see "Scope" below) — issue #142 stays open
for that.

## Background

`docs/task-sourcekitd-cooperative-pool-starvation.md` §9's own loose end 2, tracked as
[issue #142](https://github.com/btctcn/swift-isolation-map/issues/142): oracle-query resolved/
unknown counts vary between otherwise-identical runs. Original evidence was Swiftfin (an Xcode
container); reproduced a third time via this project's own self-analysis (an SPM container) during
issue #125's own investigation, with no root cause identified at the time.

## Investigation

A new, permanent, opt-in categorized diagnostic (`SWIFT_ISOLATION_MAP_QUERY_DIAGNOSTICS`, kept --
matching this project's own `SWIFT_ISOLATION_MAP_ORACLE_STATS`/`SWIFT_ISOLATION_MAP_WORKER_STDERR`
precedent for a diagnostic worth keeping rather than a one-off probe to throw away) added to
`ExternalIsolationBackfill.query` — logging which stage a query failed at (no compiler args /
offset failure / cursorinfo threw / no USR match / no isolation parsed) — found the dominant factor
swinging between two real self-analysis runs was `no-compiler-args` (288 vs. 33 failures), not
`cursorinfo-threw`.

`LiveSwiftPMCompilerArgumentsProvider` resolves per-file compiler arguments by running `swift build
-v` **once** and parsing its real invocation lines. Confirmed directly, real and reproducible: a
plain incremental `swift build -v` only prints a compile line for a file SwiftPM actually
(re)compiles *that run* — a target it decides is already fully up to date gets no line at all, real
source and real arguments notwithstanding. Four consecutive `swift build -v` invocations against
this exact package, zero source changes between them, parsed to **10** real compile lines each,
while an isolated, from-scratch build (`--build-path` a fresh temp directory) of the identical
source parsed to **1244**. The *first* of that streak, run immediately after unrelated build
activity, parsed to **32** — direct evidence the incremental parse's own completeness is not stable
run to run, purely a function of `.build`'s own leftover state.

Notably, `Tests/ProjectResolutionTests/SwiftPMCompilerArgumentsProviderTests.swift`'s own existing
`realBuildAgainstSimpleActorFixtureProducesUsableCompilerArguments` test already had a comment
documenting this exact phenomenon ("an incremental `swift build` sees unchanged sources and skips
recompilation entirely... force a real rebuild every time by clearing it first") — known and worked
around in one test, but never fixed in the production code path itself.

## Fix

Same shape as this project's own now-removed `LiveXcodeCompilerArgumentsProvider`'s PR #71 (retry
with a forced-clean rebuild when a parsed build log looks suspiciously incomplete): if the
incremental parse's file count is too low, retry once with `swift package clean` (~11s, measured)
then a full `swift build -v` (~93s for this project's own 178 files) — confirmed to reliably produce
a complete listing (1235 lines, matching the from-scratch `--build-path` figure) without needing a
wholly separate build directory (which would also re-resolve/re-fetch every dependency from
scratch).

**A fixed absolute threshold is the wrong tool — found by this fix's own first version regressing a
real test.** `Tests/Fixtures/simple-actor` has exactly one real Swift file; a fixed threshold of 10
retried *unconditionally* for it, doubling its build cost every time and — a real failure this
session — racing a *different*, concurrently-running test's own build against the same shared
fixture directory's `.build/build.db` (`"disk I/O error"`). Conversely, a fixed 10 is *too low* for
a large real project: self-analysis produced incomplete parses of both 10 *and* 32 lines, and 32 is
not `< 10`. The threshold now scales with the analyzed project's own real file count
(`expectedFileCount`, threaded from `StalenessOrchestration.swiftFiles.count` at the real call
site): a quarter of it, floored at 1, falling back to a fixed 10 only when a caller (an older test
double) doesn't provide it.

**A second real hazard found verifying this against self-analysis**: `swift package clean` on
`packageDirectory` is dangerous specifically when the *analyzed* package is the *same* checkout the
currently-running tool's own binary was built from (self-analysis, or any dev workflow running an
in-place `swift build` binary against its own source) — it deletes `.build/release/...`, the exact
binary any `--oracle-workers > 1` subprocess needs to relaunch itself, out from under the running
process. Confirmed directly this session. Scoped to this narrow self-referential case (an ordinary
end user analyzing an unrelated SPM package never shares `.build` with the running tool's own
binary at all) — documented here as a known, accepted limitation rather than engineered around; this
project's own verification runs now always copy the release binary to a stable path outside the
analyzed package first, exactly to avoid it.

## Scope: does not explain the original Swiftfin finding

`LiveSwiftPMCompilerArgumentsProvider` (SPM containers) and `SwiftBuildCompilerArgumentsProvider`
(Xcode containers, direct `SWBBuildService` API calls, no log parsing at all) are unrelated
implementations. This fix closes a real, independently-confirmed contribution to oracle-query
non-determinism for SPM-analyzed projects, but the *original* Swiftfin evidence that opened issue
#142 goes through the Xcode path, which has no equivalent "incomplete verbose log" vulnerability to
fix. That residual variance remains genuinely unexplained; issue #142's own §7 avenue (a) -- a live
`sample`/`spindump` profile captured during an actual failing Xcode-path run -- is still the
next real step there, not attempted by this fix.

## Verification

- New unit tests (`Tests/ProjectResolutionTests/SwiftPMCompilerArgumentsProviderTests.swift`): retry
  triggers and uses the retry's own result, no retry when already at/above threshold, a `clean`
  failure is fail-soft, a genuinely tiny package (`expectedFileCount: 1`) never retries, a large
  package (`expectedFileCount: 178`) retries even for a partial parse well above the fixed fallback
  floor (32 lines).
- `swift test -c release`: 632/633 passing -- the one failure is `DeclarationLinkerTests.swift`'s
  own "cross-file protocol-witness" test, confirmed **100% pre-existing and unrelated**: reproduced
  identically on unmodified `main` with zero of this fix's own changes (a real, separate race
  between two test files sharing `Tests/Fixtures/cross-file-witness`'s `.build`, filed as
  [issue #148](https://github.com/btctcn/swift-isolation-map/issues/148)).
- **Real-corpus verification**: this project's own self-analysis, 4 consecutive runs from a stable
  binary copy (avoiding the self-clean hazard above), identical cached index store: byte-identical
  summary every time (`External oracle: 476 resolved, 193 unknown` all four runs) -- was swinging
  between roughly 304-391 and 473-192 before this fix, confirmed eliminated.
