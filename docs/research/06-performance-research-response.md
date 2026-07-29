# Research response: collapsing the external-oracle wall-clock cost

**Status: remote analysis of `task-compiled-dependency-isolation-performance.md`,
source-verified where a mechanism claim was checkable from here (`swiftlang/swift` `main`, read
2026-07-26), with pre-registered falsifiable predictions per this thread's standing discipline.
No macOS empirics were possible from this environment; every empirical claim below is labeled as
a prediction to run, not a fact to file.** Seventh document of the compiled-dependency-isolation
thread.

## 1. Reframing: the bottleneck is query *count*, and only per-module batching collapses it

The observed live throughput (600–850 cursor-info queries/min ≈ 70–100 ms/query) is not
pathological — it is roughly what a real per-query type-check costs. At ~50k distinct external
USRs, no per-query optimization reaches the target; the count itself must collapse. The task
doc's option A (discover and bulk-extract every real dependency) is therefore not one candidate
among four — it is the load-bearing fix, with C (parallelism) as its multiplier, D (persistent
cache) as its amortizer, and B (`.xcactivitylog`) as a separable concern. But option A as
written will under-deliver without two levers the doc doesn't name, and one of them is
source-verified below.

## 2. Missed lever 1 (source-verified): the `@`-extension symbol files are not optional — the motivating Kingfisher case almost certainly lives in one

`lib/SymbolGraphGen/SymbolGraphGen.cpp` + `SymbolGraph.cpp`: symbols declared in **extensions of
types from another module** are not serialized into the module's main graph — they go into
separate per-extended-module graphs (`Walker.ExtendedModuleGraphs`), written as
`<Module>@<ExtendedModule>.symbols.json` (the filename construction is literal in
`serializeSymbolGraph`: name, `@`, extended module). The task doc states these sibling files are
"currently ignored" by `BulkSymbolGraphExtractor`.

Now recall what the original motivating bug *is*: `captionImageView.kf.indicatorType` — an
**extension member that Kingfisher adds to a UIKit type**. That is precisely the shape that gets
serialized into `Kingfisher@UIKit.symbols.json` (or a sibling `@`-file), not into
`Kingfisher.symbols.json`.

**Pre-registered prediction P1:** after generalizing module discovery, the `kf` accessor's USR
will *still* miss the bulk cache — and fall through to the slow live path or `unknown` — until
the parser merges all `*.symbols.json` files in the output directory, `@`-files included. In
other words, option A implemented exactly as drafted would leave the single case this whole
feature was built for on the slow path. The fix is small (glob all `*.symbols.json`, identical
parse — same `identifier.precise` + `declarationFragments` shape, already handled by
`SymbolGraphIsolationParser`), and it should land **first**, before discovery work, because it
also enlarges what the existing hardcoded three-module cache resolves (e.g. SwiftUI's extensions
over Foundation types).

## 3. Missed lever 2: invert the pipeline so the clean-build cost is paid only when actually needed

Section 1.3's clean-build fallback and this task's oracle cost are currently paid together on
every "CI just built the app, now analyze" run. The doc treats the first as out of scope — but
the pipeline can be inverted so it usually vanishes, without touching `.xcactivitylog`:

- **Bulk extraction does not need per-file compiler arguments at all.** It needs SDK path,
  target triple, and `-F`/`-I` search paths — all of which the doc itself already obtained this
  session from read-only, no-build `xcodebuild -showBuildSettings` (`FRAMEWORK_SEARCH_PATHS`,
  `PODS_ROOT`, and friends).
- **Only the live cursor-info fallback needs the full per-file arguments** (a query type-checks
  a real project file), i.e. only the residual USRs the bulk cache fails to cover.

So: run discovery + bulk extraction from `-showBuildSettings` output first; make
`CompilerArgumentsProviding` acquisition **lazy**, triggered on the first USR that actually
falls through to the live path. If levers 1+2 do their job and the fallback set is (near-)empty,
the clean build is never run — section 1.3's cost disappears as a side effect on the common CI
path, with zero new parsing of proprietary formats. (The index store this tool reads is produced
by the app's own prior build, so nothing else in the pipeline needs the rebuild either.)

**Caveat to verify, prediction P3:** `-showBuildSettings`-derived flags must reconstruct a
search-path set equivalent to the real invocations' for *extraction* purposes (per-target
xcconfig differences exist). Acceptance: sample ~100 already-live-resolved USRs from a prior
run's cache/logs and confirm the bulk answer matches the live cursor-info answer on every one —
a bulk-vs-live parity check that also directly guards the §1.1 "fast but wrong" trap.

## 4. USR → owning module without a subprocess per symbol

The doc's open question ("map a USR to its module... likely needs a light demangling step, e.g.
via `swift demangle`") has a cheaper answer with a sharp boundary:

