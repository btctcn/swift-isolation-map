import Foundation
import IsolationCore
import IndexStoreIntegration
import ProjectResolution
import SourceKitDIntegration

/// Result of resolving every USR referenced by the analyzed project but absent from its own
/// declarations -- external superclasses/protocols/call targets living in compiled dependencies.
struct ExternalIsolationResolution {
    /// New entries, keyed by an *external* USR (never a project-local one) -- safe to merge
    /// without ever overwriting an already-resolved project-local `DeclarationInfo`.
    let backfilledDeclarations: [String: DeclarationInfo]
    /// Existing *project-local* entries, rewritten (their `conformances[].protocolGlobalActorName`
    /// filled in) -- a deliberate overwrite of the original entry, not a new one. See "Why protocol
    /// conformance needs a different mechanism than superclass" below.
    let updatedDeclarations: [String: DeclarationInfo]
    /// USRs the oracle tried and failed to resolve (load/timeout/malformed response, or no
    /// candidate result matched at all) -- never populated for a successful match, even one with
    /// no isolation attribute (that's a real, positive `.nonisolated` fact, not unknown; see
    /// `SymbolGraphIsolationParser`'s own doc comment).
    let unknownUSRs: Set<String>
}

/// Resolves external isolation facts and prepares them for backfill into `declarations` *before*
/// `IsolationInferenceEngine` is constructed -- the engine itself stays completely unmodified
/// (docs/task-compiled-dependency-isolation.md's binding requirement), it just gets a fuller
/// `declarations` dictionary to work from, same shape it already handles for project-local facts.
///
/// Two trigger sources, not one -- verified against the real motivating bug
/// (docs/task-compiled-dependency-isolation.md section 2.1, `NewsTableCell`/`UITableViewCell`):
/// that bug is a pure inheritance-chain failure, not a call-graph-edge case at all, so an
/// edge-only trigger would never have caught it.
///
/// **Hypothesis 0 (docs/hypothesis-0-file-sorted-oracle-queries.md; full decision record in
/// docs/task-oracle-query-concurrency.md §7): a real `Project Iris` measurement showed 4780
/// AST builds against 4825 live oracle queries (99%, only 44 cache hits) -- essentially no AST
/// cache reuse, because neither trigger's own natural order (call-graph order; `Dictionary` hash
/// order) guarantees consecutive queries share a file.** Both triggers are collected into
/// `DeclarationInfo`/edge-USR work items first (single-threaded, preserving every existing dedup
/// guarantee -- see inline comments), merged into **one** combined list, and executed in **one**
/// pass sorted by (file, line, column) -- not two separately-sorted passes -- specifically so a
/// file referenced by *both* trigger kinds pays at most one AST build for the whole run, not up to
/// two. Outcomes are applied afterward in a separate, deterministic pass. This is safe (a real,
/// non-"syntactic:"-prefixed USR is a globally-unique external symbol, so claiming/sharing one
/// answer across every declaration referencing it, à la Gap B Phase I3's existing conformance-pair
/// dedup, is correct) for real USRs and conformance pairs -- but **not** for `"syntactic:<Name>"`
/// bare-name placeholders (`DeclarationLinker`'s own documented, pre-existing limitation: these can
/// collide across genuinely different real entities that merely share a name), which are therefore
/// deliberately excluded from the merged batch and resolved by a separate, sequential pass
/// (`resolveSyntacticPlaceholderNeeds`) reproducing the original code's exact interleaved
/// reuse-on-success/retry-on-failure semantics for just that narrow subset.
///
/// **Query-location selection is not "whoever claims first" for either trigger -- both are chosen
/// by an intrinsic property of the target, not by traversal order** (a real investigation this
/// project's decision record covers in full: `docs/task-oracle-query-concurrency.md`):
/// - Edge-level: the *canonical* representative call site for a given external `calleeUSR` is the
///   one with the lexicographically-smallest `(file, line, column)` among every edge referencing
///   it, computed independently of `linked.callGraph`'s own (order-unstable, confirmed by direct
///   repeated-run comparison against a real project) iteration order.
/// - Declaration-level conformance pairs: the representative declaration for a `(nominal,
///   protocol)` pair is the one whose own `ProtocolConformance.declaredInSameContextAsWitness` is
///   `true` for that protocol -- a real member physically declared inside the same syntactic
///   construct (the primary type body, or a specific `extension`) that introduces the conformance.
///   Confirmed necessary, not assumed, by two real regressions on opposite sides of a false
///   dichotomy: a type's own top-level declaration is a bad representative when the conformance is
///   declared via a *different* same-file `extension` (hovering the primary line doesn't see it),
///   but an arbitrary *member* is equally a bad representative when the conformance is declared on
///   the primary type directly and the member's own location carries unrelated attributes a live
///   query can misreport (see `SymbolGraphIsolationParser`'s doc comment). Neither "the type always
///   wins" nor "a member always wins" is correct in general; `declaredInSameContextAsWitness` is
///   the one signal, already computed by `SyntaxAnalysis.DeclarationExtractor`, that answers "is
///   hovering *this* declaration guaranteed to reflect the conformance in question." A declaration
///   lacking that signal for a pair defers it to a fallback pass that runs after every declaration
///   has had a chance to claim it as a true witness; only if none ever does may a non-witness
///   declaration (member or the type itself) claim it, matching this project's pre-hypothesis-0
///   fallback behavior for that narrower ("no eligible member at all") case. A conformance declared
///   via an empty marker extension (`extension Foo: P {}`, no members) has no witness-context
///   declaration by construction -- this is a documented, known limitation of the fallback, not a
///   bug: see `docs/task-oracle-query-concurrency.md`'s decision record.
enum ExternalIsolationBackfill {
    /// `environmentProvider`/`bulkModuleNames` drive an eager, one-time bulk pre-resolution
    /// (`BulkSymbolGraphExtractor`) of well-known SDK modules (UIKit/AppKit/SwiftUI by default)
    /// *plus* every real third-party module `environmentProvider` discovers from the project's own
    /// build configuration (CocoaPods/XCFrameworks/SwiftPM dependencies) *before* either trigger
    /// runs -- performance-motivated, not a new source of truth (see `BulkSymbolGraphExtractor`'s
    /// own doc comment). Critically, `environmentProvider` is obtainable without ever running a
    /// real build (`BulkExtractionEnvironmentProviding`'s own contract) -- unlike the original
    /// hardcoded-3-module version of this bulk phase, which got its SDK/target by calling
    /// `compilerArguments.compilerArguments(forFile:)`, the same expensive, `clean`-build-capable
    /// provider the live fallback needs. That one premature call is what made the live provider's
    /// slow path run even when the bulk cache alone would have covered everything -- removing it
    /// is the entire fix: `compilerArguments` is now only ever touched from inside `query(...)`'s
    /// live fallback, which already only runs on a genuine bulk-cache miss.
    static func resolve(
        linked: LinkedAnalysis,
        compilerArguments: CompilerArgumentsProviding,
        sourceKitD: SourceKitDQuerying,
        fileSystem: FileSystemQuerying,
        processRunning: ProcessRunning,
        environmentProvider: BulkExtractionEnvironmentProviding,
        bulkModuleNames: [String] = BulkSymbolGraphExtractor.defaultModules,
        oracleWorkerCount: Int = 1,
        oracleWorkerExecutablePath: String? = nil,
        precomputedBulkResolution: BulkSymbolGraphResolution? = nil
    ) async -> ExternalIsolationResolution {
        var backfilled: [String: DeclarationInfo] = [:]
        var updated: [String: DeclarationInfo] = [:]
        var unknown: Set<String> = []

        // Spike instrument (docs/task-process-tree-optimization.md): real wall-clock split between
        // the one-shot bulk symbol-graph phase and the live-query phases, to decide whether a
        // process-per-dependency redesign is worth its complexity or whether parallelizing the
        // (much simpler) bulk phase alone would already capture most of the win. Temporary --
        // remove once that decision is made, or promote to a permanent diagnostic like
        // `SWIFT_ISOLATION_MAP_ORACLE_STATS` if it proves broadly useful.
        let phaseTimingEnabled = ProcessInfo.processInfo.environment["SWIFT_ISOLATION_MAP_PHASE_TIMING"] != nil
        let bulkPhaseStart = phaseTimingEnabled ? Date() : nil

        // Issue #40: `SwiftIsolationMap.run()` already needs this same bulk extraction *before*
        // `DeclarationLinker.link()` runs (to fold `discoveredGlobalActorNames` into the accept-
        // list Rule A's `classify()` needs), so it computes it once, early, and passes the result
        // straight through here -- recomputing it a second time would double the one-time bulk-
        // extraction cost (a real, measured few seconds, per `BulkSymbolGraphExtractor`'s own doc
        // comment) for no benefit. `nil` (every existing caller, including every test in
        // `ExternalIsolationBackfillTests.swift`) preserves this function's original, self-
        // contained behavior exactly.
        let bulkResolution = precomputedBulkResolution ?? bulkSymbolGraphCache(
            environmentProvider: environmentProvider, processRunning: processRunning,
            fileSystem: fileSystem, moduleNames: bulkModuleNames
        )
        let bulkCache = bulkResolution.isolationByUSR
        let bulkProtocolUSRs = bulkResolution.protocolUSRs
        let bulkModuleNameByUSR = bulkResolution.moduleNameByUSR
        // Issue #40: unioned locally (not just relying on `linked.globalActorNames` already being
        // expanded) so this function's own live-oracle `GlobalActorNameValidation` calls below are
        // correct even for a caller that didn't thread `discoveredGlobalActorNames` through
        // `DeclarationLinker.link()` itself (every existing test in
        // `ExternalIsolationBackfillTests.swift`, plus any future caller) -- `linked.globalActorNames`
        // alone would silently miss a name this run's own bulk phase just discovered.
        let expandedGlobalActorNames = linked.globalActorNames.union(bulkResolution.discoveredGlobalActorNames)

        if let bulkPhaseStart {
            eprint("PHASE-TIMING bulk-symbol-graph-phase: \(Date().timeIntervalSince(bulkPhaseStart))s")
        }

        // ---- Phase 1: collect (single-threaded; every dedup guarantee below is computed before
        // any live query runs, never adjusted mid-flight the way the old interleaved loops did) ----

        let edgeWorkItems = collectEdgeLevelWorkItems(
            linked: linked, backfilled: &backfilled, bulkCache: bulkCache, bulkModuleNameByUSR: bulkModuleNameByUSR, processRunning: processRunning
        )

        var pairOutcomes: [ConformancePairKey: ConformancePairOutcome] = [:]
        var pairIndicesByDeclaration: [String: [(index: Int, key: ConformancePairKey)]] = [:]
        let (declarationPlans, placeholderNeeds) = collectDeclarationLevelWorkItems(
            linked: linked, bulkCache: bulkCache, bulkModuleNameByUSR: bulkModuleNameByUSR, bulkProtocolUSRs: bulkProtocolUSRs,
            backfilled: &backfilled, pairOutcomes: &pairOutcomes, pairIndicesByDeclaration: &pairIndicesByDeclaration
        )

        // ---- Phase 2: execute, merged into one file-sorted pass across *both* trigger kinds.
        // `targetUSR` values from the two collections are always disjoint (edge-level only ever
        // targets USRs absent from `linked.declarations`; declaration-level always targets a real
        // project-local declaration's own USR) -- one shared outcome map is safe. ----

        struct MergedWorkItem {
            let targetUSR: String
            let location: SymbolLocation
        }
        var merged: [MergedWorkItem] = edgeWorkItems.map { MergedWorkItem(targetUSR: $0.targetUSR, location: $0.location) }
        merged.append(contentsOf: declarationPlans.map { MergedWorkItem(targetUSR: $0.declarationUSR, location: $0.location) })
        // `targetUSR` is a required final tie-breaker, not cosmetic: two genuinely distinct USRs
        // legitimately share one exact (file, line, column) on real code (confirmed on `Project Iris` --
        // e.g. a synthesized property accessor and its setter counterpart at the same call-site
        // token). Sorting by location alone leaves such ties' relative order dependent on
        // `merged`'s own pre-sort order, which itself traces back to `Dictionary` iteration
        // (`collectEdgeLevelWorkItems`'s `bestLocationByUSR`) -- not guaranteed stable across
        // process launches, confirmed by a real two-run diff producing a handful of adjacent-pair
        // swaps despite the canonical-location fix (§ collectEdgeLevelWorkItems). The merged plan
        // is a pure function of file-sort only once every tie is broken by something itself
        // independent of iteration order.
        merged.sort { lhs, rhs in
            if lhs.location.file != rhs.location.file { return lhs.location.file < rhs.location.file }
            if lhs.location.line != rhs.location.line { return lhs.location.line < rhs.location.line }
            if lhs.location.column != rhs.location.column { return lhs.location.column < rhs.location.column }
            return lhs.targetUSR < rhs.targetUSR
        }

        // Permanent, opt-in acceptance instrument (docs/task-oracle-query-concurrency.md's
        // decision record): a stronger, exact signal than "the build/query ratio improved" -- the
        // number of *distinct files* among work items that actually reach `sourcekitd` (excluding
        // whatever `bulkCache` already answers for free, matching `query()`'s own bulk-cache fast
        // path) is known here, before execution, by construction. Under correct file-sorted
        // adjacency, every one of those files should be built *exactly once* for the whole run --
        // if a real `num-ast-builds` delta (see `SwiftIsolationMap.swift`'s own
        // `requestStatistics()` instrument) ever comes back higher than this count, that's not
        // "close enough," it's a concrete signal the ordering/merge is broken somewhere.
        if ProcessInfo.processInfo.environment["SWIFT_ISOLATION_MAP_ORACLE_STATS"] != nil {
            let liveFiles = Set(merged.filter { bulkCache[$0.targetUSR] == nil }.map { $0.location.file })
            eprint("distinct live-query file groups: \(liveFiles.count)")
            // docs/task-escape-hatch-and-preconcurrency-severity.md PR2 Step 2: originally added to
            // measure how much of a real corpus would get `moduleName: nil` from a bulk-cache hit
            // (`BulkSymbolGraphExtractor` only carried isolation, not module name, at the time) --
            // real measurement across 5 corpora found live-query-eligible items were the majority on
            // the flagship reference corpus (Project Iris, 54%) and never below 40%, so `bulkCache`
            // was extended with `bulkModuleNameByUSR` (trivially known by construction -- one
            // `symbolgraph-extract` call only ever covers the module it was asked to extract) rather
            // than shipping the gap. Kept as a permanent split-ratio instrument regardless -- still a
            // real, useful signal for how much of a given real corpus needs the slower live-query
            // path at all.
            let bulkResolvedCount = merged.filter { bulkCache[$0.targetUSR] != nil }.count
            eprint("merged work items: \(merged.count) total, \(bulkResolvedCount) bulk-cache-resolved, \(merged.count - bulkResolvedCount) live-query-eligible")
        }

        // Diagnostic-only, opt-in: dump the fully-planned, deterministically-sorted merged work
        // list (targetUSR + query location) and exit before any live query runs -- lets two
        // invocations be diffed against each other to directly confirm the *plan itself* is
        // byte-identical across runs, isolating whether a run-to-run discrepancy comes from
        // planning (this list) or from live query execution/parsing (everything after it). See
        // `docs/task-oracle-query-concurrency.md`'s decision record.
        if ProcessInfo.processInfo.environment["SWIFT_ISOLATION_MAP_DUMP_MERGED_PLAN"] != nil {
            for item in merged {
                print("\(item.targetUSR)\t\(item.location.file):\(item.location.line):\(item.location.column)")
            }
            exit(0)
        }

        let liveQueryPhaseStart = phaseTimingEnabled ? Date() : nil

        var outcomes: [String: QueryOutcome] = [:]
        if oracleWorkerCount > 1, let oracleWorkerExecutablePath {
            // docs/task-process-tree-optimization.md: the live-query phase is 97.6% of real oracle
            // wall-clock, and separate processes (separate `sourcekitd`, separate `ASTBuildQueue`)
            // achieve real, near-linear parallelism, confirmed by two real spikes -- one on timing,
            // one on correctness (byte-identical results to a sequential run). Only genuinely live
            // items go to workers; bulk-cache hits are already free and resolved here directly, in
            // the same file-sorted order they'd have taken in the sequential path.
            var liveItems: [MergedWorkItem] = []
            for item in merged {
                if let cached = bulkCache[item.targetUSR] {
                    outcomes[item.targetUSR] = .resolved(cached, moduleName: bulkModuleNameByUSR[item.targetUSR])
                } else {
                    liveItems.append(item)
                }
            }
            let parallelOutcomes = await OracleWorker.resolveInParallel(
                items: liveItems.map { (targetUSR: $0.targetUSR, file: $0.location.file, line: $0.location.line, column: $0.location.column) },
                workerCount: oracleWorkerCount,
                compilerArguments: compilerArguments,
                workerExecutablePath: oracleWorkerExecutablePath,
                processRunning: processRunning,
                knownGlobalActorNames: expandedGlobalActorNames
            )
            for (usr, outcome) in parallelOutcomes {
                outcomes[usr] = outcome
            }
        } else {
            for item in merged {
                outcomes[item.targetUSR] = await query(
                    targetUSR: item.targetUSR, file: item.location.file, line: item.location.line, utf8Column: item.location.column,
                    compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem, bulkCache: bulkCache,
                    bulkModuleNameByUSR: bulkModuleNameByUSR, knownGlobalActorNames: expandedGlobalActorNames
                )
            }
        }

        if let liveQueryPhaseStart {
            let liveFiles = Set(merged.filter { bulkCache[$0.targetUSR] == nil }.map { $0.location.file })
            eprint("PHASE-TIMING merged-live-query-phase: \(Date().timeIntervalSince(liveQueryPhaseStart))s (\(merged.count) items, \(liveFiles.count) distinct live-query files)")
        }

        // ---- Phase 3: apply, deterministically (dict/set content is independent of apply order). ----

        applyEdgeLevelOutcomes(edgeWorkItems, outcomes: outcomes, backfilled: &backfilled, unknown: &unknown)
        applyDeclarationLevelOutcomes(
            declarationPlans, outcomes: outcomes, linked: linked,
            backfilled: &backfilled, unknown: &unknown, pairOutcomes: &pairOutcomes
        )
        applyConformancePairOutcomes(pairIndicesByDeclaration, pairOutcomes: pairOutcomes, linked: linked, updated: &updated)

        // Deliberately sequential, run last, after `backfilled` already reflects bulk cache +
        // edge-level + real-USR declaration-level + conformance pairs -- see
        // `resolveSyntacticPlaceholderNeeds`'s own doc comment for why placeholder-typed
        // superclass/containingType needs cannot join the merged batch above.
        let placeholderPhaseStart = phaseTimingEnabled ? Date() : nil

        await resolveSyntacticPlaceholderNeeds(
            placeholderNeeds, linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
            bulkCache: bulkCache, bulkModuleNameByUSR: bulkModuleNameByUSR, knownGlobalActorNames: expandedGlobalActorNames,
            backfilled: &backfilled, unknown: &unknown
        )

        if let placeholderPhaseStart {
            eprint("PHASE-TIMING syntactic-placeholder-phase: \(Date().timeIntervalSince(placeholderPhaseStart))s (\(placeholderNeeds.count) items)")
        }

        return ExternalIsolationResolution(backfilledDeclarations: backfilled, updatedDeclarations: updated, unknownUSRs: unknown)
    }

