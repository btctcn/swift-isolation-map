# SwiftPM's new default `swiftbuild` backend breaks both index-store creation and Phase A compiler-argument extraction for SwiftPM projects

Tracks issue #169 and its investigation. **Analysis and spikes only — no production code changed yet.** Per the user's own instruction for this task ("analysis and spikes first"), this document exists to get a go-ahead on a specific fix direction before touching `IndexStoreLocator`/`SwiftPMCompilerArgumentsProvider`.

## Why this is bigger than issue #169's original scope

#169 was filed narrowly: `-Xswiftc -index-store-path` silently stops working. That's real, but it's a symptom of something much larger, found while investigating it: **this machine's SwiftPM (shipped with Xcode 27.0/Swift 6.4) changed its *default build system* from `native` (llbuild) to `swiftbuild`** (confirmed directly, `swift build --help`):

```
--build-system <build-system>
                        Specify the build system to use. (default: swiftbuild)
      swiftbuild        - Swift Build build engine (default)
```

`swiftbuild` is the same open-source engine (`swiftlang/swift-build`, SWBBuildService) this project already vendors and talks to directly for Xcode projects (`SwiftBuildCompilerArgumentsProvider`). Confirmed further: `swift build --help-hidden` has `--print-pif-manifest-graph` ("Write the PIF JSON sent to Swift Build as a Graphviz file") — SwiftPM's new default backend generates a PIF from `Package.swift` internally and hands it to the exact same engine `xcodebuild` uses. This explains why *two independently-discovered* symptoms below both resolve to "SwiftPM's build output now looks like Xcode's."

This affects **both** of this project's real SwiftPM-project mechanisms:
1. `IndexStoreLocator`/`SwiftIsolationMap.build`'s `--auto-build` (issue #169's original scope) — produces no index store at the path requested.
2. `SwiftPMCompilerArgumentsProvider`/`CompilerArgsLogParser.parse` (Phase A, per-file compiler arguments) — **not previously identified, found during this task's own spike** — produces **zero** compiler arguments for every file in a SwiftPM project, silently.

(2) is more severe than (1): (1) fails loudly (`storeCreateFailed`, confirmed via a real end-to-end CLI run below); (2) would fail file-by-file with `argumentsNotFound`, which several call sites already tolerate softly (`try?` loops), so the user-visible symptom could be a confusingly incomplete/empty report rather than a clear error.

## Finding 1: index-store creation (issue #169's original scope)

Repro, confirmed directly, fresh each time (`rm -rf .build` first):

```
$ swift build -Xswiftc -index-store-path -Xswiftc /tmp/sim-index-store
Build complete!
$ ls /tmp/sim-index-store
ls: /tmp/sim-index-store: No such file or directory
```

`--build-system native` (deprecated, scheduled for removal) restores the old, expected behavior:
```
$ swift build --build-system native -Xswiftc -index-store-path -Xswiftc /tmp/sim-index-store2
warning: '--build-system native' has been deprecated and will be removed in a future release...
$ ls /tmp/sim-index-store2
v5
```

**Where the data actually goes under the new default backend — a real, fixed, discoverable location, not lost:**
```
$ find .build/out -type d -iname v5
.build/out/v5
$ find .build/out/v5 -maxdepth 1
.build/out/v5/records
.build/out/v5/units
```
Identical on-disk shape (`v5/{records,units}`) to the old explicit-path store — confirming `.build/out` itself is the real index store root (the directory `indexstore_store_create` should be pointed at), just at a new fixed location. Confirmed scratch-path-relative (tested `--scratch-path /tmp/custom-scratch` → `/tmp/custom-scratch/out/v5`), not hardcoded to `.build` literally.

**A second real variable found, debug vs. release config:**

