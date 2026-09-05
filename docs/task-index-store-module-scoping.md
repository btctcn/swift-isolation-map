# Shared Xcode index store accumulates units from unrelated builds

Referenced from `RawIndexStoreClient`/`SwiftIsolationMap.swift` code comments for a while before
this file actually existed -- the feature shipped far enough to leave comments pointing here, but
was reverted before the doc itself was ever written. Backfilled now, covering the whole
investigation from the original hypothesis through the regression and its real fix.

**Status: shipped, but superseded as the default path.** Root cause of the regression fully
explained; the `is_system_unit`-based exemption fix verified against the real Project Iris corpus,
including the reason it beats even the unfiltered baseline (Step 6); test coverage added for both
the original allow-list behavior and the new system-unit exemption specifically. Since
`docs/task-private-derived-data-hypothesis.md` shipped, this whole filtering approach (allow-list +
`is_system_unit`) is no longer the default for Xcode projects -- a private, never-shared
DerivedData structurally avoids the cross-build pollution problem this fix filters out after the
fact, so filtering isn't needed at all in the common case. This fix's code is kept, gated behind
`--experimental-index-store-module-filter` (off by default, explicitly liable to removal), as a
narrower fallback. Step 10 below (never started) is now moot for that reason -- see its own updated
note.

## Step 1 — Hypothesis

`Index.noindex/DataStore` inside a project's DerivedData is a single directory, shared and
accumulated across *every* build Xcode has ever run against that DerivedData -- not scoped to the
scheme/target this tool is asked to analyze. Confirmed real on Project Iris: a run's own index
store carried real, indexed `lsboutiqueTests` (XCTest) units even though the analyzed scheme's own
`.xcscheme` declares an empty `<Testables>` list and a plain `xcodebuild -scheme ls.net.ru build`
never compiles that target at all -- those records were left over from some *other*, unrelated
build (Xcode GUI, CI, a different tool invocation) that happened to touch the same DerivedData at
some point. Symptom: XCTest symbols (`XCTAssertEqual`, `XCTestExpectation`, ...) dominating
`isUnknown`/`unspecified` edges in one run's report, absent in another -- looked like
`--force-reindex` non-determinism, was actually accumulated cross-build index pollution.

## Step 2 — First attempt: positive module-name allow-list (reverted)

Added `RawIndexStoreClient(storePath:allowedModuleNames:)`: filtered the raw libIndexStore scan to
only units whose own `indexstore_unit_reader_get_module_name` is in a set derived from
`LiveXcodeCompilerArgumentsProvider`'s own real `-module-name` build-log values
(`CompilerArgumentsProviding.realModuleNames()`).

Confirmed severe regression against Project Iris: `crossActorBoundaries` 1790 → 23198 (13x),
`highRiskBoundaries` 1472 → 908 (real, previously-correct high-risk detections disappeared).
Root cause traced partway at the time (ordinary UIKit SDK method calls like
`UIView.setBackgroundColor:` stopped resolving via the external-isolation oracle and fell back to
`.unspecified`) but not fully pinned down -- reverted, stashed, not deleted. All 500-505 unit
tests passed throughout; the regression only showed up on the real corpus, never in the
(mocked/fixture-based) test suite -- see
[[feedback_cross_cutting_infra_needs_real_corpus_verification]].

## Step 3 — Root cause, confirmed by direct probe (this session)

Reapplied the stash, added a temporary debug probe directly in `SwiftIsolationMap.swift` that
constructs *two* `RawIndexStoreClient`s (filtered vs. unfiltered) against the identical on-disk
store in one process, then calls `owningPropertyUSR(forUSR:)` on both for
`c:@CM@UIKit@@objc(cs)UIView(im)setBackgroundColor:` (and the CALayer / stripped-qualifier
variants). Result:

```
usr=c:@CM@UIKit@@objc(cs)UIView(im)setBackgroundColor:
  unfiltered.owningPropertyUSR = c:objc(cs)UIView(py)backgroundColor
  filtered.owningPropertyUSR   = nil
```

