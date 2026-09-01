# Investigation: `-external-plugin-path`/`-plugin-path` stderr noise (issue #135)

**Status: fixed at the root cause (2026-09-01) -- the real defect was in this project's own
`CompilerArgumentsSanitizing.sanitized(_:)`, not in `sourcekitd`.** A blanket `-external-plugin-path`
strip was tried first, verified as "zero regression," and shipped as a working assumption while the
mechanism was chased down further -- that assumption turned out to be wrong (see "The blanket strip
was itself hiding a real discrepancy" below), and is replaced entirely by the real fix here.

## Symptom

Immediately after #133 (stripping `-g` to fix issue #120's stderr noise), a real run against Project
Iris started flooding stderr with two new shapes, both from `fileContentsForFilesInCompilerInvocation`/
`getBufferStamp` -- `sourcekitd`'s own internal AST-staleness bookkeeping, not part of real
compilation:

```
sourcekit: [1:getBufferStamp:...] failed to stat file: <SDK>/usr/lib/swift/host/plugins#<SDK>/usr/bin/swift-plugin-server (No such file or directory)
sourcekit: [1:fileContentsForFilesInCompilerInvocation:...] failed getting file contents for <toolchain>/usr/lib/swift/host/plugins/testing: error opening input file '...' (Is a directory)
```

6269-6921 occurrences per full Project Iris run, plus a real, measurable per-query slowdown from the
repeated failed reads.

## Why only after #133, not before

Real A/B on the exact same corpus, binaries built from the commit right before #133 (`b582aae`) vs.
after:

| | before #133 (`-g` present) | after #133 (`-g` stripped) |
|---|---|---|
| plugin-path stderr occurrences | **0** | 6269-6921 |
| `crossActorBoundaries` | 1537 | 1547 |

The plugin-path defaults were always being computed by the real Swift driver (confirmed below) --
`-g`'s presence had been incidentally preventing them from ever being misread, not preventing them
from being computed. Fixing #120 let the pipeline reach a second, previously-unreached defect.

## Two visibly different failure shapes, initially treated as one bug

- **SDK-relative `-external-plugin-path <SDK>/usr/lib/swift/host/plugins#<SDK>/usr/bin/swift-plugin-server`**,
  on files with no explicit plugin flag of their own. Real, unconditional driver logic
  (`lib/Driver/DarwinToolChains.cpp`, `toolchains::Darwin::addPlatformSpecificPluginFrontendArgs`)
  always emits this whenever `-sdk` is non-empty, with no existence check and no "toolchain vs. SDK"
  gating. Confirmed via `ls` that no SDK ships a `host/plugins` subtree -- this default has never
  pointed at a real directory for a simulator SDK.
- **`-plugin-path <toolchain>/usr/lib/swift/host/plugins/testing`**, a real, correct, *existing*
  directory, on Swift Testing target files -- put there by the real build system itself, not
  computed by `sourcekitd`.

Both errors come from the same `getFileContent` call inside `fileContentsForFilesInCompilerInvocation`,
which can't tell "this value is a directory to search" (`-plugin-path`) or "this value is a
`<dir>#<executable>` compound" (`-external-plugin-path`) from "this value is a single file to read."

## First attempt: supply a correct default -- empirically falsified

Tried the same shape of fix that worked for #120: pre-empt `sourcekitd`'s broken SDK-relative
default by supplying our own, real, `ls`-verified toolchain-relative `-external-plugin-path` value
(`DefaultExternalPluginPath.resolve`, via `xcrun --find swift`). Real before/after Project Iris run:
**identical error count**, with the error text merely renamed to the toolchain-relative path
supplied instead of the SDK-relative one `sourcekitd` computed on its own. This proved the bug isn't
about *which* value is used -- confirmed independently a second way later (see below): omitting the
flag entirely produces the same ~5650-6300-occurrence volume as supplying a value does. Reverted;
this whole avenue was a dead end.

## Second attempt: blanket-strip both flags -- worked, but for the wrong reason

Stripped `-plugin-path`/`-external-plugin-path` (with their values) in `sanitized(_:)`, the same way
`-g` is stripped. Real Project Iris run: **0 stderr occurrences**, and
`crossActorBoundaries`/`highRiskBoundaries`/`unspecifiedIsolation` unchanged from the
already-established post-#133 baseline (1547/1462/233) -- verified, shipped as the working fix, and
the mechanism investigation continued in parallel per explicit instruction ("Продолжай копать issue
135").

## Finding the real mechanism -- direct `lldb`, not further guessing

The user pushed back on reasoning from source reading alone ("Нельзя прочитать код?"/"найди точный
механизм") once static analysis stalled. The real shipped `sourcekitdInProc` library (`/Applications/
Xcode-26.4.0.app/.../sourcekitdInProc.framework/.../sourcekitdInProc`, 169MB) retains full C++ symbol
tables -- no Swift-from-source build was ever needed (checked and ruled out early: only ~11GB free
disk, need 70-120GB for a debug/RelWithDebInfo build). A tiny standalone executable target
(`TEMPLLDBDebugRepro`, never committed) replayed real, captured Project Iris arguments through
`SourceKitDClient` directly, under `lldb`, with breakpoints on real mangled symbols:

- `swift::ArgsToFrontendInputsConverter::addFile(StringRef)` -- breakpoint hit **directly on the
  plugin-path compound string**, interleaved with real `.swift` file paths from the same target,
  proving `-external-plugin-path`'s value really does get classified as a source-file input.
- `swift::CompilerInvocation::parseArgs` -- returned `false` (success) in every case tested, ruling
  out an early, fatal "unknown argument" abort as the mechanism (a plausible-looking theory from
  source reading alone, directly falsified by the debugger).
- A Python-scripted register dump of the raw `FrontendArgs` array (via `x1`/`x2`, the `ArrayRef`
  passed to `parseArgs`) showed the literal token immediately preceding `-external-plugin-path`:
  **`-Xcc`**.

## The actual root cause

`-Xcc <value>` and `-Xfrontend <value>` are real Swift idioms for forwarding a value straight to
Clang's cc1 (bypassing its driver) or straight to `swift-frontend` (bypassing driver validation),
respectively. Real Project Iris arguments (from `SwiftBuildCompilerArgumentsProvider`, not something
this project constructs) carry:

```
-Xcc -Xclang -Xcc -fretain-comments-from-system-headers
-Xfrontend -empty-abi-descriptor
```

`CompilerArgumentsSanitizing.sanitized(_:)`'s `frontendOnlyFlags` table drops
`-fretain-comments-from-system-headers` and `-empty-abi-descriptor` as bare, standalone tokens --
correct for the *other* provider shape that motivated adding them (a bare, unprefixed occurrence,
confirmed by that entry's own original comment), but wrong for this one. Dropping only the trailing
token orphans the `-Xcc`/`-Xfrontend` before it, which then greedily consumes whatever real token
comes next as its own value. With `-g` stripped (post-#133), the very next token is Apple's own
`-external-plugin-path` -- swallowed whole, leaving its *value* as an unclassified bare positional,
which `ArgsToFrontendInputsConverter::readInputFilesFromCommandLine`'s `Args.filtered(OPT_INPUT,
OPT_primary_file)` then picks up as a source file. With `-g` present (pre-#133), the orphaned `-Xcc`
instead swallows the harmless `-enable-anonymous-context-mangled-names` that `-g` triggers
immediately before this point (`lib/Driver/ToolChains.cpp`'s own insertion order), which was never
part of any real pairing -- accidentally masking the corruption without fixing it.

Confirmed the boundary of this explanation precisely, not just its shape: toggling `-g` alone (same
position, same token count, via a same-slot filler flag) does *not* reproduce the masking -- only
`-g` together with `-Onone` (the exact real trigger condition for the `-enable-anonymous-context-
mangled-names` insertion) does, and the masking effect is a side effect of *that* insertion sitting
in the right slot, not of `-g` itself.

## The real fix

`sanitized(_:)` now recognizes and removes the whole real unit when dropping a `frontendOnlyFlags`
entry, instead of just its own trailing token:

- A full `-Xcc -Xclang -Xcc <flag>` unit (all 4 tokens) -- removing only 1-3 of these tokens
  desynchronizes every *other*, untouched unit later in the same chain (Clang's own driver re-pairs
  `-Xclang` with whatever token the shifted count leaves next to it -- confirmed the hard way, a
  real, reproduced cascading `"-Xclang: unknown argument"` failure from the naive single-token-pop
  version of this fix, fixed by removing the complete 4-token unit instead).
- A `-Xfrontend <flag>` pair.

`-external-plugin-path` needs no special-casing at all once this is in place -- it was never
`sourcekitd`'s own value that was the problem. `-plugin-path` is kept as a narrower, separate,
confirmed-safe defensive strip (see below).

## The blanket strip was itself hiding a real discrepancy

Real A/B on the exact same corpus, same binary otherwise, only the `-external-plugin-path`-handling
strategy changed:

| | blanket strip (2nd attempt) | real `-Xcc`/`-Xfrontend` fix |
|---|---|---|
| `crossActorBoundaries` | 1547 | **1537** |
| `highRiskBoundaries` | 1462 | 1462 |
| `unspecifiedIsolation` | 233 | **231** |
| plugin-path stderr occurrences | 0 | 0 |

1537/1462 is *exactly* the pre-#120 (`-g` present, neither fix existed yet) baseline reported above.
Confirmed deterministic across three independent full Project Iris runs with the real fix (byte-
identical each time). The blanket strip's own "zero regression" verification had only ever compared
one corrupted-argument state against another, coincidentally-matching corrupted-argument state
(orphaned `-Xcc` swallowing the plugin path vs. swallowing nothing after the plugin flags were
removed) -- it had never been checked against the true, uncorrupted reference point until the
`-g`-present binary was built for the masking investigation. The real fix isn't just "no regression"
-- it recovers a genuine 10-edge, 2-`unspecifiedIsolation` discrepancy the blanket strip had been
silently carrying.

## `-plugin-path`'s own, separate, narrower defect

The Swift Testing `-plugin-path <toolchain>/usr/lib/swift/host/plugins/testing` case is unrelated to
`-Xcc` orphaning (confirmed: no `-Xcc` precedes it in the real captured arguments) and is reproduced
directly via the same `lldb` breakpoint on `addFile`. Real A/B with this one strip entry disabled
(everything else identical, including the `-Xcc`/`-Xfrontend` fix): zero "Is a directory"
occurrences and byte-identical `crossActorBoundaries`/`highRiskBoundaries`/`unspecifiedIsolation`
either way -- not observed at real Project Iris corpus scale in practice, only in the isolated,
manually-constructed `lldb` repro. Kept anyway in `sanitized(_:)` as a cheap, confirmed-harmless
defensive strip for the one file shape that does trigger it.

## Verification

`swift test`: 593/593 passing. Three independent full Project Iris runs with the final code: byte-
identical `crossActorBoundaries`/`highRiskBoundaries`/`unspecifiedIsolation` (1537/1462/231) and zero
plugin-path/`-Xclang`/unknown-argument stderr occurrences each time.