| Invocation (debug) | Index store location |
|---|---|
| `-Xswiftc -index-store-path -Xswiftc <ignored>` (what production code does) | `.build/out/v5` |
| plain default (no index-store flag at all) | `.build/out/v5` (identical — `--auto-index-store` is on by default) |
| `--enable-index-store` (SwiftPM's own top-level flag) | `.build/out/Products/Debug/index/store/v5` (**different, more nested path**) |

| Invocation (release) | Index store location |
|---|---|
| any of the three above | **none produced at all** — confirmed via `find .build -iname v5` coming up empty in all three cases |

**Not currently a production-code risk**: confirmed by grepping every `swift build` invocation in `Sources/` (`SwiftIsolationMap.swift:828`, `SwiftPMCompilerArgumentsProvider.swift:116`, `BulkExtractionEnvironmentProviding.swift:172`) — none pass `-c release`, none pass `--enable-index-store`. The relevant real-world case for this tool today is exactly the first row: `.build/out` (= `<scratch-path>/out`) is the fixed candidate to add. The release-config gap and the `--enable-index-store` divergent path are real but currently unreachable from this tool's own code — documented here so a future change doesn't reintroduce them silently.

**End-to-end confirmation on the real CLI**, not just a manual `swift build` repro:
```
$ .build/debug/swift-isolation-map /tmp/sim-fixture2/Package.swift --scheme CrossFileWitness --output json --force-reindex --verbose
...
Building project to generate a fresh index store...
[verbose] Using index store at /tmp/sim-fixture2/.build/swift-isolation-map-index-store
Linking declarations against the index store...
Error: storeCreateFailed("index store path does not exist: /tmp/sim-fixture2/.build/swift-isolation-map-index-store")
```
Loud, not silent — consistent with this project's "never silently wrong" principle, just currently broken for every SwiftPM `--auto-build`/`--force-reindex` run on this toolchain.

## Finding 2: Phase A compiler-argument extraction is completely broken (new, not in the original issue)

`SwiftPMCompilerArgumentsProvider`/`CompilerArgsLogParser.parse` expects `swift build -v`'s old llbuild-native shape: one `swift-frontend -frontend -c -primary-file <file> ...` line per compiled source file. Captured a real `swift build -v` log under the new default backend — **it contains exactly one `swift-frontend -frontend` line in the entire log, for parsing `Package.swift` itself** (the manifest), not a single one for any real project source file. Confirmed by running the actual parser against the real captured log (a throwaway `@testable import ProjectResolution` test, removed after use, same convention as every other spike in this project):

```
SCRATCH parsed entries: 0
```

**What real compiles look like instead** — the exact same driver-level shape this project already documented for *Xcode's* build system in `docs/priority-3-phase-a-compiler-args.md`:
```
    builtin-SwiftDriver -- .../swiftc -module-name CrossFileWitness -Onone @.../CrossFileWitness.SwiftFileList ... -index-store-path /private/tmp/sim-fixture2/.build/out ...
    builtin-Swift-Compilation-Requirements -- .../swiftc ... (same args)
    builtin-Swift-Compilation -- .../swiftc ... (same args)
```
One line per *target*, source files hidden behind an `@`-referenced `.SwiftFileList` response file — not one line per file. Confirmed for both debug (one `swift-frontend` manifest-parse line only) and release (`-wmo`, whole-module, same `builtin-*` shape, zero `swift-frontend -frontend` lines) configs.

**The positive finding: this project already has working code for exactly this log shape, dormant since PR #128.** `CompilerArgsLogParser.parseXcodeSwiftCompileInvocations(buildLog:)` (written for `xcodebuild -verbose`, still present, only caller — `LiveXcodeCompilerArgumentsProvider` — removed as "unreachable" in PR #128 once `SwiftBuildCompilerArgumentsProvider` became the sole Xcode path) matches `"builtin-Swift-Compilation --"` lines and extracts the `@`-referenced file list path plus arguments. Ran it directly against the real captured new-backend SwiftPM log, unmodified:

```
SCRATCH invocations found: 1
SCRATCH fileList: .../CrossFileWitness.build/Debug/CrossFileWitness-p.build/Objects-normal/arm64/CrossFileWitness.SwiftFileList
SCRATCH argCount: 88
SCRATCH fileList contents:
.../Sources/CrossFileWitness/DirectInheritance.swift
.../Sources/CrossFileWitness/ExtensionOfExternalType.swift
.../Sources/CrossFileWitness/MultiFileType.swift
.../Sources/CrossFileWitness/MultiFileTypeExtension.swift
.../Sources/CrossFileWitness/Protocol.swift
.../Sources/CrossFileWitness/SyncCoordinator.swift
.../Sources/CrossFileWitness/SyncCoordinatorRefreshable.swift
.../Sources/CrossFileWitness/main.swift
```
**Zero changes needed to the parsing function itself** — it already correctly handles this shape, because it's genuinely the same shape Xcode's build system produces (same underlying engine). The companion file-list-expansion logic (`expandFileList`/`unescaped`, the backslash-escaped-space handling from `docs/task-external-plugin-path-noise.md`'s history) and the shared-file tie-break helper (`SwiftBuildCompilerArgumentsProvider.preferredArguments`, still present and public-enough to reuse) are both still in the tree (the former only in git history, inside the deleted `LiveXcodeCompilerArgumentsProvider.swift` — recoverable via `git show 27da3b5^:Sources/ProjectResolution/XcodeBuildLogCompilerArgumentsProvider.swift`, not currently compiled into anything).

## Root cause, summarized

One sentence: **SwiftPM's new default build system (`swiftbuild`) is the same engine Xcode uses, so its build-log shape and index-store-output location converged with Xcode's — but this project's SwiftPM-specific code (`CompilerArgsLogParser.parse`'s primary-file matching, `IndexStoreLocator`'s fixed candidate-path list) still assumes the old, llbuild-native shapes.**

## Candidate fix directions

**A. Index-store discovery (Finding 1) — low risk, additive.** Add `.build/out` (i.e. `<scratch-path>/out`, but this tool never passes a custom `--scratch-path`, so concretely `packageDirectory.appendingPathComponent(".build/out")`) to `IndexStoreLocator`'s existing fixed SwiftPM candidate list, checked the same way as the existing `.build/{debug,release}/index/store` / `.build/index-build/{debug,release}/index/store` candidates (`locateSPMIndexStore`). Mirrors the established pattern exactly (this is the third time this list has needed a new real-world entry).

**B. Phase A compiler-argument extraction (Finding 2) — additive, already-validated logic, no new dependency.** Give `SwiftPMCompilerArgumentsProvider` a fallback: if `CompilerArgsLogParser.parse` (the old primary-file shape) finds zero/too-few entries from a `swift build -v` run, retry parsing the *same* log with `parseXcodeSwiftCompileInvocations` + revived `expandFileList`/`unescaped` + `preferredArguments`. Both shapes are real and need to coexist (anyone still on an older toolchain, or explicitly passing `--build-system native`, still produces the old shape) — this isn't a replacement, it's recognizing a second real shape the same way Xcode's own provider already tolerates driver-level-only logs. Already proven correct against a real captured log in this task; implementing it is mostly wiring + reviving ~40 lines of already-written, already-tested logic from git history, not new design.

**C. (Not recommended as the primary fix, flagged for discussion) `--build-system native`.** Passing this flag at the three `swift build` call sites would restore old behavior immediately with minimal code change — but SwiftPM's own CLI marks it `deprecated` and says it "will be removed in a future release." Building a load-bearing dependency on a flag already slated for removal just defers this exact investigation to whenever that happens, with less warning next time (no deprecation window once it's gone). Worth raising with the user as an option, but A+B are more durable and don't bet against the removal.

**D. (Explicitly out of scope for now, noted for the future) Unifying SwiftPM onto `SwiftBuildCompilerArgumentsProvider`'s direct-engine path entirely.** Since SwiftPM and Xcode now share one engine, in principle the *same* direct-SWBBuildService-API approach that replaced Xcode's own log-parsing path could replace SwiftPM's too — more robust than parsing any text log. Blocked on a real gap: `SwiftBuildCompilerArgumentsProvider.loadWorkspace` generates its PIF via `xcodebuild -dumpPIF`, which doesn't exist for a bare `Package.swift` (no Xcode project). `swift build --help-hidden`'s `--print-pif-manifest-graph` only writes a Graphviz rendering, not the raw PIF JSON `session.sendPIF(_:)` needs. No public SwiftPM command (`swift package dump-pif` or similar) was found. Reusing SwiftPM's own internal PIF-generation code would mean depending on its non-public-API internals (`PackageGraph`/`Build` modules), a materially bigger and riskier undertaking — not pursued this session.

## Recommendation

A + B together fully close both findings without touching anything users on older toolchains depend on (`CompilerArgsLogParser.parse`'s existing primary-file path stays exactly as-is and is tried first; `IndexStoreLocator`'s existing candidates stay exactly as-is and are tried first). Awaiting explicit go-ahead to implement, per this task's own "analysis and spikes first" instruction.

## Loose ends, not investigated further this session

- Whether Xcode-project (`xcodebuild`) index-store/compiler-args discovery is *also* affected by a parallel SWBBuildService version change on this same toolchain upgrade — `SwiftBuildCompilerArgumentsProvider` already talks to the engine directly (not log-parsing), so it's structurally less exposed, but not re-verified end-to-end against a real Xcode project on Xcode 27 this session.
- CI (`macos-latest`) doesn't yet reproduce any of this — GitHub's hosted runner image likely hasn't picked up Xcode 27 yet (see issue #169's own clarifying comment). Re-check once it does.