    /// Fail-soft: if the environment can't be determined at all (an unrecognized platform, a
    /// `-showBuildSettings`/`--show-bin-path` failure), the bulk cache is simply empty and every
    /// USR falls through to the live oracle -- today's exact prior behavior when bulk didn't apply.
    private static func bulkSymbolGraphCache(
        environmentProvider: BulkExtractionEnvironmentProviding,
        processRunning: ProcessRunning,
        fileSystem: FileSystemQuerying,
        moduleNames: [String]
    ) -> BulkSymbolGraphResolution {
        guard let environment = try? environmentProvider.environment() else {
            return BulkSymbolGraphResolution(isolationByUSR: [:], protocolUSRs: [])
        }
        return BulkSymbolGraphExtractor.extractAll(
            moduleNames: moduleNames, discoveredModules: environment.discoveredModules,
            sdkPath: environment.sdkPath, target: environment.target,
            processRunning: processRunning, fileSystem: fileSystem
        )
    }

    // MARK: - Edge-level trigger (direct calls into external code, no subclassing involved)

    private struct EdgeWorkItem {
        let targetUSR: String
        let location: SymbolLocation
    }

    private static func isEarlier(_ lhs: SymbolLocation, than rhs: SymbolLocation) -> Bool {
        if lhs.file != rhs.file { return lhs.file < rhs.file }
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        return lhs.column < rhs.column
    }