Same pattern for every probed USR. Mechanism: `RawIndexStoreClient.resolvedOwningPropertyUSR`
(the `.accessorOf` relation lookup that canonicalizes a synthesized setter selector like
`setBackgroundColor:` to its owning property `backgroundColor`) prefers a `.definition`-role
relation candidate over `.call`-role ones whenever a definition-role one exists
(`RawIndexStoreClient.swift:175-186`). For an SDK/Clang-module symbol, that one authoritative
definition-role occurrence is recorded when indexing **UIKit's own Clang module compile unit** --
never at an app call site that merely references it. `allowedModuleNames` is built from
`-module-name` values scraped out of the app's own real *Swift* compile invocations, which can
never contain a system framework's own module name (`UIKit`, `Foundation`, `CoreGraphics`,
`QuartzCore`, `Dispatch`, `ObjectiveC`, `CoreFoundation`, ...) -- so the filter systematically
discarded every SDK/Clang-module unit, confirmed directly via a
`SWIFT_ISOLATION_MAP_DEBUG_UNIT_MODULES` dump on the real Project Iris store: 53 UIKit units, 70
Foundation, 55 CoreGraphics, 74 ObjectiveC/Dispatch, etc., all `SKIP`. Losing the `.accessorOf`
data made `owningPropertyUSR` return `nil`, so `DeclarationLinker.canonicalized(_:)` left the raw
setter-selector USR unchanged instead of rewriting it to the property -- and neither
`BulkSymbolGraphExtractor`'s cache nor the live oracle have an answer for that raw selector USR.

Reproduced end-to-end on the real corpus this same session (fresh baseline numbers, project has
changed since the original 1790/1472 baseline): `crossActorBoundaries` 3038 → 23198,
`highRiskBoundaries` 1713 → 908 -- 23198/908 landed byte-identical to the original regression run,
confirming the bug is fully deterministic, not a fluke of build state.

## Step 4 — `indexstore_unit_reader_is_system_unit`: read from real source, not guessed

The obvious fix direction: stop conflating "not in the app's own compiled Swift module list" with
"should be filtered" -- exempt genuinely-SDK/Clang-module units from the allow-list, while still
filtering out other first-party targets from unrelated builds (the original, still-real
`lsboutiqueTests` pollution case).

First pass at this (same session) inferred a candidate signal, `indexstore_unit_reader_is_system_unit`,
by pattern-matching its likely signature against sibling functions (`is_module_unit`,
`is_debug_compilation`, `has_main_file`) and guessing its semantics from its name alone, after
confirming only that the symbol is exported by the real `libIndexStore.dylib`
(`nm -gU .../libIndexStore.dylib | grep is_system_unit`). Correctly challenged as an unproven
claim -- see [[feedback_no_unproven_claims]] -- so it was actually verified, two ways:

**a) Real source, not guessed.** Fetched the real upstream header this project's own
`CIndexStoreRaw.h` already cites as its source of truth
(`swiftlang/llvm-project`, branch `next`, `clang/include/indexstore/indexstore.h`):

```c
INDEXSTORE_PUBLIC bool
indexstore_unit_reader_is_system_unit(indexstore_unit_reader_t);
```

Confirms the guessed signature exactly (`bool(indexstore_unit_reader_t)`), but the header carries
no doc comment for this one. Traced the implementation instead:
`clang/include/clang/Index/IndexUnitWriter.h`'s constructor doc comment: *"`IsSystem` true for
system module units, false otherwise"*, and the real call site that decides the value,
`clang/lib/Index/IndexingAction.cpp` (`next` branch, function that builds each unit):

```cpp
bool IsSystemUnit = UnitModule ? UnitModule->IsSystem : false;
bool IsModuleUnit = UnitModule != nullptr;
```