- **Swift USRs embed the module.** `s:` is followed by standard mangling
  (`docs/ABI/Mangling.rst`): when the next character is a digit, a length-prefixed identifier
  follows and it *is* the module name — `s:10Kingfisher…` → `Kingfisher`,
  `s:4Dep4…` → `Dep4` (both shapes already seen verbatim in this thread's own spike results).
  A ~20-line parser, no subprocess. Known-module substitutions handle the rest of the `s:`
  space: `s:s…`/known two-char type substitutions (`s:SS`, `s:Sa`, …) → `Swift`;
  `s:Sc…` → `_Concurrency`; `s:So…` → ObjC-imported, module **not** recoverable from the USR.
- **Clang USRs (`c:objc(cs)…`, `c:@…`) don't embed a module** — and don't need to: the bulk
  cache is keyed by exact USR, and an ObjC symbol appears under that same clang USR inside
  whichever extracted module's graph declares it. Membership in the merged multi-module cache
  resolves them with no mapping step.

Practical consequence: the "extract only referenced modules" refinement in option A becomes:
demangle the digit-prefixed Swift USR population into a module set, union it with a small
standard set (`Swift`, `Foundation`, `_Concurrency`, `Dispatch`, plus the current trio), and —
because `So`/`c:` USRs can't vote — union with *all* discovered search-path modules anyway.
Which collapses to the simpler rule: **extract everything discovered, in parallel** (section 5);
keep the demangler anyway as (a) a cheap pre-run metric — histogram the ~50k unresolved USRs by
prefix class (`s:<digit>` / `s:s`-stdlib / `s:So` / `c:`) *from the already-captured verbose
logs, before writing any new code* — this single number validates or refutes the whole plan's
coverage assumption (prediction P2: post-levers, live-fallback residue < 1% of today's count);
and (b) the unit-tested basis for per-module persistent-cache keying (section 6). Test the
parser against the real USR corpus already in hand, not synthetic examples.

One discovery nuance: framework directory basenames are *mostly* module names, but not always —
`ActionSheetPicker-3.0` is not a valid module identifier; the real module name lives in the
bundle's `Modules/*.swiftmodule` folder name or `module.modulemap`. Prefer those when present;
fail soft otherwise (existing pattern). C/ObjC-only pods legitimately yield nothing from
`symbolgraph-extract` — their symbols still resolve if any Swift-visible module re-exports them,
else they fall to the (now tiny) live path.

## 5. Parallelism: spend it on subprocesses, not on sourcekitd

`symbolgraph-extract` invocations are independent subprocesses — `withThrowingTaskGroup` with
core-count width. Expected order: ~40 modules, seconds each (this session measured AppKit at
~14 s as an outlier-large case), ⇒ tens of seconds wall-clock for the whole extraction pass,
plus one-time UIKit/Swift-stdlib-sized parses. Prediction P4: full `Project Iris` run lands in low
single-digit minutes end-to-end, dominated by extraction+parse, with live queries reduced to a
residue.

Option C's second half — concurrent `sourcekitd` sessions — should be explicitly
**deprioritized**: if levers 1+2 land, the live path is residual, and Phase B's own record
documents real uncertainty about `sourcekitd`'s concurrency beyond the single-threaded case
(the `pthread_mutex_t` shim fix guards shim-global state only). Spending risk budget making the
*fallback* concurrent, before knowing its post-fix size, optimizes the wrong term.

## 6. Persistent cache (option D): key by content, not by version strings

`Podfile.lock` version strings under-invalidate (local/dev pods, `:path =>` pods, post-install
patching). The invalidation key that matches this project's existing content-hash staleness
discipline and is honest by construction: **content hash of the module artifact itself** (the
`.swiftmodule` file / framework binary + interface if present) ⊕ SDK `ProductBuildVersion` (from
`SDKSettings.plist` / `xcrun --show-sdk-build-version`) ⊕ toolchain version string. The
AppKit/`NSViewController` observation in the task doc (isolation facts are SDK-version-dependent)
is exactly why nothing weaker is acceptable. Scope: per-module `USR → isolation` maps, storage
next to the existing content-hash cache infrastructure.

## 7. Option B (`.xcactivitylog`): keep it decoupled

With lever 2, the only remaining consumer of build-log parsing is the residual live path — so
`.xcactivitylog` no longer needs to solve this task's problem and can stay what the user already
preferred it to be: not adopted, reconsidered only if the lazy-args lever fails empirically. If
someday adopted, it replaces the clean-build fallback *inside* the lazy path, invisible to
everything above.

## 8. Suggested execution order for the implementing session (each step independently checkable)

0. **Measure before coding**: baseline pre-oracle runtime on `Project Iris` (§3 of the task doc asks for
   it); prefix-class histogram of the unresolved-USR population from existing verbose logs (P2's
   denominator, and the plan's cheapest possible falsification point).
1. Merge all `*.symbols.json` including `@`-files (P1 check: `kf`'s USR appears; the motivating
   case resolves from bulk).
2. Module discovery from `-showBuildSettings` search paths (+ module-name resolution per §4's
   nuance) + parallel extract-all; parity sample (P3).
3. Lazy `CompilerArgumentsProviding` (lever 2); confirm the no-live-queries run never triggers
   the clean build.
4. Timed DoD runs on both projects (`--output json --verbose`), `External oracle:` `resolved`
   meaningfully nonzero (the §1.1 trap check), wall-clock vs target (P4).
5. Persistent cache (option D) — only after 0–4 establish what remains worth amortizing.
6. `swift test -c release` full suite; decision record in `docs/priority-3-*` convention, real
   numbers before/after, remaining slow sub-cases documented as evidenced limitations.

Out-of-scope boundaries of the task doc are respected throughout: nothing above changes what
gets resolved or how correctness is established — every isolation fact still comes from the real
compiler via the same trusted parser; everything here changes only where and how many times that
compiler is asked.
