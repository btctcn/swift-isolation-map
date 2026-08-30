# Investigation: `-enable-anonymous-context-mangled-names` stderr noise

**Status: fixed at the root cause (2026-08-30, see "Fixed" section at the end) -- not by
suppressing the symptom, but by removing the one argument (`-g`) that makes `sourcekitd`'s own
driver-emulation logic auto-inject the flag it then rejects.** Everything through "Revisited" below
is the real, chronological record of how that was found -- including a real, working fd-2
interception attempt that was tried, empirically proven fragile, and deliberately not kept.

## Symptom

A real run against Project Iris prints many lines like this to stderr, interleaved with normal
`--verbose` output, during "Resolving external isolation (compiled dependencies)...":

```
<unknown>:0: error: unknown argument: '-enable-anonymous-context-mangled-names'
```

## What it is not

- Not something this project's own argument construction introduces. `-enable-anonymous-context-
  mangled-names` is already in `CompilerArgumentsSanitizing.frontendOnlyFlags` and is stripped from
  every real `key.compilerargs` this project builds, confirmed by reading the flag's own git history
  (`ba3b74c`, part of the original dozen frontend-only flags found in real captured `swift build -v`
  output). The flag reappears anyway -- it is re-injected internally by `sourcekitd`'s own driver-
  emulation logic (`swift::driver::createCompilerInvocation`) when building a frontend invocation
  from driver-style arguments that include `-g`, per real `swiftlang/swift` source
  (`lib/Driver/ToolChains.cpp`: `-g` without optimization implies this flag). The *current* toolchain
  (Xcode 26.4 / Swift 6.3) then rejects the very flag it just auto-injected -- confirmed by direct
  reading of the driver source and by direct experimentation (below), not assumed.
- Not a correctness bug for this project's own results. Confirmed directly, repeatedly: even when the
  diagnostic prints, the same `cursorInfo` call still returns a correct, real USR. It is printed
  directly by `sourcekitd`'s own in-process diagnostic engine straight to this process's stderr,
  bypassing this project's JSON response handling entirely -- there is no return-value corruption to
  catch.

## What triggers it -- confirmed on the real corpus, not guessed

Extracted the *exact*, real, deterministic oracle query plan `ExternalIsolationBackfill` builds for a
real Project Iris run (`SWIFT_ISOLATION_MAP_DUMP_MERGED_PLAN=1`) -- 4880 real `(targetUSR, file,
line, column)` triples -- and replayed every single one directly against `sourcekitd`, capturing
stderr per-query (unbuffered `dup2` capture around each call, chronologically exact).

**Result: 6 of 6 diagnostic occurrences, 0 of the other 4874, are all hovers on a compiler-
synthesized call site standing in for a literal expression**:
- `DefaultStringInterpolation.appendInterpolation(...)` (4 occurrences) -- the implicit call every
  `"\(x)"` string interpolation desugars to.
- `OSLogInterpolation.appendInterpolation(...)` (1 occurrence) -- the same shape for `os.Logger`'s
  own string interpolation.
- `UIImage.init(imageLiteralResourceName:)` (1 occurrence) -- the implicit initializer call behind
  `#imageLiteral(resourceName:)`.

Every single occurrence of any of these three symbol shapes anywhere in the 4880-item plan triggered
the diagnostic; no other symbol shape ever did. This is a 100% correlation on real, exhaustive data,
not a sample.

**Bisected which compiler arguments matter**, starting from AFError.swift's real 133-argument
invocation (known to reproduce reliably):
- Removing every `-Xcc`/`-Xclang`-prefixed argument and every `-I`/`-F` search path (i.e. all Clang/
  ObjC-interop machinery) makes the diagnostic stop appearing entirely on the same query. `-g` alone,
  without real Clang-interop context, is not sufficient.
- A drastically reduced argument list (`-module-name`, `-Onone`, just the one file, `-sdk`/`-target`/
  `-g`/`-swift-version`, dropping the other 43 real module files) does not reproduce it either --
  AFError.swift alone, out of its real module context, doesn't build a valid-enough AST to test with.

## Attempted minimal, standalone reproduction -- inconclusive, likely scale-dependent

Built a from-scratch, fully self-contained mixed Swift+ObjC framework (hand-written `.framework`
directory, `module.modulemap`, `-import-underlying-module`, `-Xcc -F<path>`) with the exact same
`appendInterpolation` call shape. The symbol resolved correctly at the exact same kind of position
(the `(` opening a string interpolation) -- but the diagnostic did **not** fire.

