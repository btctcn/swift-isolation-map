# Raw `libIndexStore` C API as a scoped alternative to `IndexStoreDB` (issue #51)

Tracks [issue #51](https://github.com/btctcn/swift-isolation-map/issues/51) and the persistent
investigation memory (`project_libindexstore_raw_api_investigation.md`, spanning multiple prior
sessions/scratchpad spikes before this document existed).

**Status: shipped. `RawIndexStoreClient` replaces `IndexStoreClient` as the project's default
index reader.** The original hypothesis (raw bypasses issue #51's own async/LMDB root cause) did
not hold up under a controlled measurement -- but the investigation surfaced a second, larger,
previously-unknown `IndexStoreDB` gap that raw genuinely fixes: for a source file compiled into
more than one target (an app plus its extensions, the exact real shape found in Project Iris),
`IndexStoreDB.symbolOccurrences(inFilePath:)` silently returns occurrences from only *one* of the
compiled variants. See Step 6 for the full, corrected record, including a real regression this
migration found and fixed in `RawIndexStoreClient` itself along the way.

## Step 1 — Hypothesis

`docs/task-indexstore-declaration-completeness.md` found `IndexStoreDB` silently drops a real
fraction of a large project's own declarations under full-project load (803 measured on Project
Iris, out of ~46895) -- traced to `IndexStoreDB`'s own async, event-driven initialization
(`startEventListening`/`OnUnitsChange`/`pollForUnitChangesAndWait`), built for `sourcekit-lsp`'s
live-editing use case, not this project's one-shot batch read. The mitigation that shipped
(`LocalDeclarationLiveFallback`, issue #51/#52) works around the symptom with a live `cursorinfo`
fallback; it does not touch the root cause.

Hypothesis: `libIndexStore`'s own raw C API (`indexstore.h`, part of the LLVM/Swift toolchain,
which `IndexStoreDB` itself is built on top of) exposes a plain synchronous, one-shot read path
with none of `IndexStoreDB`'s own async/LMDB-accelerator machinery -- and might sidestep issue
#51's root cause entirely, rather than routing around it.

## Step 2 — Spike

Three independent, escalating spikes, each confirming the previous one's finding before
proceeding, per this project's "compile every line" discipline:

**2a. Scratchpad, small scale (prior session, preserved verbatim in the persistent memory)**:
read the real, current `indexstore.h` (`swiftlang/llvm-project`, branch `next`,
`INDEXSTORE_VERSION_MINOR 16`) directly rather than trusting secondhand descriptions. Confirmed:
`indexstore_store_create` is plain synchronous, no "wait until done" concept at all -- the
async/event-listening API is a separate, opt-in subscription mechanism this project never needs to
call. A hand-written C program, linked directly against the toolchain's `libIndexStore.dylib`,
read a real hand-built fixture's full occurrence/relation graph correctly on the very first read,
immediately after `swift build` returned -- no wait, no poll. Performance measured separately:
raw reads avoid `IndexStoreDB`'s own initialization cost entirely (~60-70x faster at micro scale,
confirmed not to amortize across repeated runs against the same on-disk database).