So the flag is **not** "this unit belongs to a framework" in general. It's true if and only if the
indexed unit is itself a compiled **Clang module** (`UnitModule != nullptr`, i.e.
`is_module_unit` is also true for it) *and* that module's own `Module::IsSystem` bit
(`clang/include/clang/Basic/Module.h`: `ModuleAttributes::IsSystem`, "Whether this is a system
module") is set -- which Clang's module-map/header-search machinery sets for a module found via a
system/framework search path (the SDK's own `System/Library/Frameworks`, `usr/include`, etc.), not
something this project computes itself. An ordinary (non-module) translation-unit compile -- every
app source file, every CocoaPod's own source file, every first-party target's own source file --
always has `UnitModule == nullptr`, hence `IsSystemUnit == false` unconditionally, *regardless* of
where that file physically lives. This is exactly the distinction needed: SDK frameworks get
compiled as Clang modules under `-fmodules`/index-while-building and are correctly `true`; every
first-party target (including `lsboutiqueTests`) is an ordinary TU compile and is correctly
`false`.

**No fixed enumeration exists (there is no "list from Apple") -- `IsSystem` is dynamically derived
per build, not a static property of a given framework.** Traced one level deeper, into where
`Module::IsSystem` itself gets set: `clang/lib/Lex/ModuleMap.cpp:1968-1969` --
`if (MD.Attrs.IsSystem || IsSystem) ActiveModule->IsSystem = true;` -- either an explicit
`[system]` attribute written on that specific module in its own module map, or inherited from the
enclosing *module map file's own* system-ness. That file-level flag, in turn
(`clang/lib/Lex/HeaderSearch.cpp:2340/2395/2420`: `IsSystem = DL.isSystemHeaderDirectory()`), comes
from whether the module map was found via a search path directory registered as a *system* header
search path (`-isystem`/`-iframework`/the SDK's own automatically-added framework and header
paths) versus an ordinary user path (`-I`/`-F`). In a normal Xcode build this is reliable in
practice -- Apple's SDK frameworks are always resolved through the automatically-registered system
paths, third-party Pods/SPM packages never are -- matching the exact, zero-mixed-modules split
found empirically in Step 4(b). But it is not an intrinsic property of "being an Apple framework";
it is a property of *how this specific compiler invocation's search paths classified the directory
the module map was found in*.

**b) Empirical confirmation against the real Project Iris store**, independent of (a) -- added a
temporary `debugModuleSystemCounts()` diagnostic to `RawIndexStoreClient` (tallies
`is_system_unit` true/false per module, unconditionally, during the existing scan) and a
`SWIFT_ISOLATION_MAP_DEBUG_RAW_UNIT_DUMP` CLI short-circuit that runs it directly against the
already-built index store with no xcodebuild step needed. Result, 220 distinct modules:

| Module | `is_system_unit` |
|---|---|
| `UIKit`, `Foundation`, `CoreGraphics`, `QuartzCore`, `Dispatch`, `ObjectiveC`, `CoreFoundation` | 100% `true` |
| `Ls_net_ru` (the app itself), `Alamofire`, `Kingfisher`, `Mindbox`, `Moya` (pods) | 100% `false` |
| `lsboutiqueTests`, `lsboutiqueContentExtension_Release`, `lsboutiqueNotifications_Release` (other first-party targets) | 100% `false` |

Zero mixed modules -- the split is exact, on real data, matching the real-source explanation in
(a) precisely: `lsboutiqueTests` (the original motivating pollution case) is confirmed `false`,
meaning the fix below still correctly filters it, while every SDK module the regression broke is
confirmed `true`, meaning the fix exempts it.

## Step 5 — Fix implemented (not yet committed)

`RawIndexStoreClient`'s unit filter (`rawIndexStoreUnitApplier`) now allows a unit through
whenever `indexstore_shim_unit_reader_is_system_unit(unit)` is true, *or* its module name is in
`allowedModuleNames` -- previously it was allow-list membership alone. Required adding the shim
function itself (`indexstore_shim_unit_reader_is_system_unit`) to `CIndexStoreRaw.h`/`shim.c`,
mirroring the existing `get_module_name` shim.

Existing `RawIndexStoreClientModuleScopingTests` fallout (expected, not a regression): one
sanity assertion (`filtered.skippedUnitCount > 0`, commented at the time as "Swift stdlib/SDK
modules... real and legitimately skipped") now fails, because Swift-stdlib/SDK units genuinely
stop being skipped -- which is the entire point of this fix. The test's own load-bearing assertion
(the fixture module's own declarations are byte-identical between filtered and unfiltered) still
passes.

Intermediate real-corpus signal (mid-run, `--verbose` log): `Skipped 2667 index store unit(s)`,
down from 5620 before this fix -- consistent with exempting the SDK/Clang-module units (UIKit's
53, Foundation's 70, CoreGraphics' 55, etc.) while still skipping genuine pollution.

## Step 6 — Real-corpus results

All three runs against the identical, same-session, freshly-clean-built Project Iris index store
(`--oracle-workers 8`, byte-identical `.build`/toolchain):

| metric | unfiltered (no scoping at all) | broken filter (allow-list only) | fixed filter (`is_system_unit` exemption) |
|---|---:|---:|---:|
| `crossActorBoundaries` | 3038 | 23198 | **1795** |
| `highRiskBoundaries` | 1713 | 908 | **1472** |
| `unspecifiedIsolation` | 150 | 1124 | **117** |
| `mainActorTypes` | 12119 | 12106 | 12106 |
| `typesAnalyzed` | 35472 | 35471 | 35471 |
| skipped units | 0 | 5620 | 2667 |

The fixed filter clearly resolves the regression (`crossActorBoundaries`/`highRiskBoundaries`
nowhere near the broken filter's 23198/908). It also lands **better than the plain unfiltered
baseline** on every accuracy-relevant metric, not merely equal to it: fewer
`crossActorBoundaries` (1795 vs. 3038), fewer `unspecifiedIsolation` (117 vs. 150), and different
`highRiskBoundaries` (1472 vs. 1713). `skipped units` dropped from 5620 (broken filter) to 2667
(fixed filter) -- consistent with exempting the SDK/Clang-module units (UIKit's 53, Foundation's
70, CoreGraphics' 55, etc.) while still excluding genuine pollution (first-party targets from
other builds/schemes, e.g. `lsboutiqueTests`, confirmed still `is_system_unit == false` in Step 4).

**Update -- traced to concrete edges (same session, following up on the open question above).**
Diffed the two runs' own `edges` arrays by `(callerUSR, calleeUSR, file, line)`: 2999 unfiltered,
1756 fixed-filter, 1724 common with **zero** reclassification among the common set (identical
`risk`/`callerIsolation`/`calleeIsolation` for every shared edge -- the delta is a pure
appear/disappear effect, not a change in how surviving edges get classified). 1275 edges exist
only in the unfiltered run; 32 exist only in the fixed-filter run.

Of the 1275 lost edges, **1248 (98%) originate from files physically under
`/Users/ab/ios/lsboutiqueTests/`** -- e.g.:

```
callerUSR: c:@M@lsboutiqueTests@objc(cs)AboutTests(im)testGetShopContacts
calleeUSR: c:objc(cs)XCTestCase(im)expectationWithDescription:
location:  /Users/ab/ios/lsboutiqueTests/AboutTests.swift:10
```

Full mechanism, traced end to end: `SyntaxAnalysis` globs *every* `.swift` file under the project
root regardless of scheme ("Found 2226 Swift source file(s) under /Users/ab/ios"), so
`lsboutiqueTests/AboutTests.swift` gets syntactically extracted even though the `ls.net.ru` scheme
never compiles that target. `DeclarationLinker.filesToQuery` includes any file with an extracted
declaration, so `indexStore.callSites(inFile: ".../AboutTests.swift")` gets queried regardless.
**Unfiltered**: the shared store still carries real records for this file from some past, unrelated
build of `lsboutiqueTests` (Xcode GUI test run, CI, ...), so the query returns real edges --
`testGetShopContacts` genuinely calling `XCTAssertNotNil`/`expectationWithDescription:` etc. -- and
these get reported as real `crossActorBoundaries` of the `ls.net.ru` scheme, even though
`lsboutiqueTests` was never part of it. **Fixed filter**: `lsboutiqueTests`'s own unit is correctly
excluded (`is_system_unit == false`, confirmed in Step 4's per-module table; module name not in
the scheme's allow-list), so the same query finds no record at all and the edge never gets
generated. This is not a new or separate phenomenon -- it's the *exact* pollution this whole task
was originally about (Step 1), just manifesting as **1248 fabricated edges**, a far bigger effect
than the originally-observed "XCTest symbols dominate unresolved edges" framing suggested.

The remaining 27 lost edges are a distinct, smaller, **pre-existing** limitation, unrelated to the
`is_system_unit` fix: plain (non-modular) Objective-C `.m` compile units --
`Pods/PromiseKit/Sources/AnyPromise.m`, `Pods/FirebaseCrashlytics/.../FIRCrashlytics.m`,
`Pods/FirebaseCore/.../FIRHeartbeatLogger.m` -- report an **empty string** for
`indexstore_unit_reader_get_module_name` (confirmed via the debug unit log: `module= system=false
unit=AnyPromise-....o-... mainFile=.../AnyPromise.m`), since they're ordinary non-module TU
compiles with no `-fmodule-name` at all. An empty string can never match a positive module-name
allow-list, so these were *already* being skipped by the original (broken) filter too -- confirmed
by grepping that run's own debug log for the identical unit hashes. `is_system_unit` doesn't help
here (`system=false`, correctly -- these aren't Clang module compiles either), so this is an
orthogonal gap in the allow-list design itself, not something this fix introduced or fixed. Also
notable: `AnyPromise.m` has *two* separate unit hashes for the same file (`...-23AF4DHYYX80C` and
`...-3DB2D4QIVVXRF`) -- the same multi-build/multi-config accumulation pattern as Step 1's original
hypothesis, just for a pod's own `.m` file instead of a test target.

The 32 gained edges (present only in the fixed-filter run) were spot-checked and are ordinary,
plausible new edges from files whose own declarations previously failed to resolve through the
broken filter (e.g. `TimelineView.swift`'s calls into `CMSteppedProgressBar`, a `system=true`-now
Clang-module symbol) -- not investigated further, since Step 3 already fully explains why SDK-
symbol edges reappear once `is_system_unit` stops discarding their declarations.

**Conclusion: the fixed filter's numbers being better than the unfiltered baseline is now proven,
not hypothesized** -- it's the original bug (shared-store cross-build pollution), just far larger
in scope (whole fabricated edges from an uncompiled target, not only unresolved-symbol noise) than
first understood. The 27-edge non-modular-ObjC gap remains open but is small, pre-existing, and
orthogonal to this fix.

**Scope note, added after `docs/task-private-derived-data-hypothesis.md` shipped:** this 27-edge
gap is a property of the module-name-based allow-list/`is_system_unit` filter itself (an empty
module-name string can never match a positive allow-list) -- it only manifests when that filter is
active. Since that filter is now off by default (gated behind
`--experimental-index-store-module-filter`), the gap does not affect the tool's default behavior
against Xcode projects today; it only affects that narrower, explicitly-experimental fallback path.
Confirmed to reproduce identically on a private store too, per
`docs/task-private-derived-data-hypothesis.md` Step 5 -- tracked as
[issue #155](https://github.com/btctcn/swift-isolation-map/issues/155), scoped accordingly.

## Step 7 — Shipped

The throwaway `is_system_unit` diagnostics (`debugModuleSystemCounts()`,
`SWIFT_ISOLATION_MAP_DEBUG_RAW_UNIT_DUMP`, the earlier `SWIFT_ISOLATION_MAP_DEBUG_USR_PROBE`) were
stripped before committing -- they were never meant to ship, only to verify Step 4's (a) and (b).
`RawIndexStoreClientModuleScopingTests.swift`'s stale sanity assertion (Step 5) was replaced with
a new, dedicated test (`systemUnitsSurviveFilteringEvenWhenAppKitIsNotInTheAllowList`) that proves
the exemption directly: `ExtensionOfExternalType.swift`'s `extension NSView` still resolves its
real AppKit base types (`NSResponder`, ...) through `extendedTypeUSR`/`baseTypeUSRs` even when
`"AppKit"` is never in `allowedModuleNames`. Full suite (506 tests) passes.

## Step 9 — `is_system_unit`, traced to real source, not guessed (follow-up, same day)

Challenged (correctly) on whether `is_system_unit`'s signature/semantics were actually read from
source or inferred by analogy -- they were inferred first, then verified for real:

- **Signature** confirmed against the real upstream header this project already cites as its
  source of truth (`swiftlang/llvm-project`, branch `next`,
  `clang/include/indexstore/indexstore.h`): `bool indexstore_unit_reader_is_system_unit
  (indexstore_unit_reader_t)`.
- **Semantics** traced through the real implementation: `clang/lib/Index/IndexingAction.cpp` --
  `bool IsSystemUnit = UnitModule ? UnitModule->IsSystem : false;` -- true iff the unit is itself a
  compiled Clang *module* (not an ordinary TU) whose module is a system module.
- **`Module::IsSystem` itself** traced one level deeper, into `clang/lib/Lex/ModuleMap.cpp:1968-
  1969` and `clang/lib/Lex/HeaderSearch.cpp:2340/2395/2420`: set either by an explicit `[system]`
  attribute on that module, or inherited from whether its own module map file was discovered via a
  *system* header search path (`-isystem`/`-iframework`/the SDK's own automatically-registered
  paths) versus an ordinary `-I`/`-F` path. **There is no fixed enumeration ("a list from Apple")
  -- it's dynamically derived per build from search-path classification, not a static property of
  a given framework.** Reliable in practice for normal Xcode builds (SDK frameworks always resolve
  through the automatic system paths; third-party Pods/SPM packages never do), matching the exact
  zero-mixed-modules split found empirically in Step 4(b), but not an intrinsic guarantee.

Also confirmed empirically via 220-module per-module tallying (Step 4(b), unchanged) and a fast,
standalone probe reusing the already-fresh index store directly (no re-running xcodebuild).

## Step 10 — Superseded, never started: output-path-based filtering

**Not pursued.** Investigated as its own hypothesis and found not viable: Xcode's new build system
prints one driver-level line per target in its `-verbose` log (`builtin-Swift-Compilation --`), not
one per-file `swift-frontend` invocation with its own `-o <path>` -- confirmed on a real, fixed
compile line this project's own tests already capture. There is no per-file output path to parse
from the log this tool reads, so the plan below could never have worked as designed. Superseded,
not just abandoned: `docs/task-private-derived-data-hypothesis.md` solves the same underlying
problem structurally instead (a private, never-shared DerivedData can't accumulate another build's
units at all, by construction -- no filtering of any kind needed) and has since shipped as the
default for Xcode projects. Left below verbatim as the original, now-historical plan.

While researching Step 9, found the closest thing to official documentation of how the index store
itself is built: `swiftlang/indexstore-db`'s own `Sources/IndexStore/Index Store.md` (written by
the actual maintainers, not third-party). It independently confirms this task's entire premise --
*and* names a more precise alternative to both this task's filtering approaches (the original
broken module-name allow-list, and the shipped `is_system_unit` exemption):

> At the moment, the Index Store is only ever appended to and no unit or record files are ever
> removed... The Index Store may... contain stale unit files: (1) a source file was deleted from
> the project but the unit file of its last build is still present... (2) a source file used to be
> part of an iOS and watchOS target but was removed from one and then modified -- the outdated
> unit file of the last build still exists... **SourceKit-LSP solves this issue by querying the
> build system for the output paths it produces and filtering unit files based on their output
> path.**

This is exactly the `lsboutiqueTests` pollution this whole task set out to fix -- described by the
tool's own maintainers, who name the *authoritative* fix: match units by their own real **output
path** (`indexstore_unit_reader_get_output_file`, confirmed a real function in the header --
Step 9's fetched `indexstore.h` lists it alongside `get_module_name`), read from the build system's
own real invocation log, rather than by module name at all. Per the same doc's "Output path"
section, a unit's output path is what actually distinguishes two different compiled variants of
the identical source file (different target, different platform, different config) -- something
neither the broken module-name filter nor the shipped `is_system_unit` exemption can distinguish,
since both operate at the coarser module-name granularity.

**Task, not started:** work out an output-path-based filtering approach (parse each real compiler
invocation's own `-o <path>` from the same `xcodebuild -verbose` log
`LiveXcodeCompilerArgumentsProvider` already parses for `-module-name`, build a set of this run's
own real output paths, and keep a unit iff `indexstore_unit_reader_get_output_file(unit)` is in
that set -- SDK/system units still need their own separate exemption, since they're never part of
*this* run's own compiled output paths at all, so `is_system_unit` likely still needs to stay,
composed with the new check, not replaced outright). Compare against the currently-shipped
`is_system_unit`-only fix via full real-corpus (or synthetic-fixture) before/after runs -- same
methodology as Step 6: `crossActorBoundaries`/`highRiskBoundaries`/`unspecifiedIsolation`/
`skippedUnitCount`, plus an edge-level diff (Step 6's own methodology) to see whether output-path
filtering catches anything the shipped fix still misses (e.g. the 27-edge non-modular-ObjC gap
from Step 6, or duplicate-target-variant pollution the module-name filter can't distinguish at
all). Not yet scoped further than this -- treat as its own hypothesis -> spike per this project's
usual workflow, not a same-session pivot on top of the just-merged fix.