    /// A call-graph edge whose callee is absent from `declarations` -- the query site for its
    /// `calleeUSR` is the **canonical representative call site**: the lexicographically-smallest
    /// `(file, line, column)` among every edge referencing that callee, computed independently of
    /// `linked.callGraph`'s own iteration order.
    ///
    /// **Why not first-encountered-in-`callGraph`-order** (this function's own behavior before
    /// this fix): confirmed by direct repeated-run comparison against a real ~2200-file project
    /// that two runs of the *identical* binary, on the *identical* input, produced different
    /// resolved isolation for the same handful of USRs -- traced to exactly this dedup picking a
    /// different representative call site each run, because `linked.callGraph`'s own construction
    /// order (ultimately, IndexStoreDB occurrence enumeration order) is not itself guaranteed
    /// stable across runs. A deterministic tie-break computed purely from each edge's own location
    /// data removes that dependency entirely: the plan is now a pure function of the *set* of
    /// edges, never of the order they were visited in. See
    /// `docs/task-oracle-query-concurrency.md`'s decision record.
    private static func collectEdgeLevelWorkItems(
        linked: LinkedAnalysis,
        backfilled: inout [String: DeclarationInfo],
        bulkCache: [String: IsolationKind],
        bulkModuleNameByUSR: [String: String],
        processRunning: ProcessRunning
    ) -> [EdgeWorkItem] {
        // Built once, project-wide -- see `MultiTargetDeclarationAliasing`'s own doc comment for
        // the real, confirmed multi-target-membership shape this closes. Only genuinely-linked
        // declarations (a real `location`, never a placeholder/backfilled entry) are indexed, so a
        // lookup miss here is never itself evidence of anything -- just "no sibling-target variant
        // of this declaration happens to already be linked."
        var declarationBySuffix: [String: DeclarationInfo] = [:]
        for declaration in linked.declarations.values where declaration.location != nil {
            guard let (_, suffix) = MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: declaration.usr) else { continue }
            declarationBySuffix[suffix] = declaration
        }

