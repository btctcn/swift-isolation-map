# Investigation: `-enable-anonymous-context-mangled-names` stderr noise

**Status: root-caused, not fixed, not filed upstream.** Real, reproducible, harmless to actual
results. Deliberately left unsuppressed -- see "Why not suppressed" below.

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
