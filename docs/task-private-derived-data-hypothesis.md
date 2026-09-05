# Hypothesis: a private, composite-keyed DerivedData instead of filtering the shared one

Tracks the same underlying problem as `docs/task-index-store-module-scoping.md` (shared
`Index.noindex/DataStore` accumulating units from unrelated builds), but proposes structurally
avoiding the pollution instead of filtering it out after the fact.

**Status: shipped as the default behavior for Xcode projects, verified end-to-end against Project
Iris.** The private-DerivedData mechanism itself is not experimental or gated behind any flag --
it's simply how the tool now works for `.xcodeproj`/`.xcworkspace` containers. Only the *old*
`allowedModuleNames`/`is_system_unit` filtering it superseded stays in the code, off by default,
re-enabled by `--experimental-index-store-module-filter` (explicitly marked in its own `--help`
text as liable to change or be removed without notice) -- that flag's own name is the only
"experimental" thing left here. Three items from Step 5/7 remain genuinely open, tracked as
[issue #156](https://github.com/btctcn/swift-isolation-map/issues/156): the 32-edge unexplained
residual, a second real corpus never re-run against this specific wired-up code path, and a
once-observed, unreproduced `BUILD FAILED` on first use of a fresh private-DerivedData key.

## Step 1 — Hypothesis

Instead of scanning Xcode's own shared `~/Library/Developer/Xcode/DerivedData` (used by Xcode GUI,
CI, and every other tool on the machine) and filtering out what doesn't belong (the
`allowedModuleNames`/`is_system_unit` approach, already shipped in PR #101), pass `xcodebuild` its
own `-derivedDataPath <private-path>` pointing at a location **exclusively owned by
swift-isolation-map**, keyed by (project identity, scheme, destination, configuration), and never
deleted between runs (for incremental-build speed on repeat invocations of the same key).

If the private path is *never* written to by anything except this tool's own build of this exact
(project, scheme, destination, configuration) tuple, its `Index.noindex/DataStore` can never
contain another target/scheme's units by construction -- no filtering logic needed at all.
`RawIndexStoreClient` could go back to an unconditional full scan, and the entire
`allowedModuleNames`/`is_system_unit` machinery from PR #101 could potentially be retired.

Precedent already in this codebase: `IndexStoreLocator.explicitIndexStorePath(for:)` already does
exactly this for SwiftPM packages (`.build/swift-isolation-map-index-store`, this tool's own,
never shared with a plain `swift build`) -- this proposal extends the same pattern to Xcode
projects, which currently have no equivalent and fall back to the shared, polluted default.

## Step 2 — Critical review: where could a "private" store still get polluted?

Raised and worked through with the user before starting the spike (not assumed clean):

1. **Wrong key granularity** -- if keyed by project only (not scheme+destination+config), analyzing
   multiple schemes of the same workspace against the same private cache reintroduces cross-scheme
   pollution, just self-inflicted instead of externally inflicted. **Mitigation: composite key**
   (Step 3) -- directly solves this.
2. **The index store is append-only forever** (confirmed in `docs/task-index-store-module-scoping.md`
   Step 10, citing `indexstore-db`'s own `Index Store.md`) -- a long-lived, reused private cache
   still accumulates stale unit/record files as source changes over weeks/months (renamed files,
   deleted declarations, files moved between targets). **Mitigation: this project's existing
   `StalenessManifest`/`decideIndexAction` machinery** (Step 4) already refuses to silently proceed
   on stale data (hard stop without `--auto-build`, automatic rebuild with it) -- extending its scope
   (currently one manifest per *project*) to be keyed the same composite way as the new cache
   defuses most of this, though the *manifest's own* comparison (raw `.swift` file content hashes
   only) doesn't currently account for destination/configuration changes, which is why destination/
   configuration must live in the *directory* key, not be left to the manifest to detect.
3. **Escape hatches defeat the isolation.** The CLI's existing `--index-store-path` override, or a
   developer pointing Xcode's own "Custom Derived Data Location" preference at the same private
   path, reintroduces sharing. Not solvable by this design itself -- a documentation/UX concern
   (the private path should not be a well-known, easily-guessable location a user might reuse for
   something else).
4. **Persistent CI runners reusing disk across PRs/branches** without per-checkout isolation --
   covered by the same staleness mechanism as (2), as long as the manifest correctly flags changed
   content (it does, since it compares raw file bytes, catching any real code difference between
   branches).
