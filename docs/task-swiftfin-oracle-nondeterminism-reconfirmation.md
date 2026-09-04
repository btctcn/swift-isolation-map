# Issue #142's original Xcode-path (Swiftfin) finding: no longer reproducible

**Status: INVESTIGATED, not reproducible today. Recommend closing issue #142 as "not currently
reproducible" (same precedent as the Mindbox `AsyncOperation` finding in
`docs/task-remaining-matcher-batch.md` §8) rather than leaving it open indefinitely with no current
target to investigate.**

## Background

`docs/task-sourcekitd-cooperative-pool-starvation.md` §6's own original finding: 7 repeated,
non-catastrophic Swiftfin runs, 6 landing on `1312/6804` resolved (`136` high-risk), 1 landing on
the true historical baseline `1316/6804` (`122` high-risk) -- a small, ~1-in-7 residual
non-determinism, confirmed **not** caused by the catastrophic-failure root cause §8 found and fixed
(a `compilerArguments` caching bug). Tracked as issue #142's own primary evidence (the SwiftPM-path
mechanism `docs/task-swiftpm-compiler-args-retry-threshold.md` fixed is a *different, independent*
issue, found later via this project's own self-analysis, and explicitly does not touch or explain
this Xcode-path finding).

## A prerequisite correction: Swiftfin is *not* environment-blocked

Before this investigation could even start, `docs/task-multi-platform-target-support.md`'s own claim
("A separate, confirmed-independent real Swiftfin/environment issue... `ComputeTargetDependencyGraph`
failing... confirmed real and entirely independent of this project's own code by reproducing it with
a plain, manual `xcodebuild` ... invocation with no involvement of this tool at all") turned out to
be **incomplete, not a genuine environment blocker**. Reproducing that same plain manual `xcodebuild
build -scheme Swiftfin -destination "generic/platform=iOS Simulator"` today (2026-09-04) still fails
identically -- but the real, underlying reason is a plain missing `-skipMacroValidation`, confirmed
by the actual error text:

```
error: Macro "CasePathsMacros" from package "swift-case-paths" must be enabled before it can be used
error: Macro "StatefulMacrosMacros" from package "StatefulMacros" must be enabled before it can be used
```

-- exactly the real, already-documented Xcode macro-validation security gate this project's own
`--skip-macro-validation` flag exists to bypass (its own README doc comment already names Swiftfin,
`swift-case-paths`, `StatefulMacros` as the real, confirmed motivating case for that flag). Passing
`-skipMacroValidation` to the identical plain manual `xcodebuild` command succeeds
(`** BUILD SUCCEEDED **`). The original PR #141 investigation's own "plain manual" repro simply
didn't pass this flag either, and mischaracterized a legitimate macro-security gate as an
unrelated environment failure. `docs/task-multi-platform-target-support.md` itself is not corrected
in this pass (out of scope for this investigation) -- flagged here so a future reader isn't misled
by it into believing Swiftfin is unusable in this environment.

## Investigation: 7 repeated real runs, matching the original sample size and methodology

Ran `swift-isolation-map ~/corpora/Swiftfin/Swiftfin.xcodeproj --scheme Swiftfin
--skip-macro-validation --oracle-workers 4` seven times: the first with `--force-reindex` (a fresh
index store), the remaining six reusing that identical cached index store -- controlling for the one
variable (corpus/index state) that could legitimately explain a difference, same discipline as every
other real-corpus A/B in this project's history.

**Result: all 7 runs are byte-identical**, confirmed at two levels:
- `summary` identical across all 7 (`crossActorBoundaries: 1125`, `highRiskBoundaries: 144`,
  `typesAnalyzed: 6434`, `unspecifiedIsolation: 1028`, ...).
- A full node-level set diff (by USR, not positional) of runs 2-7 against run 1: zero added, zero
  removed, zero changed, every single time.

The permanent `SWIFT_ISOLATION_MAP_QUERY_DIAGNOSTICS` diagnostic (added shipping
`docs/task-swiftpm-compiler-args-retry-threshold.md`'s own fix, kept for exactly this kind of
follow-up) was active throughout; its own `no-compiler-args` entries were for files genuinely
outside the analyzed `Swiftfin` (iOS) scheme's own compiled sources (`Swiftfin tvOS/`-only files,
`fastlane/swift/` build-automation scripts) -- expected, not evidence of the residual
non-determinism this investigation was looking for.

(Note: this real corpus's own absolute numbers -- `1125` cross-actor boundaries, `6434` types
analyzed -- don't match §6's original `6804`/`1312`/`1316` figures at all. Swiftfin is a real,
actively-maintained open-source project; its own source has very likely changed substantially in
the time since that original measurement. This doesn't affect the actual question this
investigation answers -- whether *repeated runs against the identical, current corpus state* still
disagree with each other -- only whether the *specific* USRs originally implicated are still the
same ones, which can't be verified without the original run's own raw edge list, not preserved
anywhere.)

## Why the discrepancy is not chased further

Given a completely clean 7/7 reproduction with the identical methodology and sample size that
originally found a ~1-in-7 rate, forcing an explanation for why it no longer occurs would be
exactly the kind of guess this project's own discipline exists to avoid. Two real, plausible,
unverified candidates exist (not chosen between, since neither can currently be confirmed): (1) one
of the many compiler-argument-handling fixes shipped since (PR #133's `-g` stripping, PR #136's
`-Xcc`/`-Xfrontend` token-orphaning fix, among others) incidentally closed whatever caused a small
fraction of live queries to behave differently run to run; (2) Swiftfin's own current source state
no longer contains whatever specific construct originally triggered it. Matches this project's own
established precedent for exactly this situation (`docs/task-remaining-matcher-batch.md` §8's own
Mindbox `AsyncOperation.setExecuting:`/`setFinished:` finding: "Most likely the Mindbox pod version
installed in the corpus has since changed the exact call shape that produced the original 2 edges
-- not something this project fixed. Not re-opened as an issue since there's nothing current to
point at").

## Recommendation

Close issue #142 as "not currently reproducible" -- the SwiftPM-path mechanism it also tracked is
already fixed and documented separately
(`docs/task-swiftpm-compiler-args-retry-threshold.md`), and this session's own 7/7 clean
reproduction of the original Xcode-path evidence, at the identical sample size, found nothing left
to investigate. If it resurfaces on a future real corpus, it should be filed as a fresh issue with
its own real evidence, not by reopening this one on the strength of a stale finding.