        var bestLocationByUSR: [String: SymbolLocation] = [:]
        for edge in linked.callGraph {
            let targetUSR = edge.calleeUSR
            guard linked.declarations[targetUSR] == nil, backfilled[targetUSR] == nil else { continue }
            // A project-local declaration compiled under a sibling Xcode target's own module
            // namespace (see `MultiTargetDeclarationAliasing`'s own doc comment) -- resolved
            // deterministically here by reusing the already-linked sibling variant's own, fully
            // resolved `DeclarationInfo` verbatim (same `containingTypeUSR` etc., so downstream
            // inheritance/module-default resolution works identically), zero live query needed.
            if let (_, suffix) = MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: targetUSR),
               let sibling = declarationBySuffix[suffix] {
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: sibling.name, explicitIsolation: sibling.explicitIsolation,
                    isActorType: sibling.isActorType, containingTypeUSR: sibling.containingTypeUSR,
                    isStaticMember: sibling.isStaticMember, superclassUSR: sibling.superclassUSR,
                    conformances: sibling.conformances, isEligibleForModuleDefaultIsolation: sibling.isEligibleForModuleDefaultIsolation,
                    enclosingExtensionIsolation: sibling.enclosingExtensionIsolation, isNestedType: sibling.isNestedType,
                    location: sibling.location, isImmutableStoredProperty: sibling.isImmutableStoredProperty,
                    isActorInitializer: sibling.isActorInitializer,
                    hasPreconcurrencyAttribute: sibling.hasPreconcurrencyAttribute, isNonisolatedUnsafe: sibling.isNonisolatedUnsafe,
                    moduleName: sibling.moduleName
                )
                continue
            }
            // Compiler-synthesized `RawRepresentable.rawValue`/`CaseIterable.allCases` accessors of
            // a project-local enum have no physical declaration for `DeclarationExtractor` to see
            // (see `SynthesizedEnumAccessorMatching`'s own doc comment) -- resolved deterministically
            // here, with zero live query, rather than ever generating a work item for the oracle.
            if let enumUSR = SynthesizedEnumAccessorMatching.enclosingEnumUSR(forSynthesizedAccessorUSR: targetUSR),
               linked.declarations[enumUSR] != nil {
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, explicitIsolation: .nonisolated, isEligibleForModuleDefaultIsolation: false
                )
                continue
            }
            // A top-level `@objc`-annotated enum's own `linked.declarations` entry is keyed by its
            // *Clang*-style USR, not the Swift-mangled form the check above derives (see
            // `SynthesizedEnumAccessorMatching.enclosingObjCEnumUSR`'s own doc comment) --
            // `DeclarationLinker`'s own disambiguation picks the Clang form when both exist as real
            // index-store candidates at the enum's declaration site.
            if let objcEnumUSR = SynthesizedEnumAccessorMatching.enclosingObjCEnumUSR(forSynthesizedAccessorUSR: targetUSR),
               linked.declarations[objcEnumUSR] != nil {
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, explicitIsolation: .nonisolated, isEligibleForModuleDefaultIsolation: false
                )
                continue
            }
            // `Hashable.hashValue`'s own default-witness accessor has no physical declaration either
            // (see `SynthesizedHashableAccessorMatching`'s own doc comment) -- unlike the enum
            // rawValue/allCases case above, its own isolation is not assumed; the synthesized entry
            // only carries `containingTypeUSR`, letting the unmodified `IsolationInferenceEngine`
            // apply its own already-verified whole-type inference to it, same as any real member.
            if let enclosingTypeUSR = SynthesizedHashableAccessorMatching.enclosingTypeUSR(forSynthesizedAccessorUSR: targetUSR),
               linked.declarations[enclosingTypeUSR] != nil {
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, containingTypeUSR: enclosingTypeUSR, isEligibleForModuleDefaultIsolation: false
                )
                continue
            }
            // A raw field/constant of a plain Objective-C/C struct (`CGSize.width`, `UIEdgeInsets.top`,
            // `UIControlState.disabled`, ...) has no entry in `symbolgraph-extract`'s own output at all
            // (see `ImportedStructMemberMatching`'s own doc comment), so the bulk cache never covers
            // it either -- resolved deterministically here instead: a raw imported C struct field is
            // categorically outside Swift's attribute system, never needing a live query to confirm.
            if ImportedStructMemberMatching.containerUSR(forPossibleMemberUSR: targetUSR) != nil {
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, explicitIsolation: .nonisolated, isEligibleForModuleDefaultIsolation: false
                )
                continue
            }
            // A plain, non-member imported Clang global constant (`NSCocoaErrorDomain`,
            // `kNumberCaseType`, ...) has no containing type at all, so the bulk cache -- keyed by
            // Clang USR, never the Swift-mangled global's own -- never covers it either (see
            // `ImportedTopLevelConstantMatching`'s own doc comment, including the real live-toolchain
            // probe confirming these never carry an isolation attribute).
            if ImportedTopLevelConstantMatching.isTopLevelImportedConstant(usr: targetUSR) {
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, explicitIsolation: .nonisolated, isEligibleForModuleDefaultIsolation: false
                )
                continue
            }
            // A subscript accessor's own USR (`NSDictionary["key"]`, `...cig`/`...cis`-suffixed)
            // never matches the bulk cache directly -- both the bulk symbol graph and a live hover
            // key the same subscript by its own *declaration* USR (`...cip`-suffixed) instead (see
            // `SubscriptAccessorDeclarationMatching`'s own doc comment). Once rewritten to that
            // declaration form, the bulk cache already has the real answer -- zero live query.
            if let declarationUSR = SubscriptAccessorDeclarationMatching.subscriptDeclarationUSR(forAccessorUSR: targetUSR),
               let cachedIsolation = bulkCache[declarationUSR] {
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, explicitIsolation: cachedIsolation, isEligibleForModuleDefaultIsolation: false,
                    moduleName: bulkModuleNameByUSR[declarationUSR]
                )
                continue
            }
            // A pure-Swift static member's own accessor USR (`"...vgZ"`/`"...vsZ"`) never matches
            // the bulk cache directly either -- same "accessor form vs. declaration form" gap as the
            // subscript case just above, for a static var instead (see
            // `SwiftStaticMemberAccessorDeclarationMatching`'s own doc comment).
            if let declarationUSR = SwiftStaticMemberAccessorDeclarationMatching.declarationUSR(forStaticAccessorUSR: targetUSR),
               let cachedIsolation = bulkCache[declarationUSR] {
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, explicitIsolation: cachedIsolation, isEligibleForModuleDefaultIsolation: false,
                    moduleName: bulkModuleNameByUSR[declarationUSR]
                )
                continue
            }
            // An ordinary Objective-C class's own instance property, accessed from Swift, carries
            // the call graph's own accessor-form USR (`"...vg"`/`"...vs"`), but the bulk cache keys
            // an ordinary Clang property by its selector-style form instead (see
            // `ObjCInstancePropertyAccessorMatching`'s own doc comment).
            if let declarationUSR = ObjCInstancePropertyAccessorMatching.declarationUSR(forInstancePropertyAccessorUSR: targetUSR),
               let cachedIsolation = bulkCache[declarationUSR] {
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, explicitIsolation: cachedIsolation, isEligibleForModuleDefaultIsolation: false,
                    moduleName: bulkModuleNameByUSR[declarationUSR]
                )
                continue
            }
            if let existing = bestLocationByUSR[targetUSR] {
                if isEarlier(edge.location, than: existing) {
                    bestLocationByUSR[targetUSR] = edge.location
                }
            } else {
                bestLocationByUSR[targetUSR] = edge.location
            }
        }

        // Demangle-based sibling fallback (see `DemangledSiblingMatching`'s own doc comment):
        // retries every still-unresolved, multi-target-shaped USR the plain suffix comparison above
        // missed because Swift's own mangling substitution compression made two module-qualified
        // variants' suffixes diverge -- real, confirmed on `Project Iris`
        // (`CurrentNotifications.removeOldNotifications`). Deliberately a second, separate pass
        // (not folded into the loop above): needs the *complete* set of still-pending targets
        // collected first, to batch every `swift-demangle` invocation instead of one per edge.
        let stillPendingMultiTargetUSRs = bestLocationByUSR.keys.filter {
            MultiTargetDeclarationAliasing.moduleNameAndSuffix(ofSwiftUSR: $0) != nil
        }
        if !stillPendingMultiTargetUSRs.isEmpty {
            let targetSignatures = DemangledSiblingMatching.moduleAgnosticSignatures(forSwiftUSRs: stillPendingMultiTargetUSRs, processRunning: processRunning)
            let neededBareNames = Set(targetSignatures.values.compactMap { DemangledSiblingMatching.bareMemberName(fromSignature: $0) })
            if !neededBareNames.isEmpty {
                // Narrowed via each candidate's own already-extracted `DeclarationInfo.name` (zero
                // demangling cost) before demangling *those* too -- keeps the real `swift-demangle`
                // call volume bounded to what's actually needed, not every linked declaration.
                let candidateUSRs = linked.declarations.values
                    .filter { $0.location != nil && neededBareNames.contains($0.name) }
                    .map(\.usr)
                let candidateSignatures = DemangledSiblingMatching.moduleAgnosticSignatures(forSwiftUSRs: candidateUSRs, processRunning: processRunning)
                var candidateUSRsBySignature: [String: [String]] = [:]
                for (usr, signature) in candidateSignatures {
                    candidateUSRsBySignature[signature, default: []].append(usr)
                }
                for targetUSR in stillPendingMultiTargetUSRs {
                    // Exactly one candidate must share this signature -- same "never guess" rule as
                    // `disambiguate`/`MultiTargetDeclarationAliasing` itself: two genuinely different
                    // real declarations coincidentally sharing a module-agnostic signature (e.g. the
                    // same bare-name-collision shape `docs/task-syntactic-placeholder-name-collision.md`
                    // fixed) must never be guessed between.
                    guard let signature = targetSignatures[targetUSR],
                          let matchingUSRs = candidateUSRsBySignature[signature], matchingUSRs.count == 1,
                          let sibling = linked.declarations[matchingUSRs[0]] else {
                        continue
                    }
                    backfilled[targetUSR] = DeclarationInfo(
                        usr: targetUSR, name: sibling.name, explicitIsolation: sibling.explicitIsolation,
                        isActorType: sibling.isActorType, containingTypeUSR: sibling.containingTypeUSR,
                        isStaticMember: sibling.isStaticMember, superclassUSR: sibling.superclassUSR,
                        conformances: sibling.conformances, isEligibleForModuleDefaultIsolation: sibling.isEligibleForModuleDefaultIsolation,
                        enclosingExtensionIsolation: sibling.enclosingExtensionIsolation, isNestedType: sibling.isNestedType,
                        location: sibling.location, isImmutableStoredProperty: sibling.isImmutableStoredProperty,
                        isActorInitializer: sibling.isActorInitializer,
                        hasPreconcurrencyAttribute: sibling.hasPreconcurrencyAttribute, isNonisolatedUnsafe: sibling.isNonisolatedUnsafe,
                        moduleName: sibling.moduleName
                    )
                    bestLocationByUSR.removeValue(forKey: targetUSR)
                }
            }
        }

        // Demangled raw-struct-member fallback (see `DemangledStructMemberMatching`'s own doc
        // comment): a raw C struct field whose own name uses Swift's compound/underscore-identifier
        // mangling scheme (`ImportedStructMemberMatching`'s own simple length-prefix parse can't
        // recognize) -- real, confirmed on Project Iris
        // (`_firebase_appquality_sessions_SessionInfo.firebase_installation_id`, a nanopb-generated
        // C struct field). Deliberately a separate pass for the same batching reason as the
        // demangle-based sibling fallback above.
        let candidateStructMemberUSRs = bestLocationByUSR.keys.filter {
            DemangledStructMemberMatching.isCandidateRawStructMember(targetUSR: $0)
        }
        if !candidateStructMemberUSRs.isEmpty {
            let rawDemangled = DemangledSiblingMatching.rawDemangled(forSwiftUSRs: candidateStructMemberUSRs, processRunning: processRunning)
            for targetUSR in candidateStructMemberUSRs {
                guard let demangled = rawDemangled[targetUSR], DemangledStructMemberMatching.isUnconditionallyNonisolated(rawDemangled: demangled) else {
                    continue
                }
                backfilled[targetUSR] = DeclarationInfo(
                    usr: targetUSR, name: targetUSR, explicitIsolation: .nonisolated, isEligibleForModuleDefaultIsolation: false
                )
                bestLocationByUSR.removeValue(forKey: targetUSR)
            }
        }

        return bestLocationByUSR.map { EdgeWorkItem(targetUSR: $0.key, location: $0.value) }
    }

    private static func applyEdgeLevelOutcomes(
        _ items: [EdgeWorkItem],
        outcomes: [String: QueryOutcome],
        backfilled: inout [String: DeclarationInfo],
        unknown: inout Set<String>
    ) {
        for item in items {
            switch outcomes[item.targetUSR] {
            case .resolved(let isolation, let moduleName):
                backfilled[item.targetUSR] = DeclarationInfo(
                    usr: item.targetUSR, name: item.targetUSR, explicitIsolation: isolation, isEligibleForModuleDefaultIsolation: false,
                    moduleName: moduleName
                )
            case .unknown, .none:
                unknown.insert(item.targetUSR)
            }
        }
    }

    // MARK: - Declaration-level trigger (external superclass/protocol conformance)

    /// A project-local declaration referencing an external superclass and/or protocol, with no
    /// explicit isolation of its own -- queried at *its own* declaration location (the spike's
    /// proven "hover the project's own declaration" shape: the result is the declaration's
    /// already-fully-resolved effective isolation, inheritance included). Only declarations with
    /// no explicit isolation of their own are safe representatives: if a declaration overrides its
    /// inherited isolation explicitly, its own effective isolation no longer equals what its
    /// superclass/protocol alone would contribute, so it must not be used to backfill facts about
    /// them (and, since the engine already checks `explicitIsolation` before ever consulting
    /// inheritance, such a declaration doesn't need this backfill for its own sake either).
    ///
    /// **Why protocol conformance needs a different mechanism than superclass**: confirmed by
    /// reading `IsolationInferenceEngine.resolveInheritedIsolation` directly -- the superclass
    /// branch does a real `declarations[superclassUSR]` lookup, so backfilling a new entry there
    /// is exactly what it needs. The protocol-conformance branches do **no such lookup** -- they
    /// read `conformance.protocolGlobalActorName` directly off the `ProtocolConformance` value
    /// already attached to the declaration. Backfilling `declarations[protocolUSR]` for an
    /// external protocol would therefore have zero effect; the fix has to rewrite the conforming
    /// declaration's own `conformances` array instead, mirroring `DeclarationLinker.relink`'s
    /// existing precedent for the project-local case.
    private enum ConformancePairOutcome {
        case globalActor(String)
        case notGlobalActor
        case unknown
    }

    /// Keyed the same way Phase I2's own member->nominal derivation is
    /// (`containingTypeUSR ?? usr`, `IndexStoreIntegration.DeclarationLinker`'s
    /// `resolveInheritanceViaBaseOfRelation`) -- deliberately not a second, parallel "which nominal
    /// does this declaration belong to" mechanism; the two live in different modules so can't
    /// literally share one map, but must agree on one derivation.
    private struct ConformancePairKey: Hashable {
        let nominalUSR: String
        let protocolUSR: String
    }

    private static func nominalUSR(for declaration: DeclarationInfo) -> String {
        declaration.containingTypeUSR ?? declaration.usr
    }

    /// One declaration whose own location becomes a live query, and what that query's outcome
    /// should backfill/propagate once it resolves.
    private struct DeclarationQueryPlan {
        let declarationUSR: String
        let location: SymbolLocation
        var superclassUSR: String?
        var containingTypeUSR: String?
        var pairKeys: [ConformancePairKey]
    }

    /// Gap B Phase I3's per-pair dedup (every member sharing one still-unresolved (nominal,
    /// protocol) pair only ever pays for one live oracle round trip, not one per member) already
    /// had *permanent* claim-once semantics in the original sequential code -- once one
    /// declaration's query answers a pair (resolved *or* unknown), every later declaration sharing
    /// it reuses that answer without retrying, confirmed by reading the original cache-hit filter
    /// (it removed the index from `unresolvedConformanceIndices` regardless of outcome kind). This
    /// collection function reproduces that permanent-claim behavior exactly via `claimedPairs`.
    ///
    /// **Superclass/containingType claim-once unification (the one deliberate, flagged behavior
    /// difference from pre-hypothesis-0 code):** the original sequential code did *not* have this
    /// permanent-claim property for superclass/containingType -- it only checked
    /// `backfilled[usr] == nil`, so if the first declaration sharing an external superclass got
    /// `.unknown`, a *later* declaration sharing the same superclass would independently retry (and
    /// could succeed where the first attempt failed). Collecting every distinct work item up front
    /// (required for hypothesis 0's single merged, file-sorted execution pass) cannot preserve an
    /// outcome-dependent retry without executing queries during collection itself, so this extends
    /// the *already-permanent* conformance-pair claim model uniformly to superclass/containingType
    /// too via `claimedSuperclass`/`claimedContainingType` -- one well-understood, narrow
    /// difference, verified against the real `Project Iris` correctness gate, not assumed.
    ///
    /// A declaration deferred as a conformance-pair claimant of last resort, because its own copy
    /// of the conformance is not a `declaredInSameContextAsWitness` one -- see the claim loop's own
    /// doc comment for why only a witness-context declaration is a safe first-choice
    /// representative.
    private struct DeferredConformanceCandidate {
        let declarationUSR: String
        let location: SymbolLocation
        let nominal: String
        let conformances: [ProtocolConformance]
        let indices: [Int]
    }

    /// `Swift.Sendable` and `Swift.SendableMetatype` -- `@_marker` protocols (the compiler's own
    /// designation for a protocol with no runtime representation/witness table), both declared
    /// with an empty body, zero requirements, in `stdlib/public/core/Sendable.swift`:
    /// `@_marker public protocol SendableMetatype: ~Copyable, ~Escapable { }` and
    /// `@_marker public protocol Sendable: SendableMetatype, ~Copyable, ~Escapable { }`
    /// (confirmed directly against `swiftlang/swift`'s real source, not assumed) -- structurally
    /// incapable of ever being `@GlobalActor`-qualified by anyone. Excluded from the declaration-level conformance-pair
    /// trigger below entirely: that trigger's live-query fallback infers a conformed protocol's own
    /// global-actor status from *the conforming declaration's own effective isolation* (see its own
    /// doc comment, "more precise than the live query's fallback, which infers a shared actor name
    /// from the conforming type's single effective isolation, not each individual protocol's own")
    /// -- an approximation that is not just imprecise but flatly *wrong* whenever the conforming
    /// declaration's own isolation comes from a source unrelated to this specific conformance, most
    /// concretely a project's module-wide default isolation (SE-0466). Confirmed as a real,
    /// reproduced false positive against a real project (`IceCubesApp`, `StatusEditor.
    /// MediaUploadService.UploadPolicy: Sendable`, `NetworkClient.MastodonClient: ...Sendable`):
    /// both types have no explicit isolation of their own and live in files with no reason to be
    /// `@MainActor`, yet `struct UploadPolicy: Sendable`'s own live-queried isolation still comes
    /// back `@MainActor` (`StatusKit`'s package manifest sets `.defaultIsolation(MainActor.self)`,
    /// and `UploadPolicy` itself was empirically confirmed real-`nonisolated` -- a `nonisolated`
    /// synchronous function reading `policy.maxBytes`, a mutable `var`, compiles with no actor-
    /// isolation error at all) -- so this mechanism concluded "conforming to `Sendable` makes you
    /// `@MainActor`", corrupting the well-known SE-0466 exclusion (`isEligibleForModuleDefaultIsolation`
    /// already correctly excludes `Sendable`/`SendableMetatype`-conforming declarations from the
    /// module default) via `IsolationInferenceEngine.resolveInheritedIsolation`'s *higher-priority*
    /// same-context-as-witness rule, which runs before the correctly-implemented default-isolation
    /// exclusion is ever consulted. `Sendable`/`SendableMetatype` conformances can never legitimately
    /// answer "yes" here, so the safe, narrow fix is to never treat them as worth asking at all.
    private static let wellKnownNeverGlobalActorProtocolUSRs: Set<String> = [
        "s:s8SendableP", "s:s16SendableMetatypeP",
    ]

    private static func collectDeclarationLevelWorkItems(
        linked: LinkedAnalysis,
        bulkCache: [String: IsolationKind],
        bulkModuleNameByUSR: [String: String],
        bulkProtocolUSRs: Set<String>,
        backfilled: inout [String: DeclarationInfo],
        pairOutcomes: inout [ConformancePairKey: ConformancePairOutcome],
        pairIndicesByDeclaration: inout [String: [(index: Int, key: ConformancePairKey)]]
    ) -> (plans: [DeclarationQueryPlan], placeholderNeeds: [PlaceholderNeed]) {
        var claimedSuperclass: Set<String> = []
        var claimedContainingType: Set<String> = []
        var claimedPairs: Set<ConformancePairKey> = []
        var plans: [DeclarationQueryPlan] = []
        var placeholderNeeds: [PlaceholderNeed] = []
        var deferredConformanceCandidates: [DeferredConformanceCandidate] = []

        // Hypothesis 0: sorted, not `linked.declarations.values`' own (already unspecified/hash-
        // randomized) order -- strictly more deterministic than before, not less, and groups
        // same-file declarations so the merged execution pass (§ resolve) reuses a file's AST
        // across both trigger kinds rather than rebuilding it once per kind.
        // `usr` is a required final tie-breaker, not cosmetic -- see `resolve()`'s own merged-sort
        // comment: two distinct declarations can legitimately share one exact (file, line, column)
        // on real code, and `linked.declarations` is itself a `Dictionary` (iteration order not
        // guaranteed stable across process launches), so a location-only sort leaves such ties'
        // relative order non-deterministic.
        let orderedDeclarations = linked.declarations.values.sorted { lhs, rhs in
            guard let lhsLocation = lhs.location else { return false }
            guard let rhsLocation = rhs.location else { return true }
            if lhsLocation.file != rhsLocation.file { return lhsLocation.file < rhsLocation.file }
            if lhsLocation.line != rhsLocation.line { return lhsLocation.line < rhsLocation.line }
            if lhsLocation.column != rhsLocation.column { return lhsLocation.column < rhsLocation.column }
            return lhs.usr < rhs.usr
        }

        // A `linked.declarations[usr]` entry with no `location` at all has no primary declaration
        // anywhere among the analyzed files -- `DeclarationLinker.merged`'s own "known, documented
        // limitation" doc comment (only extensions ever contributed to it, e.g. `extension
        // UIViewController { ... }` in a project's own helper file, extending a real SDK type that
        // itself is never declared in the analyzed project) -- so it carries no real isolation
        // information (`explicitIsolation: nil`, and `resolveDefaultIsolation` would just fall
        // through to `.nonisolated`). Confirmed a real, reproduced bug on `Swiftfin`:
        // `PreferencesView/Sources/PreferencesView/UIViewController+Swizzling.swift` extends the
        // real `UIViewController`, which creates exactly this phantom, isolation-less
        // `"syntactic:UIViewController"` entry -- and since `linked.declarations[superclassUSR] ==
        // nil` was the *only* signal this claim loop used to decide "already resolved, no backfill
        // needed," every *other*, unrelated declaration in the whole project whose own superclass
        // is genuinely `UIViewController` (`UIVideoPlayerContainerViewController`, a real, direct
        // subclass, confirmed `@MainActor` via a real `swiftc` repro: "main actor isolation
        // inferred from inheritance from class 'UIViewController'") silently inherited that
        // phantom's `.nonisolated` default instead of ever triggering a live-query backfill.
        // Treating a location-less entry as "not really resolved" here routes it into the exact
        // same external-backfill path a plain unresolved placeholder already gets.
        func isGenuinelyResolvedProjectLocalDeclaration(_ usr: String) -> Bool {
            linked.declarations[usr]?.location != nil
        }

        for declaration in orderedDeclarations {
            guard declaration.explicitIsolation == nil, declaration.enclosingExtensionIsolation == nil else { continue }

            var unresolvedSuperclassUSR = declaration.superclassUSR.flatMap { superclassUSR in
                !isGenuinelyResolvedProjectLocalDeclaration(superclassUSR) && backfilled[superclassUSR] == nil ? superclassUSR : nil
            }
            // Extension-of-an-external-type fix (docs/task-external-type-extension-isolation.md):
            // a member whose `containingTypeUSR` `DeclarationLinker`'s own `.childOf`/`.extendedBy`
            // chain rewrote to a real, external USR (the extended type has no primary declaration
            // among the linked files) needs that type's own isolation backfilled here, exactly the
            // way an external superclass already does -- same store, same `declarations[usr]`
            // lookup `IsolationInferenceEngine.resolveInheritedIsolation`'s containing-type-
            // propagation branch already performs, no engine change needed.
            var unresolvedContainingTypeUSR = declaration.containingTypeUSR.flatMap { containingTypeUSR in
                !isGenuinelyResolvedProjectLocalDeclaration(containingTypeUSR) && backfilled[containingTypeUSR] == nil ? containingTypeUSR : nil
            }
            var unresolvedConformanceIndices = declaration.conformances.indices.filter { index in
                let conformance = declaration.conformances[index]
                guard conformance.protocolGlobalActorName == nil,
                      conformance.declaredInSameFileAsPrimaryDefinition || conformance.declaredInSameContextAsWitness,
                      !isGenuinelyResolvedProjectLocalDeclaration(conformance.protocolUSR),
                      !wellKnownNeverGlobalActorProtocolUSRs.contains(conformance.protocolUSR) else { return false }
                return true
            }
            guard unresolvedSuperclassUSR != nil || unresolvedContainingTypeUSR != nil || !unresolvedConformanceIndices.isEmpty else { continue }

            // Bulk-cache fast path: satisfy whichever needs a bulk-extracted SDK module already
            // answers -- the external symbol's own real isolation, keyed directly by USR -- so the
            // live per-declaration query below only ever runs for what's genuinely left over.
            // Checking each protocol's *own* isolation directly here is actually more precise than
            // the live query's fallback (which infers a shared actor name from the conforming
            // type's single effective isolation, not each individual protocol's own). Per-
            // declaration and order-independent (a fixed lookup table, not a claim), exactly as
            // before hypothesis 0.
            let nominal = nominalUSR(for: declaration)
            if let superclassUSR = unresolvedSuperclassUSR, let cachedIsolation = bulkCache[superclassUSR] {
                backfilled[superclassUSR] = DeclarationInfo(
                    usr: superclassUSR, name: superclassUSR, explicitIsolation: cachedIsolation, isEligibleForModuleDefaultIsolation: false,
                    moduleName: bulkModuleNameByUSR[superclassUSR]
                )
                unresolvedSuperclassUSR = nil
            }
            if let containingTypeUSR = unresolvedContainingTypeUSR, let cachedIsolation = bulkCache[containingTypeUSR] {
                backfilled[containingTypeUSR] = DeclarationInfo(
                    usr: containingTypeUSR, name: containingTypeUSR, explicitIsolation: cachedIsolation, isEligibleForModuleDefaultIsolation: false,
                    moduleName: bulkModuleNameByUSR[containingTypeUSR]
                )
                unresolvedContainingTypeUSR = nil
            }

            // Every originally-unresolved conformance index is tracked here -- regardless of
            // whether the bulk-cache pass below resolves it immediately or it's still outstanding
            // for the live-query path -- because `applyConformancePairOutcomes` is the *only* place
            // that ever rewrites a declaration's `conformances` array, for both paths uniformly.
            // (A real bug this fixed during hypothesis 0's own correctness gate: registering only
            // the post-bulk-cache-filter leftovers here silently dropped every bulk-cache-resolved
            // conformance's actual application -- e.g. `extension SomeType: UITextFieldDelegate`
            // resolving `@MainActor` via the bulk-extracted UIKit cache, correctly computed into
            // `pairOutcomes`, but never applied to `SomeType`'s own `conformances`, since nothing
            // told this final apply pass that `SomeType` had a pair to rewrite at all.)
            if !unresolvedConformanceIndices.isEmpty {
                let indices = unresolvedConformanceIndices.map { index in
                    (index: index, key: ConformancePairKey(nominalUSR: nominal, protocolUSR: declaration.conformances[index].protocolUSR))
                }
                pairIndicesByDeclaration[declaration.usr, default: []].append(contentsOf: indices)
            }

            // Class-bound-protocol fix (docs/task-class-bound-protocol-conformance-isolation.md):
            // `declaration.conformances[index].protocolUSR` is *not* necessarily a protocol -- it's
            // whatever name appeared in an inheritance/conformance clause (`SyntaxAnalysis
            // .DeclarationExtractor.applyInheritance`'s `else` branch has no project-wide type-kind
            // knowledge at extraction time, so it can't tell `protocol P: SomeProtocol` apart from
            // `protocol P: SomeGlobalActorClass`, a class-bound protocol whose class constrains
            // *conformers*, not `P` itself). SE-0316's "conformance to a global-actor-qualified
            // protocol" rule only applies when the named entity genuinely *is* a protocol -- reusing
            // a class's own isolation here as if it were the protocol's stated global actor is wrong
            // (confirmed a real false positive: `protocol ViewDataConfigurable: UIView` on a real
            // corpus wrongly made every `ViewDataConfigurable` extension-default member, including
            // `static var reuseIdentifier`, resolve to `@MainActor`, with zero matching compiler
            // diagnostic at any of 220 real call sites). `bulkProtocolUSRs` (from `symbolgraph-
            // extract`'s own authoritative `kind.identifier`) is the one signal that tells the two
            // apart. Anything the bulk pass has *any* isolation data for is resolved definitively
            // here either way -- `.globalActor` only when it's confirmed a protocol, `.notGlobalActor`
            // otherwise (a confirmed class, or a protocol with no global-actor isolation of its own)
            // -- so this never adds live-query volume; only USRs bulk data has nothing on at all
            // still fall through to the live path below, exactly as before this fix.
            unresolvedConformanceIndices = unresolvedConformanceIndices.filter { index in
                let protocolUSR = declaration.conformances[index].protocolUSR
                guard let cachedIsolation = bulkCache[protocolUSR] else { return true }
                let key = ConformancePairKey(nominalUSR: nominal, protocolUSR: protocolUSR)
                if bulkProtocolUSRs.contains(protocolUSR), case .globalActor(let actorName) = cachedIsolation {
                    pairOutcomes[key] = .globalActor(actorName)
                } else {
                    pairOutcomes[key] = .notGlobalActor
                }
                return false
            }

            // A real (not "syntactic:"-prefixed) USR genuinely identifies one external symbol --
            // claiming it once and sharing the answer across every declaration referencing it is
            // safe and correct (the whole point of Gap B/Phase I3's dedup). A `"syntactic:<Name>"`
            // value is a bare-name placeholder instead (`DeclarationLinker`'s own documented,
            // pre-existing limitation: "multiple such unresolved entries for the same name can
            // [collide]") -- it does *not* uniquely identify one real entity, so two different
            // declarations carrying the identical placeholder string can legitimately need two
            // different real answers, and the one that should "win" a shared placeholder can only
            // be decided by the same reuse-on-success/retry-on-failure logic the original
            // sequential code applied, one at a time -- it cannot be precomputed as a claim up
            // front the way a real USR safely can be. So placeholder-typed superclass/containingType
            // needs are deliberately *excluded* from this batch entirely and deferred to
            // `resolveSyntacticPlaceholderNeeds` below, which reproduces the original's exact
            // sequential, interleaved semantics for just this narrow subset.
            var claimsSomethingNew = false
            if let superclassUSR = unresolvedSuperclassUSR, !superclassUSR.hasPrefix("syntactic:") {
                if claimedSuperclass.contains(superclassUSR) {
                    unresolvedSuperclassUSR = nil
                } else {
                    claimedSuperclass.insert(superclassUSR)
                    claimsSomethingNew = true
                }
            }
            if let containingTypeUSR = unresolvedContainingTypeUSR, !containingTypeUSR.hasPrefix("syntactic:") {
                if claimedContainingType.contains(containingTypeUSR) {
                    unresolvedContainingTypeUSR = nil
                } else {
                    claimedContainingType.insert(containingTypeUSR)
                    claimsSomethingNew = true
                }
            }
            // The representative for a conformance pair is chosen by an intrinsic property of the
            // *specific conformance entry*, not by traversal order or by "is this the type itself":
            // only a declaration whose own copy of this conformance has
            // `declaredInSameContextAsWitness == true` -- a real member physically declared inside
            // the same syntactic construct (primary body or a specific `extension`) that introduces
            // the conformance -- is queried inline. Confirmed necessary by two real, opposite-shape
            // regressions on `Project Iris` (see this file's own top-level doc comment): a type's own
            // top-level entry can be a bad representative (conformance declared via a *different*
            // same-file extension) and an arbitrary member can equally be a bad representative
            // (conformance declared on the primary type directly, member's own location carries an
            // unrelated attribute a live query can misreport). Every other candidate -- the type's
            // own entry, or a member without witness-context locality for this specific protocol --
            // is deferred to the fallback pass below, which only lets a non-witness declaration
            // claim a pair if no witness-context declaration ever does.
            //
            // A witness-context member is *also* rejected as a representative (deferred exactly
            // like a non-witness one) when it's structurally ineligible for isolation at all
            // (`isEligibleForModuleDefaultIsolation`'s own SE-0466 exclusion list: typealiases,
            // enum cases, accessors) -- confirmed a real, reproduced regression on `Swiftfin`:
            // `struct SelectUserView: View { typealias UserItem = (...); ... var body: some View
            // { ... } }` picked `UserItem` (declared earlier in the file, hence first in
            // `orderedDeclarations`) as the (SelectUserView, View) pair's representative. A
            // `typealias` can never carry actor isolation, so its own live-queried isolation
            // correctly comes back `.nonisolated` -- but that's a fact about the *typealias*, not
            // about whether `View` (a real, whole-protocol `@MainActor` conformance, confirmed
            // directly against `SwiftUICore`'s own `.swiftinterface`) applies to the type. Skipping
            // ineligible candidates lets a later, eligible witness-context member (`body`, here)
            // claim the pair instead.
            var ownedPairKeys: [ConformancePairKey] = []
            var deferredIndices: [Int] = []
            for index in unresolvedConformanceIndices {
                let key = ConformancePairKey(nominalUSR: nominal, protocolUSR: declaration.conformances[index].protocolUSR)
                guard !claimedPairs.contains(key) else { continue }
                guard declaration.conformances[index].declaredInSameContextAsWitness, declaration.isEligibleForModuleDefaultIsolation else {
                    deferredIndices.append(index)
                    continue
                }
                claimedPairs.insert(key)
                ownedPairKeys.append(key)
                claimsSomethingNew = true
            }
            if !deferredIndices.isEmpty, let location = declaration.location {
                deferredConformanceCandidates.append(DeferredConformanceCandidate(
                    declarationUSR: declaration.usr, location: location, nominal: nominal,
                    conformances: declaration.conformances, indices: deferredIndices
                ))
            }

            let placeholderSuperclassUSR = unresolvedSuperclassUSR?.hasPrefix("syntactic:") == true ? unresolvedSuperclassUSR : nil
            let placeholderContainingTypeUSR = unresolvedContainingTypeUSR?.hasPrefix("syntactic:") == true ? unresolvedContainingTypeUSR : nil
            if let location = declaration.location, placeholderSuperclassUSR != nil || placeholderContainingTypeUSR != nil {
                placeholderNeeds.append(PlaceholderNeed(
                    declarationUSR: declaration.usr, location: location,
                    superclassUSR: placeholderSuperclassUSR, containingTypeUSR: placeholderContainingTypeUSR
                ))
            }

            guard claimsSomethingNew, let location = declaration.location else { continue }

            plans.append(DeclarationQueryPlan(
                declarationUSR: declaration.usr, location: location,
                superclassUSR: unresolvedSuperclassUSR?.hasPrefix("syntactic:") == true ? nil : unresolvedSuperclassUSR,
                containingTypeUSR: unresolvedContainingTypeUSR?.hasPrefix("syntactic:") == true ? nil : unresolvedContainingTypeUSR,
                pairKeys: ownedPairKeys
            ))
        }

        // Fallback pass: a non-witness-context declaration (the type's own entry, or a member
        // without witness-context locality for this specific protocol) only claims a conformance
        // pair here if *no* witness-context declaration ever claimed it during the main loop above
        // (re-checked against the now-final `claimedPairs`, since a witness-context declaration
        // appearing later in file order may have claimed it after this candidate deferred it) --
        // see the claim loop's own doc comment for why a non-witness declaration is deliberately
        // never a first-choice representative. These plans join the same merged, file-sorted
        // execution pass as everything else (§ resolve) -- never a separately-ordered append.
        for candidate in deferredConformanceCandidates {
            var pairKeys: [ConformancePairKey] = []
            for index in candidate.indices {
                let key = ConformancePairKey(nominalUSR: candidate.nominal, protocolUSR: candidate.conformances[index].protocolUSR)
                guard !claimedPairs.contains(key) else { continue }
                claimedPairs.insert(key)
                pairKeys.append(key)
            }
            guard !pairKeys.isEmpty else { continue }
            plans.append(DeclarationQueryPlan(
                declarationUSR: candidate.declarationUSR, location: candidate.location,
                superclassUSR: nil, containingTypeUSR: nil, pairKeys: pairKeys
            ))
        }

        return (plans, placeholderNeeds)
    }

    /// A declaration whose superclass and/or containing-type need is still an unresolved
    /// `"syntactic:<Name>"` bare-name placeholder -- see `collectDeclarationLevelWorkItems`'s own
    /// doc comment for why these can't safely join the claim-once batch.
    private struct PlaceholderNeed {
        let declarationUSR: String
        let location: SymbolLocation
        let superclassUSR: String?
        let containingTypeUSR: String?
    }

    /// Reproduces the pre-hypothesis-0 sequential algorithm's exact semantics for placeholder-typed
    /// superclass/containingType needs: walked one at a time (file-sorted here for whatever
    /// locality benefit is safely available, though -- unlike the main batch -- this loop cannot
    /// itself be reordered into a merged, pre-planned execution without losing that semantics), each
    /// re-checking `backfilled[usr] == nil` *at the time it runs* (so an earlier item in *this same
    /// loop* resolving the identical placeholder string is correctly reused, matching original's
    /// "share on success"), and retrying independently on `.unknown` rather than caching it
    /// permanently (matching original's "no negative cache for superclass/containingType" -- unlike
    /// conformance pairs, which already had a permanent cache before hypothesis 0 and are
    /// unaffected by any of this).
    private static func resolveSyntacticPlaceholderNeeds(
        _ needs: [PlaceholderNeed],
        linked: LinkedAnalysis,
        compilerArguments: CompilerArgumentsProviding,
        sourceKitD: SourceKitDQuerying,
        fileSystem: FileSystemQuerying,
        bulkCache: [String: IsolationKind],
        bulkModuleNameByUSR: [String: String],
        knownGlobalActorNames: Set<String>,
        backfilled: inout [String: DeclarationInfo],
        unknown: inout Set<String>
    ) async {
        for need in needs {
            let stillUnresolvedSuperclassUSR = need.superclassUSR.flatMap { backfilled[$0] == nil ? $0 : nil }
            let stillUnresolvedContainingTypeUSR = need.containingTypeUSR.flatMap { backfilled[$0] == nil ? $0 : nil }
            guard stillUnresolvedSuperclassUSR != nil || stillUnresolvedContainingTypeUSR != nil else { continue }

            let outcome = await query(
                targetUSR: need.declarationUSR, file: need.location.file, line: need.location.line, utf8Column: need.location.column,
                compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem, bulkCache: bulkCache,
                bulkModuleNameByUSR: bulkModuleNameByUSR, knownGlobalActorNames: knownGlobalActorNames
            )
            switch outcome {
            case .resolved(let isolation, let moduleName):
                if let superclassUSR = stillUnresolvedSuperclassUSR {
                    backfilled[superclassUSR] = DeclarationInfo(
                        usr: superclassUSR, name: superclassUSR, explicitIsolation: isolation, isEligibleForModuleDefaultIsolation: false,
                        moduleName: moduleName
                    )
                }
                if let containingTypeUSR = stillUnresolvedContainingTypeUSR {
                    backfilled[containingTypeUSR] = DeclarationInfo(
                        usr: containingTypeUSR, name: containingTypeUSR, explicitIsolation: isolation, isEligibleForModuleDefaultIsolation: false,
                        moduleName: moduleName
                    )
                }
            case .unknown:
                // Matches the batch path's own member-propagation exactly (see
                // `applyDeclarationLevelOutcomes`) -- a declaration whose *only* need was a
                // placeholder superclass/containingType must still mark its direct members unknown
                // on failure, not just itself.
                unknown.insert(need.declarationUSR)
                for other in linked.declarations.values where other.containingTypeUSR == need.declarationUSR {
                    unknown.insert(other.usr)
                }
            }
        }
    }

    private static func applyDeclarationLevelOutcomes(
        _ plans: [DeclarationQueryPlan],
        outcomes: [String: QueryOutcome],
        linked: LinkedAnalysis,
        backfilled: inout [String: DeclarationInfo],
        unknown: inout Set<String>,
        pairOutcomes: inout [ConformancePairKey: ConformancePairOutcome]
    ) {
        for plan in plans {
            switch outcomes[plan.declarationUSR] {
            case .resolved(let isolation, let moduleName):
                if let superclassUSR = plan.superclassUSR {
                    backfilled[superclassUSR] = DeclarationInfo(
                        usr: superclassUSR, name: superclassUSR, explicitIsolation: isolation, isEligibleForModuleDefaultIsolation: false,
                        moduleName: moduleName
                    )
                }
                if let containingTypeUSR = plan.containingTypeUSR {
                    backfilled[containingTypeUSR] = DeclarationInfo(
                        usr: containingTypeUSR, name: containingTypeUSR, explicitIsolation: isolation, isEligibleForModuleDefaultIsolation: false,
                        moduleName: moduleName
                    )
                }
                if !plan.pairKeys.isEmpty {
                    let outcome: ConformancePairOutcome = {
                        if case .globalActor(let actorName) = isolation { return .globalActor(actorName) }
                        return .notGlobalActor
                    }()
                    for key in plan.pairKeys { pairOutcomes[key] = outcome }
                }
            case .unknown, .none:
                for key in plan.pairKeys { pairOutcomes[key] = .unknown }
                // Mark the declaration itself, plus its direct members (one level of containing-
                // type propagation -- covers the common case, e.g. a method whose isolation
                // recurses into its containing type's, per `resolveInheritedIsolation`'s own
                // containingTypeUSR branch). Deeper nesting is a documented, known limitation, not
                // silently assumed away -- see docs/priority-3-phase-c-oracle-triggers.md.
                unknown.insert(plan.declarationUSR)
                for other in linked.declarations.values where other.containingTypeUSR == plan.declarationUSR {
                    unknown.insert(other.usr)
                }
            }
        }
    }

    /// Rebuilds `conformances` for *every* declaration with a tracked pair index -- whether it was
    /// the one whose own query resolved the pair or a "follower" sharing the same (nominal,
    /// protocol) pair claimed by a different declaration -- from the final `pairOutcomes`, mirroring
    /// the original code's own "only `.globalActor` outcomes actually rewrite `conformances`"
    /// gating (a `.notGlobalActor`/`.unknown` outcome leaves that index's `protocolGlobalActorName`
    /// as `nil`, exactly as before).
    private static func applyConformancePairOutcomes(
        _ pairIndicesByDeclaration: [String: [(index: Int, key: ConformancePairKey)]],
        pairOutcomes: [ConformancePairKey: ConformancePairOutcome],
        linked: LinkedAnalysis,
        updated: inout [String: DeclarationInfo]
    ) {
        for (declarationUSR, indices) in pairIndicesByDeclaration {
            guard let declaration = linked.declarations[declarationUSR] else { continue }
            var conformances = declaration.conformances
            var changed = false
            for (index, key) in indices {
                guard case .globalActor(let actorName)? = pairOutcomes[key] else { continue }
                conformances[index] = ProtocolConformance(
                    protocolUSR: conformances[index].protocolUSR,
                    protocolGlobalActorName: actorName,
                    declaredInSameFileAsPrimaryDefinition: conformances[index].declaredInSameFileAsPrimaryDefinition,
                    declaredInSameContextAsWitness: conformances[index].declaredInSameContextAsWitness,
                    isUnchecked: conformances[index].isUnchecked,
                    isPreconcurrency: conformances[index].isPreconcurrency
                )
                changed = true
            }
            if changed {
                updated[declarationUSR] = rebuilt(declaration, conformances: conformances)
            }
        }
    }

    private static func rebuilt(_ declaration: DeclarationInfo, conformances: [ProtocolConformance]) -> DeclarationInfo {
        DeclarationInfo(
            usr: declaration.usr,
            name: declaration.name,
            explicitIsolation: declaration.explicitIsolation,
            isActorType: declaration.isActorType,
            containingTypeUSR: declaration.containingTypeUSR,
            isStaticMember: declaration.isStaticMember,
            superclassUSR: declaration.superclassUSR,
            conformances: conformances,
            isEligibleForModuleDefaultIsolation: declaration.isEligibleForModuleDefaultIsolation,
            enclosingExtensionIsolation: declaration.enclosingExtensionIsolation,
            isNestedType: declaration.isNestedType,
            location: declaration.location,
            isImmutableStoredProperty: declaration.isImmutableStoredProperty,
            isActorInitializer: declaration.isActorInitializer,
            hasPreconcurrencyAttribute: declaration.hasPreconcurrencyAttribute,
            isNonisolatedUnsafe: declaration.isNonisolatedUnsafe,
            moduleName: declaration.moduleName
        )
    }

    // MARK: - Shared oracle query

    enum QueryOutcome {
        case resolved(IsolationKind, moduleName: String?)
        case unknown
    }

    /// `sourcekitd`'s `key.modulename` is not always a bare module name -- confirmed on a real
    /// ~2200-file corpus (docs/task-escape-hatch-and-preconcurrency-severity.md PR2 Step 2, 2405
    /// real live queries against Project Iris): a plain name for most Swift/Pods symbols
    /// (`"Mindbox"`), but `"Module.Type"` for many ObjC-bridged property/accessor symbols
    /// (`"WebKit.WKWebView"`), and `"Module.Submodule.Type"` for a real Clang-submodule case
    /// (`"Darwin.os.lock"`) -- the first `.`-separated component was the real top-level module name
    /// in every one of those 2405 real samples, no exceptions found.
    private static func topLevelModuleName(from rawModuleName: String) -> String {
        String(rawModuleName.split(separator: ".", maxSplits: 1).first ?? Substring(rawModuleName))
    }

    /// One `sourcekitd` cursor-info round trip: resolve compiler arguments + byte offset, send the
    /// request, select the result by USR, parse isolation (symbol-graph primary, XML fallback).
    /// Every failure mode -- compiler-args unavailable, offset conversion failure, the query
    /// itself throwing, no USR match among the results, or a matched result whose isolation can't
    /// be parsed at all -- becomes `.unknown`, never a crash and never a silent `.nonisolated`.
    static func query(
        targetUSR: String,
        file: String,
        line: Int,
        utf8Column: Int,
        compilerArguments: CompilerArgumentsProviding,
        sourceKitD: SourceKitDQuerying,
        fileSystem: FileSystemQuerying,
        bulkCache: [String: IsolationKind],
        bulkModuleNameByUSR: [String: String],
        knownGlobalActorNames: Set<String>
    ) async -> QueryOutcome {
        // The primary win for the edge-level trigger: a direct call into a bulk-covered SDK
        // module (e.g. `someUIView.someMethod()`) resolves from an in-memory dictionary, no
        // `sourcekitd` round trip at all. A no-op lookup for the declaration-level trigger's own
        // `targetUSR` (always a project-local declaration, never itself in an SDK module's cache).
        if let cached = bulkCache[targetUSR] {
            return .resolved(cached, moduleName: bulkModuleNameByUSR[targetUSR])
        }
        do {
            let rawArguments = try compilerArguments.compilerArguments(forFile: file)
            // `compilerArguments(forFile:)` faithfully returns the real build's real (frontend-
            // level, for SwiftPM) arguments -- `sourcekitd`'s `key.compilerargs` needs driver-
            // level arguments instead, confirmed empirically (docs/priority-3-phase-e-fixtures.md).
            let arguments = CompilerArgumentsSanitizing.sanitized(rawArguments)
            let offset = try UTF8OffsetLocator.utf8Offset(inFile: file, line: line, utf8Column: utf8Column, fileSystem: fileSystem)
            let result = try await sourceKitD.cursorInfo(CursorInfoRequest(sourceFile: file, byteOffset: offset, compilerArguments: arguments))
            // `BridgedExternConstantMatching` only ever runs once strict USR equality has already
            // failed -- a narrow fallback for a confirmed, real shape strict matching can never
            // resolve by construction (docs/task-extern-constant-swift-name-usr-mismatch.md), not a
            // relaxation of `USRMatching`'s own binding "strict equality only" design for the general
            // case.
            guard let symbol = USRMatching.select(from: result, targetUSR: targetUSR)
                ?? BridgedExternConstantMatching.select(from: result, targetUSR: targetUSR)
                ?? BridgedExternConstantContainerMatching.select(from: result, targetUSR: targetUSR)
                ?? BridgedExternConstantOptionalContainerMatching.select(from: result, targetUSR: targetUSR)
                ?? BridgedExternClassConstantMatching.select(from: result, targetUSR: targetUSR)
                ?? ObjCProtocolPropertyWitnessMatching.select(from: result, targetUSR: targetUSR)
                ?? BridgedExternFunctionPropertyMatching.select(from: result, targetUSR: targetUSR) else { return .unknown }
            let moduleName = symbol.moduleName.map(topLevelModuleName(from:))
            if let symbolGraphJSON = symbol.symbolGraphJSON,
               let isolation = SymbolGraphIsolationParser.isolation(fromSymbolGraphJSON: symbolGraphJSON, knownGlobalActorNames: knownGlobalActorNames) {
                return .resolved(isolation, moduleName: moduleName)
            }
            if let xml = symbol.fullyAnnotatedDeclXML,
               let isolation = FullyAnnotatedDeclParser.isolation(fromXML: xml, knownGlobalActorNames: knownGlobalActorNames) {
                return .resolved(isolation, moduleName: moduleName)
            }
            return .unknown
        } catch {
            return .unknown
        }
    }
}