Went further: built a real, fully public, shareable project (`xcodegen` + CocoaPods installing the
real, current, public Alamofire pod, no Project Iris content at all) and replayed the identical
query shape against it directly. The diagnostic still did **not** fire on the interpolation site --
it fired instead on an unrelated position (end-of-scope `}`, no symbol at all).

**Conclusion**: the trigger is not purely "hover this symbol shape, plus `-g`, plus Clang interop" --
something about *scale* (Project Iris: 303 targets, a large real Pods dependency graph) or
accumulated `sourcekitd` state across a long-running real query session also matters, and that
factor was not isolated. A small, clean project with the identical symbol and identical Clang-interop
shape does not reproduce it deterministically.

## Why not filed upstream, why not suppressed

- **Not filed upstream**: a bug report that doesn't reproduce deterministically outside one large,
  proprietary corpus isn't actionable by `swiftlang/swift` maintainers. Revisit if a large, public
  corpus that reproduces it is ever found, or if the scale/state factor gets isolated.
- **Not suppressed**: the diagnostic is written directly by `sourcekitd` (dlopen'd in-process) to
  this process's own stderr, bypassing every layer of this project's own error handling -- the only
  way to intercept it would be redirecting the raw fd 2 (`dup2`) around every `cursorInfo` call. Real
  risk under this project's own concurrent oracle workers (multiple threads/processes sharing one
  process-wide fd 2) outweighs a purely cosmetic, already-proven-harmless annoyance. Revisit only if
  a safe, non-racy interception method is found, or if the noise volume becomes large enough to
  matter in practice (currently ~0.1% of real oracle queries on the largest real corpus this project
  has).

## Revisited (2026-08-30): a real attempt at fd-2 interception, and why it's still not viable

Re-examined the "not suppressed" reasoning above against real source, not just restated it.
**Refinement, confirmed by reading every real call site**: every path that reaches `sourcekitd` in
this project (`ExternalIsolationBackfill.query`, `LocalDeclarationLiveFallback.resolveOne`) is
driven by a plain sequential `for item in ... { await ... }` loop -- at most one `cursorinfo` round
trip is ever in flight in a given *process* at a time. `--oracle-workers N`'s own parallelism is
strictly inter-process (`withTaskGroup` spawns one real subprocess per chunk; each worker's own
`sourcekitd` runs in its own process with its own independent file descriptor table) -- a `dup2` in
one worker process cannot affect a sibling's fd 2 at all, since fd tables aren't shared across
processes here. So the specific "multiple *processes* sharing one process-wide fd 2" framing above
was imprecise: processes don't share an fd table; the only real hazard is *intra*-process
concurrency, which the sequential-dispatch invariant above rules out for every current call site.