5. **Same scheme, different destination/configuration** -- legitimate per `indexstore-db`'s own
   docs (a file built for two platforms gets two real, distinct units), but mixing both into one
   *analysis* would still be a smaller-scope version of the original problem if not directory-
   separated. **Mitigation: destination and configuration are directory-key components, not
   manifest-detected** (Step 3).
6. **Build-phase side effects / implicit dependencies** -- Run Script phases, code-gen tool targets,
   or Xcode's own implicit-dependency resolution pulling in more than a human expects, even in a
   freshly isolated DerivedData. **Not solved by this design** -- a property of what the scheme's
   own build graph legitimately includes, orthogonal to where the DerivedData lives.

Net assessment before the spike: (1) and (5) are fully solved by construction (composite key).
(2) and (4) are already substantially covered by this project's own existing staleness machinery,
modulo the scoping extension in Step 4. (3) is a documentation/UX concern, not an engineering gap.
(6) is a genuine, irreducible residual risk shared with *every* approach considered so far
(including the shipped `is_system_unit` fix) -- not specific to this hypothesis.

## Step 3 — Composite key design (proposed, not yet implemented)

Private cache root: `~/Library/Caches/swift-isolation-map/DerivedData/` -- macOS `Caches`
semantics (safe to delete anytime, OS/user may reclaim under pressure, clearly not Xcode's own
`~/Library/Developer/Xcode/DerivedData`, so a developer's mental model of "my real DerivedData"
is never confused with this tool's private one).

Per-key subdirectory: `<sanitized-basename>-<hash8>/<sanitized-scheme>/<sanitized-destination>/<configuration>/`
where:
- `sanitized-basename` = the `.xcworkspace`/`.xcodeproj`'s own basename (human-readable, matches
  Xcode's own `<ProjectName>-<hash>` DerivedData naming convention, for recognizability).
- `hash8` = first 8 hex chars of a SHA256 of the **`realpath`-resolved absolute path** to the
  `.xcworkspace`/`.xcodeproj` file itself -- resolved, not the raw argument path, so a symlinked
  invocation and its target don't collide *or* diverge inconsistently; two different checkouts
  (branches, worktrees) of the same repo get different real paths, hence different keys, by design
  (deliberately -- see Step 2 point 2, a different checkout is different source, must not share a
  cache with another).
- `sanitized-scheme` = the scheme name, filesystem-sanitized (schemes can contain spaces/slashes).
- `sanitized-destination` = `resolveDeterministicSimulatorDestination`'s own return value (already
  confirmed stable across runs/machines -- always the generic-platform form, e.g.
  `"generic/platform=iOS Simulator"`, never a concrete simulator UDID that would vary per run),
  filesystem-sanitized.
- `configuration` = today always the scheme's own implicit default (`xcodeIndexingBuildSettings`
  never passes `-configuration`) -- not yet a real variable dimension in this tool's own CLI, but
  reserved as its own path component now so a future `--configuration` flag doesn't require a
  cache-layout migration.

## Step 4 — Manifest scoping extension (proposed, not yet implemented)