**2b. In-repo, real fixture, byte-for-byte diff (this document, this branch)**: built
`Sources/CIndexStoreRaw` (a `dlopen`-based C shim over the raw API, mirroring `CSourceKitD`'s own
pattern -- see its own doc comment for why a shim is needed even though, unlike `sourcekitd`'s
24-byte `sourcekitd_variant_t`, none of `indexstore.h`'s own structs need one for ABI reasons) and
`RawIndexStoreClient` (a second `IndexStoreQuerying` conformer, doing one synchronous full-store
scan at `init` instead of `IndexStoreDB`'s per-query on-demand model -- see the type's own doc
comment for the full architecture). Diffed it against the real `IndexStoreClient` on
`Tests/Fixtures/cross-file-witness` (chosen because it already exercises every shape the 7-method
protocol needs: direct inheritance, extension-of-an-external-type, nested/generic-type extensions,
cross-file conformance, protocol conformance via extension, a stored-property accessor, and a real
call graph) -- **passed on the first real run, all 7 methods, byte-for-byte identical results**.

**2c. Real scale (Project Iris, the scale issue #51 actually manifested at)**: in progress -- see
Step 6.

## Step 3 — Documentation (this document)

## Step 4 — Code

- `Sources/CIndexStoreRaw/`: `include/CIndexStoreRaw.h` + `shim.c`. `dlopen`/`dlsym`-resolves 24
  real `indexstore_*` symbols (store/unit/record lifecycle, occurrence/relation enumeration,
  symbol accessors), exposing matching `indexstore_shim_*` forwarding functions. Symbol role bit
  values declared as `static const` typed constants, not `#define` macros -- a cast-to-typedef
  macro was found to import into Swift as "unavailable: structure not supported"; a plain typed
  constant imports cleanly.
- `Sources/IndexStoreIntegration/RawIndexStoreClient.swift`: the `IndexStoreQuerying` conformer.
  One synchronous full-store scan (every unit -> its record dependencies, each carrying the real
  filepath `indexstore_occurrence_get_line_col` alone can't give -- reconstructed from the owning
  unit's dependency list, confirmed necessary in spike 2a -- -> every occurrence in each *distinct*
  record exactly once, since a record can be a dependency of more than one unit) builds four
  in-memory indices (defined symbols by file, call edges by callee, call edges by file, and two
  relation indices -- one keyed by an occurrence's own symbol, one keyed by a relation's target --
  covering all 7 `IndexStoreQuerying` methods without any further store queries).
- **Every scan callback is a top-level free function, not a closure or method** -- found
  empirically that Swift refuses to form a C function pointer from any closure that merely
  *references* a `private static func` or nested type of its own enclosing class, not only ones
  that capture local variables. All real state is threaded through the C `void *context` parameter
  via `Unmanaged`/`UnsafeMutablePointer` instead.
- `Package.swift`: new `CIndexStoreRaw` target (no external dependency, `dlopen`'d at runtime like
  `CSourceKitD`), added to `IndexStoreIntegration`'s dependencies.
- `Sources/swift-isolation-map/SwiftIsolationMap.swift`: `IndexStoreClient` replaced outright with
  `RawIndexStoreClient` at the one real construction site. No `databasePath`/LMDB accelerator file
  needed any more, so `.swift-isolation-map-index-db` is no longer created.

**A real regression found and fixed mid-migration** (Step 6 explains how it was found): the first
version of `owningPropertyUSR`/`containingExtensionUSR`/`baseTypeUSRs`'s extension-lookup step
collected relations from *any* occurrence of a symbol, regardless of that occurrence's own role.
`IndexStoreClient`'s real methods are stricter -- `db.occurrences(ofUSR: usr, roles: .definition)`
for the first two, `db.occurrences(ofUSR: usr, roles: .extendedBy)` for the third -- scoped to
occurrences whose *own* role matches, not just any occurrence that happens to carry the right
relation. `RawRelation` gained an `occurrenceRoles` field (the enclosing occurrence's own role
bitmask, stamped once when relations are collected in `processOccurrence`, since the low-level
`indexstore_shim_occurrence_relations_apply_f` callback has no visibility into it), and all three
methods now filter on it, matching `IndexStoreClient`'s exact scoping.

## Step 5 — Tests

`Tests/IndexStoreIntegrationTests/RawIndexStoreClientDiffTests.swift`: builds the real
`cross-file-witness` fixture, constructs both `IndexStoreClient` and `RawIndexStoreClient` against
the identical real index store, and diffs all 7 `IndexStoreQuerying` methods for every real defined
USR and every source file -- passed on the first run. Includes four "not vacuously passing" guard
assertions (at least one real, non-nil match on each of the four relation-based methods), so the
test can't silently pass by comparing `nil == nil` everywhere without the fixture's real shapes
ever being exercised.

## Step 6 — Documenting results

**Attempt 1: two separate CLI invocations (regular `IndexStoreClient` from an earlier run in this
session vs. `RawIndexStoreClient` via a temporary env-var hook) -- confounded, discarded.** The
aggregate numbers moved by a lot (`crossActorBoundaries` 24801 -> 15266, `highRiskBoundaries` 1167
-> 1532), which looked like a dramatic win at first. Two direct, same-moment spot checks
(`baseTypeUSRs` for `OldPurchaseReturnViewController` -- the exact class the original #51
investigation was built on -- and `callSites(inFile:)` for a 765-call-site file) both came back
byte-identical between the two clients when constructed independently right then, contradicting
the aggregate swing. Conclusion: comparing two separate CLI runs made at different times isn't a
valid A/B -- issue #49 already documents ~30% edge-level churn between separate `IndexStoreDB`
reads of *unchanged* source, independent of which client reads it. Discarded as evidence.

**Attempt 2: controlled A/B, one process, one extraction pass, both clients queried at the
identical moment against the identical on-disk store** -- methodologically sound:

| | value |
|---|---|
| Source files extracted | 2251 (47751 raw declarations before linking) |
| Raw client: full-store scan time | 5.09s |
| Raw client: `link()` time (after scan) | 0.35s |
| `IndexStoreDB` client: `link()` time (includes its own per-query cost) | 8.78s |
| Declarations after linking (both clients) | 47192 (identical) |
| Call-graph edges: raw / `IndexStoreDB` / shared | 137641 / 137133 / 119539 |
| Missing app-module declarations: raw / `IndexStoreDB` | 295 / 296 |

Read at face value, this says "no fix, and a real edge-level disagreement" -- 295 vs. 296 is noise,
not a fix for #51's own original symptom; and 18102/17594 edges (~13% each side) present in only
one client, despite every earlier single-file spot check matching perfectly. **This reading turned
out to be incomplete, not wrong** -- both anomalies had a real, findable cause, chased down next
rather than accepted as an unexplained wash.

**The ~13% edge disagreement, chased down: a genuine, larger `IndexStoreDB` gap, unrelated to
issue #51's own root cause.** The controlled A/B's per-file breakdown of "only in raw" vs. "only in
db" edges showed the same top files on both sides, in almost the same counts (e.g.
`OrderListCell.swift`: 140 vs. 142; `ProductViewController.swift`: 116 vs. 116) -- consistent with
ordinary edge-level noise (#49), not a systematic gap. **One file broke that pattern**:
`Common/MindboxNotification.swift` had 366 edges only-in-raw and essentially none only-in-db.
Investigated directly: this file's mangled USRs carry *three different module-name prefixes*
(`Ls_net_ru` -- the main app -- plus `lsboutiqueNotifications_Release` and
`lsboutiqueContentExtension_Release`, Project Iris's own two notification-extension targets, both
of which also compile this shared file). Queried both clients directly for this one file:

| | `definedSymbols` | `callSites` |
|---|---|---|
| raw | 216 (72 x 3 targets) | 627 |
| `IndexStoreDB` | 72 (main app only) | 209 |

`IndexStoreClient.definedSymbols(inFile:)`/`callSites(inFile:)` are both built on
`IndexStoreDB.symbolOccurrences(inFilePath:)` -- for a file compiled into more than one target,
that call **silently returns occurrences from only one compiled variant**, dropping the other two
entirely. This is a different, larger-in-aggregate-impact gap than issue #51's own root cause
(async/LMDB initialization) -- it's about which *targets'* data a per-file query surfaces at all,
not about staleness or timing. `RawIndexStoreClient`'s one-shot full-store scan processes every
distinct on-disk record independently (by record name, not by file path), so it has no such gap by
construction.

**Exact root cause, found by reading `indexstore-db`'s own real, checked-out source** (not
guessed): `Sources/IndexStoreDB_Index/SymbolIndex.cpp`,
`SymbolIndexImpl::foreachSymbolOccurrenceInFilePath` (lines 509-534). The outer loop enumerates
every unit containing the file via `reader.foreachUnitContainingFile(...)`; the very first
matching provider found inside that callback triggers `record->foreachSymbolOccurrence(Receiver)`
followed immediately by `return false;` (line 528) -- which returns from the *outer*
`foreachUnitContainingFile` callback itself, terminating the whole unit enumeration after exactly
one match. Every other unit that also contains this file (the file's other compiled targets) is
never visited. A one-line, precisely locatable bug: `return false` should `continue`/`return true`
so `foreachUnitContainingFile` keeps enumerating the remaining units instead of stopping after the
first.

**Minimal, standalone reproduction** (not dependent on Project Iris; saved in full, reproducible
from this document alone --
`/Users/ab/.claude/jobs/eb8b802b/tmp/indexstoredb-multitarget-repro/repro.sh` as of this writing,
reproduced here for permanence):

```sh
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET="arm64-apple-macosx13.0"
# The identical Shared.swift, compiled into two different modules, both indexed into the
# same store -- exactly what an Xcode app target + extension target sharing one file via
# multi-target membership produces.
xcrun swiftc -module-name AppModule -swift-version 6 -sdk "$SDK" -target "$TARGET" \
  -emit-module -emit-module-path AppModule.swiftmodule -parse-as-library \
  -index-store-path "$PWD/index-store" -c Shared.swift -o AppModule.o
xcrun swiftc -module-name ExtModule -swift-version 6 -sdk "$SDK" -target "$TARGET" \
  -emit-module -emit-module-path ExtModule.swiftmodule -parse-as-library \
  -index-store-path "$PWD/index-store" -c Shared.swift -o ExtModule.o
```

with `Shared.swift`:
```swift
public struct SharedThing {
    public init() {}
    public func doWork() { helper() }
    private func helper() { print("working") }
}
```

Querying the resulting store with both clients: raw finds all **8** definitions (4 `AppModule` +
4 `ExtModule`); `IndexStoreDB.symbolOccurrences(inFilePath:)` finds only **4** (`AppModule`'s own,
`ExtModule`'s entirely missing) -- the exact same signature as the real `MindboxNotification.swift`
finding, confirmed minimal and toolchain-only (no SwiftPM, no Xcode project, no third-party
dependency).

**A real regression found and fixed along the way, not just a clean win.** Migrating the real CLI
to `RawIndexStoreClient` and re-running the full test suite surfaced one genuine failure:
`CompiledDependencyCLITests`'s golden fixture expected an edge whose `calleeUSR` contains
`"setTitle"` (an ObjC-bridged `NSCell` property setter, `docs/task-compiled-dependency-isolation-
usr-granularity.md`'s own documented USR-granularity case) -- with raw, that edge's `calleeUSR` had
silently become `c:objc(cs)NSCell(py)title` (the *property*, not the setter) instead. Traced
directly (temporary debug prints in `DeclarationLinker.link()`, the same discipline as every prior
investigation this session): the edge itself was correctly found by `callSites(inFile:)` in both
clients, but `RawIndexStoreClient.owningPropertyUSR`'s first implementation collected `.accessorOf`
relations from *any* occurrence of a symbol, not just `.definition`-role occurrences the way
`IndexStoreClient`'s real `db.occurrences(ofUSR: usr, roles: .definition)` call does. `setTitle:`
has no local definition in this index (it's an external SDK symbol) -- but its one *reference*
occurrence (the call site itself) happened to also carry an `.accessorOf` relation to `title`,
which the unscoped lookup wrongly treated as authoritative. Fixed by threading each occurrence's
own role through to `RawRelation` and scoping `owningPropertyUSR`/`containingExtensionUSR`/
`baseTypeUSRs`'s extension-lookup step to match `IndexStoreClient`'s own precise role filters (see
Step 4). Full test suite (315 tests) passes after the fix.

## Step 7 — PR

**Integrated.** `RawIndexStoreClient` replaces `IndexStoreClient` as the default index reader
(`SwiftIsolationMap.swift`). The original hypothesis -- that bypassing `IndexStoreDB`'s async/LMDB
layer fixes issue #51's own declaration-loss symptom -- did not hold up (295 vs. 296 missing
declarations, statistically noise). The migration is justified by a different, real finding
instead: `IndexStoreDB.symbolOccurrences(inFilePath:)`'s silent multi-target data loss, measured at
real, non-trivial scale on Project Iris (one file alone: 72 -> 216 declarations, 209 -> 627 call
sites) and confirmed with a minimal, standalone, three-line-of-Swift reproduction independent of
this project entirely. A ~2.3x reduction in index-read wall-clock time (5.09s + 0.35s vs. 8.78s
in the controlled A/B) is a secondary, measured benefit, not the primary justification.

**Done since the above was written:**
- The full, real-corpus run against Project Iris with `RawIndexStoreClient` integrated completed.
  Line-by-line audit (high-risk edges first, then medium, then low, per the project's usual
  methodology): the *full set* of 1166 confirmed high-risk edges was byte-identical between raw
  and `IndexStoreDB` (verified via an isolated worktree build of the pre-migration client against
  the same real index store) -- the multi-target fix added real declarations and edges (mostly
  `.medium`), but **zero new or lost high-risk findings** in this specific corpus (the
  notification-extension targets' own code doesn't happen to contain any `nonisolated`-reaching-
  isolated-state shapes). A 25-edge random sample of high-risk edges and the full 25-edge low-risk
  set were manually verified against real source -- no misclassifications found. One sampled
  `.medium` edge from a previously-invisible extension-target declaration
  (`CurrentNotifications.scheduleSave`, `MindboxNotification.swift:206`) was traced to its exact
  root cause: a `DispatchQueue.main.async { }` closure (issue #33's Rule B), confirming the newly
  surfaced facts flow correctly through the existing, already-tested isolation-inference pipeline.
- Filed upstream: [swiftlang/indexstore-db#292](https://github.com/swiftlang/indexstore-db/issues/292),
  using the minimal reproduction above. Independently re-confirmed the reproduction on a second,
  separately-built environment before filing (same deterministic 4-vs-8 result).
- **Unexpected bonus finding: issue #49's own dirty-vs-clean instability disappeared with the raw
  client.** #49 found that `IndexStoreDB` (via `IndexStoreClient`) reported meaningfully different
  edge sets between a multi-day-accumulated ("dirty," 5904 unit files for 2251 source files) and a
  freshly-rebuilt ("clean," one unit file per source file) `DerivedData` -- 8588 edges only in the
  dirty report, 5736 only in the clean one, out of ~44-48k. Repeated that exact experiment
  (`xcodebuild -workspace lsboutique.xcworkspace -scheme "ls.net.ru" COMPILER_INDEX_STORE_ENABLE=YES
  build` after deleting `DerivedData` entirely, confirmed one unit file for `MainPageInteractorImpl`
  -- the same file #49's own investigation started from) with `RawIndexStoreClient` in place of
  `IndexStoreClient`: **a full multiset comparison of all 25030 edges (every field, not just the
  `(callerUSR, calleeUSR, file, line)` tuple #49's own diff used) found zero differences** between
  the dirty and clean reports. `summary` fields identical too. Posted as a follow-up comment on #49
  rather than closing it outright -- the *root cause* of `IndexStoreDB`'s own instability was never
  actually identified, only worked around by switching data sources, and only one clean rebuild was
  performed here (not #49's own repeated-build methodology) -- but it's a strong, real result worth
  recording. If accurate, this is consistent with the instability living specifically in
  `IndexStoreDB`'s LMDB-accelerator/async-initialization layer, not in the underlying on-disk index
  store's own content.

**Still open, re-checked directly (2026-08-29):** `grep -rn "swift-isolation-map-index-db"` (not
just `-l` -- the first pass here wrongly stopped at "no file mentions it," which was never actually
run against `Tests/`) found 4 real hits: `CapstoneCLITests.swift`, `DefaultIsolationCLITests.swift`,
`CompiledDependencyCLITests.swift`, `ThirdPartyGlobalActorCLITests.swift` each had a
`try? FileManager.default.removeItem(...)` pre-test cleanup step still naming
`.swift-isolation-map-index-db` alongside the real, still-current `.build`/
`.swift-isolation-map-manifest.json` (and, in one file, `.swift-isolation-map-index-store`) entries.
Harmless in practice (`try?` against a path that's never created is simply a no-op), but a real,
stale artifact name left behind after the LMDB accelerator was retired -- removed from all 4 test
files. `docs/architecture.md` also mentions `databasePath`/LMDB (lines ~125-135) but that's inside
its own explicitly-marked "original, pre-implementation specification" body, already flagged as
superseded by that document's own top-of-file "What's changed since this was written" §7 -- not
stale, correctly self-annotated already, left as-is.