Built a real, working implementation anyway (a `dup2`-based capture-and-filter wrapper around
`SourceKitDClient.blockingSendRequestSync`, with unit tests covering the exact call shape:
`sourcekitd`'s own real write pattern, a raw libc `write(2, ...)` from a detached background
thread). **Immediate, concrete negative result**: running the new tests via a plain `swift test`
(parallel by default locally, unlike this project's own `--no-parallel` CI) crashed the entire test
process with `SIGPIPE` (signal 13) -- two `@Test` functions, each independently redirecting the
same real, process-wide `STDERR_FILENO` at the same moment (Swift Testing's own default parallel
execution), collided. This is real, reproduced evidence for exactly the class of risk the original
"not suppressed" decision was written to avoid *before* it had a concrete failure to point to --
not a theoretical worry, a real crash on the first real attempt.

**Decision, reaffirmed with stronger evidence**: still not suppressed. Even though this project's
own current production call sites are provably sequential, a `dup2`-based interception around a
process-wide resource is exactly the kind of fix that silently breaks the moment anyone (this
project or a future contributor) adds any real concurrency near it -- a fragile invariant to build a
permanent guardrail on top of, for a purely cosmetic, already-proven-harmless annoyance. The
attempted implementation and its tests were not kept in the tree.

## Fixed (2026-08-30): remove the trigger condition itself, not the symptom

Interception was the wrong shape of fix entirely -- it treats the diagnostic as unavoidable and
tries to catch it after the fact. Going back to the root-cause paragraph above ("What it is not")
with fresh eyes: the injection is conditional, not unconditional. Read the real trigger directly
from `swiftlang/swift`'s current source:

`lib/Driver/ToolChains.cpp`:
```cpp
if (inputArgs.hasArg(options::OPT_g)) {
  auto OptArg = inputArgs.getLastArgNoClaim(options::OPT_O_Group);
  if (!OptArg || OptArg->getOption().matches(options::OPT_Onone))
    arguments.push_back("-enable-anonymous-context-mangled-names");
```

`include/swift/Option/Options.td` confirms `OPT_g` matches *only* the bare `-g` flag -- `-gnone`/
`-gline-tables-only`/`-gdwarf-types` are each their own, separate option ID (sharing `g_Group` for
help-text grouping only, not aliased to `-g`). A real Debug-configuration build (Xcode's own
default, and SwiftPM's) is exactly bare `-g` plus `-Onone`/no `-O` at all -- confirmed against this
project's own real captured fixture build logs (`Tests/Fixtures/*/.build/debug.yaml`), matching the
trigger condition precisely.

**The fix**: `CompilerArgumentsSanitizing.sanitized(_:)` now also drops the literal `-g` token (and
only that literal token -- `-gnone`/`-gline-tables-only`/`-gdwarf-types` are left untouched, since
none of them match `OPT_g`) before building `key.compilerargs`. `cursorinfo`'s own semantic query
(type/USR/isolation-attribute lookup against an already-type-checked AST) has no use for debug
info at all -- debug info is generated during SILGen/IRGen, strictly after the semantic analysis
`cursorinfo` reads from, so removing `-g` cannot change what a query is able to resolve.

**Real, controlled verification against Project Iris** -- same on-disk index store, same corpus
state, two back-to-back CLI invocations differing only in this one code change (confirmed via
`git stash`, not by comparing runs taken at different times):

| | before (`-g` present) | after (`-g` stripped) |
|---|---|---|
| `-enable-anonymous-context-mangled-names` diagnostic occurrences | 52 | **0** |
| Unique call-graph edges in report | 1505 | **1515 (+10)** |
| `unspecifiedIsolation` | 233 | **234 (+1)** |
| `highRiskBoundaries` | 1462 | 1462 (unchanged) |

**A real bonus found, not just noise removed**: the 10 new edges are not noise-related duplicates --
they're genuinely new report entries, all sharing one previously-entirely-absent calleeUSR
(`os.OSLogInterpolation.appendInterpolation(_:align:privacy:)`, matching this doc's own "What
triggers it" list above), now correctly surfaced as `isUnknown: true` (`calleeIsolation:
"unspecified"`) rather than being missing from the report altogether. Traced to
`AnalysisReportBuilder.swift`'s own edge-crossing gate (`guard declaredCallerIsolation !=
calleeIsolation || callerIsolation != calleeIsolation else { return nil }`): an edge is excluded
from the report entirely -- not just left unflagged -- whenever caller and callee isolation happen
to be equal, including the degenerate case where *both* sides are `.unspecified` because neither
ever resolved. The callee's own isolation stays `.unspecified` in both the before and after run
(confirmed directly in the JSON output; `os` is not one of `BulkSymbolGraphExtractor.defaultModules`,
so it was never going to resolve via the bulk cache either way) -- so for these 10 edges to newly
pass the crossing gate, the *caller*'s own isolation (`ConsoleErrorReporter`'s methods, a
project-local declaration) must have resolved successfully only in the "after" run. This points at
the same root cause reaching further than the one exact hover position originally measured: building
a file's AST for *any* live query targeting a declaration in that file appears able to fail once
that file also contains one of the three known trigger call shapes, not only when the query
literally hovers the trigger position itself -- consistent with the original investigation's own
unexplained "something about scale/accumulated state" note above. **Not independently re-confirmed
with dedicated instrumentation on the caller's own resolution path** (would require a further,
separate live-fallback-specific repro to prove beyond the edge-count evidence above) -- reported as
a well-evidenced but not fully step-by-step-traced mechanism, not asserted as fully proven.

**Verification**: `swift test` 581/581 passing (2 new unit tests added:
`dropsDebugInfoFlagThatTriggersSourcekitdsBuggyReinjection`,
`keepsOtherDebugInfoVariantsThatDoNotTriggerReinjection`,
`Tests/SourceKitDIntegrationTests/CompilerArgumentsSanitizingTests.swift`).