`StalenessOrchestration.manifestFileName`/`manifestURL(for:)` currently store one
`.swift-isolation-map-manifest.json` per *project* (sibling of the `.xcworkspace`/`.xcodeproj`),
regardless of scheme/destination/configuration. Needs the same composite-key scoping as Step 3's
cache directory -- either a separate manifest file per key (e.g. living *inside* that key's own
private DerivedData subdirectory, since it's conceptually "what does this specific cache currently
vouch for," not project-wide), or a single manifest keyed internally by the same tuple. The former
is simpler and matches this design's own "the cache directory is the unit of freshness" framing
directly -- no `Codable` schema migration needed for the existing single-project-manifest shape,
just a different `manifestURL(for:)` when this mode is active.

## Step 5 — Spike results: real cost + purity + correctness, Project Iris

**Cost, real measurement (raw `xcodebuild`, not yet wired into the tool's own code path):**
- Cold first build under a fresh, never-before-used, isolated `-derivedDataPath` (same
  `xcodeIndexingBuildSettings`, same `generic/platform=iOS Simulator` destination this tool already
  uses): **4m34.5s** wall-clock (`22.38s user 13.65s system 13% cpu 4:34.50 total`). Much cheaper
  than initially feared (earlier informal recollection of "10-20+ minutes" for a clean Project Iris
  build did not hold up under an actual timed measurement -- corrected here per
  [[feedback_no_unproven_claims]], not left as an assumption).
- Second, unmodified re-run against the *same* private path (no source changes): **10.3s**
  (`2.86s user 1.37s system 40% cpu 10.321 total`) -- confirms normal Xcode incremental-build speed
  is fully retained on repeat invocations of the same key, the core cost claim behind "don't delete
  the private path between runs."

**Purity, confirmed by direct inspection, not inferred:** a standalone C probe (linked directly
against real `libIndexStore.dylib`, bypassing this project's own Swift code entirely) scanned every
unit in the resulting private store. Zero `lsboutiqueTests` units found (searched explicitly).
Store is genuinely populated with real content (confirmed real modules present: `Alamofire`,
`AppMetricaCore`, `CoreData`, `AVFoundation`, `CMSteppedProgressBar`, ...). This directly validates
the structural claim: a store that was never written to by anything but this one scheme's own
build cannot contain another scheme's units, full stop -- no heuristic required.

**Correctness, real end-to-end swift-isolation-map runs against the private store** (via the
existing `--index-store-path` override, no code changes needed for this test):

| metric | `is_system_unit`-filtered on private store | **fully unfiltered on private store** | original historical baseline (months ago) |
|---|---:|---:|---:|
| crossActorBoundaries | 1795 | **1790** | 1790 |
| highRiskBoundaries | 1472 | **1472** | 1472 |
| unspecifiedIsolation | 117 | **114** | -- |

The fully unfiltered run (the true pre-module-scoping binary, which has no `allowedModuleNames`
concept at all) landed **almost exactly on the filtered numbers, and matched the original
historical "good" baseline (1790/1472) from months before this whole investigation started, to the
edge.** This is strong, direct confirmation that a private, isolated store needs no filtering
logic at all to get the right answer -- the small residual delta (5 boundaries, 3 unspecified) was
traced to concrete edges, not left as an unexplained rounding difference:

- 27 edges present only in the *unfiltered* run trace to the same **already-documented, orthogonal
  gap** from `docs/task-index-store-module-scoping.md` Step 6: non-modular Objective-C `.m` compiles
  (`Pods/PromiseKit/Sources/AnyPromise.m`, `Pods/FirebaseCore/.../FIRHeartbeatLogger.m`,
  `Pods/FirebaseCrashlytics/.../FIRCrashlytics.m`) report an **empty string** for
  `indexstore_unit_reader_get_module_name`, so the `is_system_unit`/allow-list filter drops them
  even in an already-clean private store -- not a new problem this hypothesis introduces, the exact
  same pre-existing quirk, now confirmed to reproduce identically regardless of which store (shared
  or private) is being filtered.
- 32 edges present only in the *filtered* run were **not** traced to a specific cause this session
  (`FirebaseSessions`/`CurrentUser.swift` calling into `GDTCOREvent`/`FIRApp`/`AMAAppMetrica`
  symbols) -- flagged as an open, unexplained residual rather than guessed at, per
  [[feedback_no_unproven_claims]]. Small in magnitude (32 of ~1750 edges, ~2%), does not change the
  overall conclusion, but should be understood before fully retiring the `is_system_unit` filter in
  favor of this approach.

## Step 6 — Conclusion

**The hypothesis is strongly validated on real-corpus evidence, not just architecturally
plausible.** A private, per-(project, scheme, destination, configuration) `-derivedDataPath`,
reused (not deleted) between runs:
- Costs one 4m34s clean build per key, then ~10s per subsequent run -- a favorable, measured
  tradeoff, not a guess.
- Produces a store with **zero** cross-scheme pollution by direct inspection, not filtering.
- Produces analysis numbers that match (to the edge, for the dominant delta) both the already-
  shipped `is_system_unit` fix *and* the original, months-old "known good" baseline -- without
  needing `allowedModuleNames`/`is_system_unit`/output-path filtering logic at all.

This means the entire filtering direction explored in `docs/task-index-store-module-scoping.md`
(the shipped `is_system_unit` fix, and the abandoned output-path-filtering task in
`project_index_store_output_path_filtering_task.md`) could potentially be **superseded**, not just
complemented, by this simpler, structurally-correct-by-construction approach -- pending the real
implementation (composite key + manifest scoping, Steps 3-4) and resolving the one still-open,
small (~2%) unexplained edge-count delta above.

**Not yet done (at spike time):** actual code implementation; the 32-edge open residual; a second
real corpus (WordPress-iOS) to confirm this isn't Project-Iris-specific, matching this project's
own [[feedback_cross_cutting_infra_needs_real_corpus_verification]] standard before treating any
change to this shared infrastructure as done.

## Step 7 — Implemented (EXPERIMENTAL)

Per explicit direction: the composite key and manifest scoping are now the tool's real default
behavior for Xcode projects; the old `allowedModuleNames`/`is_system_unit` filtering stays in the
code (not removed) but is now off by default, gated behind a new flag,
`--experimental-index-store-module-filter`, whose own `--help` text explicitly says it may be
removed without notice.

**What changed:**
- `Sources/ProjectResolution/PrivateDerivedDataLocator.swift` (new) -- `PrivateDerivedData.path(for:
  scheme:destination:configuration:)`, implementing Step 3's design exactly: `~/Library/Caches/
  swift-isolation-map/DerivedData/<basename>-<hash8>/<scheme>/<destination>/<configuration>/`.
  `hash8` is the first 8 hex chars of `contentHash(of:)` (the project's own existing SHA-256 helper,
  already used for `StalenessManifest`) over the `realpath(3)`-resolved absolute container path.
- `SwiftIsolationMap.swift`'s `run()`: for `.xcodeproj`/`.xcworkspace` containers, when
  `--index-store-path` is *not* given explicitly, resolves the destination early (needed for the
  key) and computes the private path once. That path then drives: the manifest's own location
  (Step 4 -- now `<private-path>/.swift-isolation-map-manifest.json`, not project-root-sibling),
  index-store discovery (a direct existence check at the known `Index.noindex/DataStore` location,
  not `IndexStoreLocator`'s shared-DerivedData search), the compiler-arguments provider's own
  `-derivedDataPath`, and `build()`'s own `-derivedDataPath` when a rebuild is needed. SwiftPM and
  any explicit `--index-store-path` invocation are completely unaffected (`privateDerivedDataPath ==
  nil` in both cases) -- today's exact prior behavior, unchanged.
- `LiveXcodeCompilerArgumentsProvider` gained a `derivedDataPath: URL? = nil` init parameter,
  threaded into every `xcodebuild -verbose` invocation it runs, so the compiler-argument-resolution
  build and the index-store-populating build always agree on where this run's own artifacts live.
- `LiveFileSystem.write(data:to:)` now creates the parent directory chain first -- the private
  path's manifest location may not exist yet on a project's very first run there, unlike the
  pre-existing sibling-of-the-project-file location, whose parent (the project root) always already
  exists.
- `allowedModuleNames` in `SwiftIsolationMap.swift` is now `experimentalIndexStoreModuleFilter ?
  compilerArguments.realModuleNames() : nil` -- `nil` by default.

**Real-corpus verification, Project Iris, three actual end-to-end tool invocations (not simulated):**

| run | crossActorBoundaries | highRiskBoundaries | unspecifiedIsolation |
|---|---:|---:|---:|
| new default (private DD, filter off), cold | **1790** | **1472** | **114** |
| new default, same key reused (warm, no rebuild) | *(index store reused unchanged)* | | |
| `--experimental-index-store-module-filter` on the same warm store | **1795** | **1472** | **117** |

The cold, unfiltered run landed on numbers **byte-identical to the spike's own Step 5 measurement**
(1790/1472/114) -- confirms the real, wired-up implementation behaves exactly like the spike's raw-
`xcodebuild` prototype, not just similarly. The experimental-filter run also matched its own Step 5
spike number (1795/1472/117) and reused the already-built index store without rebuilding it
(`[verbose] Using index store at ...` -- staleness manifest correctly vouched for the unchanged
source tree on this repeat invocation, confirming Step 4's manifest-scoping design works in
practice, not just on paper).

**A real, once-observed, not-reproduced build failure**, worth recording rather than hiding: the
very first cold end-to-end run (before this section was written) hit a genuine `** BUILD FAILED **`
(exit 65) from the `xcodebuild` invocation inside `build()`, immediately after the *separate*
compiler-argument-resolution build (also newly pointed at the same fresh `-derivedDataPath`) had
just run. Neither a byte-for-byte manual reproduction of the exact same final `xcodebuild` command
(succeeded immediately) nor two subsequent full tool re-runs from a clean cache (both succeeded)
reproduced it. Leading, unconfirmed hypothesis: two real `xcodebuild` invocations landing in very
close succession against a *just-created* (not yet "settled") private DerivedData -- plausible
given this design now runs two separate real builds (compiler-args resolution, then the index-store
build) against the same fresh key back-to-back, a pattern the old shared-DerivedData design also
had but rarely exercised against a *brand-new* directory the way every private-key's very first use
now does. Not chased further per [[feedback_no_unproven_claims]] -- flagged as a known, unexplained
risk on first use of a new key, not asserted as understood or fixed.

**A real bug found and fixed along the way, unrelated to the above:** reproducing the failure by
hand (a read-only `-derivedDataPath`) surfaced that `ProcessFailure.description` only ever included
`standardError` -- confirmed directly that `xcodebuild`'s own actual diagnostics (`xcodebuild:
error: Could not resolve package dependencies: ...`, `** BUILD FAILED **`) print to *stdout*, so a
real build failure's error message to the user carried no useful reason at all, just the exit code.
Fixed: `ProcessFailure` now includes a tail (last 4000 characters) of `standardOutput` too, covered
by `Tests/swift-isolation-mapTests/ProcessFailureTests.swift`.

**Tests added:** `Tests/ProjectResolutionTests/PrivateDerivedDataLocatorTests.swift` (8 tests --
sanitization, hash determinism, cross-checkout hash divergence, per-scheme/per-destination key
divergence, nil-destination fallback) and `ProcessFailureTests.swift` (4 tests, above). Full suite:
518 tests, all passing.

**Not yet done:** the 32-edge open residual from Step 5 remains unexplained; a second real corpus
(WordPress-iOS) hasn't been re-run against this new code path specifically (Step 5's spike used raw
`xcodebuild`, not the wired-up tool, and only against Project Iris); the once-observed build failure
above is undiagnosed; no code review/PR yet -- implementation only, per explicit instruction to
start it, not ship it.

## Step 8 — `--index-store-path` removed entirely, not just bypassed by default

Discussed with the user after Step 7 landed. The compiler-argument-resolution build was already
made unconditionally private (Step 7's own refactor -- it no longer respects `--index-store-path`
at all, closing the gap where that flag left the *build* path pointed at Xcode's shared
DerivedData while only the *read* path was overridden). Comparing the two real `xcodebuild`
invocations line by line (compiler-args resolution vs. the index-store-populating build) showed
they're nearly identical -- same `-scheme`/`-project`/`-workspace`/`-destination`/
`-derivedDataPath`/`xcodeIndexingBuildSettings`, differing only in `-verbose` (needed to parse the
log) and an optional `clean` retry the compiler-args build alone does. Since both now always target
the same private path, the second (index-store) build is an incremental, near-free rebuild on top
of the first in the common case, not a second full build -- which removed the strongest remaining
argument for keeping `--index-store-path` as a "skip a redundant expensive rebuild" escape hatch.

**Decision: removed the flag entirely**, not just left disabled by default. Two reasons, not one:
1. The efficiency case for keeping it had already collapsed (above) once the compiler-args build
   became unconditionally private.
2. A sharper, independent correctness argument: `--index-store-path` only ever overrode *where this
   run reads its index data from*. With the compiler-args-resolution build always private, pointing
   `--index-store-path` anywhere else created a real risk of the two silently diverging --
   compiler arguments/real module names computed against one build's code state, index data read
   from a *different* store that might reflect different code, different real modules, or simply be
   stale relative to the private build. Removing the flag removes that whole class of inconsistency
   by construction, not just by convention.

**Confirmed safe to remove**: grepped every `Sources/`/`Tests/` reference -- the only real usages of
the string `indexStorePath`/`index-store-path` anywhere in the test suite are unrelated local
variables in `DeclarationLinkerTests.swift`/`ExternalIsolationBackfillTests.swift`/
`RawIndexStoreClientModuleScopingTests.swift` building SPM fixtures directly via `swift build
-Xswiftc -index-store-path -Xswiftc <path>` (SwiftPM's own raw compiler flag, unrelated to this
CLI's own option) -- zero tests exercise the CLI flag itself. Removed the `@Option var
indexStorePath: String?` declaration, the two branches that read it (`initialDiscovery` computation,
now unconditionally either the private path or `IndexStoreLocator.locate(for:)`), and updated every
comment that referenced it (including `--experimental-index-store-module-filter`'s own help text,
whose "only useful if --index-store-path points at a shared/foreign store" justification no longer
applies -- kept anyway as a narrower defensive fallback, per the user's original instruction to keep
the filtering code available behind a flag, not remove it). `README.md` and `docs/architecture.md`'s
own CLI reference sections updated to match; historical investigation docs that reference the
*different*, still-real `swift build -Xswiftc -index-store-path -Xswiftc <path>` SwiftPM compiler
flag (`docs/priority-2-phase-0-spike.md`, `docs/task-raw-indexstore-spike.md`, etc.) were left alone
-- accurate, unrelated. Full suite re-verified: 518 tests, still all passing, after removal.
