import Foundation
import CIndexStoreRaw
import IsolationCore

/// Same local-stderr-helper pattern as `ProjectResolution/XcodeBuildLogCompilerArgumentsProvider.swift`
/// -- a library target has no access to the executable's own `eprint`, and `internal` symbols don't
/// cross module boundaries even between targets that depend on each other.
func writeStderr(_ message: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((message + terminator).utf8))
}

/// Experimental second `IndexStoreQuerying` conformer, backed directly by `libIndexStore`'s raw C
/// API (`CIndexStoreRaw`) instead of `IndexStoreDB`'s own Swift/C++ wrapper -- the scoped spike
/// issue #51 (`docs/task-indexstore-declaration-completeness.md`) called for, testing whether
/// `IndexStoreDB`'s own async, LMDB-backed initialization layer is the actual root cause of that
/// issue's declaration-loss, by bypassing it entirely. See `docs/task-raw-indexstore-spike.md`
/// for the full decision record; see the persistent investigation memory
/// (`project_libindexstore_raw_api_investigation.md`) for the prior correctness/performance spike
/// this is built on.
///
/// **Architecture, matching the memory's own "one full pass, not seven on-demand queries" note**:
/// unlike `IndexStoreClient` (which asks `IndexStoreDB` a fresh question per call), this type does
/// exactly one synchronous, upfront scan of the *entire* store at `init` time -- every unit, every
/// record, every occurrence, every relation -- and builds a small set of in-memory indices that
/// every `IndexStoreQuerying` method then answers from directly. This matches how
/// `DeclarationLinker`/`LinkedAnalysis` already build the whole call graph once per run rather
/// than querying on demand, and avoids the one raw-API gap `IndexStoreDB` doesn't have: there is
/// no store-wide "occurrences related to USR X" primitive in `indexstore.h` at all (confirmed
/// against the real header), so a reverse lookup like `callGraphEdges(forUSR:)` is only answerable
/// after a full pass has already indexed every file's own call sites by callee.
///
/// **Why every callback below is a free function, not a closure or method**: Swift refuses to
/// form a C function pointer from any closure that "captures context" -- and, found empirically
/// while building this, that includes a closure merely *referencing* a `private static func` or
/// nested type of its own enclosing class, not only closures over local variables. Every
/// `indexstore_shim_*_apply_f` callback here is therefore a true top-level function, referencing
/// only other top-level declarations in this file, with all real state threaded through the C
/// `void *context` parameter via `Unmanaged`/`UnsafeMutablePointer` -- the only shape that reliably
/// converts to `@convention(c)`.
///
/// `@unchecked Sendable`: every index below is built once, synchronously, in `init`, and never
/// mutated afterward; concurrent reads of already-built, immutable storage are safe.
public final class RawIndexStoreClient: IndexStoreQuerying, @unchecked Sendable {
    fileprivate var definedSymbolsByFile: [String: [IndexedSymbol]] = [:]
    fileprivate var callEdgesByCallee: [String: [CallGraphEdge]] = [:]
    fileprivate var callEdgesByFile: [String: [CallGraphEdge]] = [:]
    /// Every source position where a real `getter:`-named `CALL`-role occurrence was seen --
    /// populated during the scan, consumed once, at the end of `init`, to filter
    /// `pendingSetterEdges`. See that property's own doc comment for why this exists.
    fileprivate var getterCallLocations: Set<SymbolLocation> = []
    /// A `setter:`-named `CALL`-role occurrence's edge is never added directly -- held here until
    /// the *entire* store has been scanned, then reconciled against `getterCallLocations`
    /// (docs/task-readonly-property-phantom-setter-edge.md): a real Objective-C **read-only**
    /// property, accessed via a pure read (`view.leadingAnchor.constraint(...)`, never assigned),
    /// still gets *two* `CALL`-role occurrences recorded at the exact same `(file, line, column)`
    /// by the real Swift indexer -- one `getter:<name>` (the real access) and one phantom
    /// `setter:<name>` for a setter that doesn't exist in the real header and would be a hard
    /// compile error to actually invoke. Confirmed directly: a genuinely writable property
    /// (`translatesAutoresizingMaskIntoConstraints = false`) gets *only* the `setter:`-named
    /// occurrence at its location, never a paired `getter:` one -- so "both a getter and a setter
    /// occurrence share one exact position" is itself the real, reliable signal that the setter
    /// one is the indexer's own read-only-property artifact, not a genuine call. A single forward
    /// pass can't apply this filter inline (occurrence order within a record isn't guaranteed to
    /// put the getter before the setter), hence the defer-then-reconcile shape.
    fileprivate var pendingSetterEdges: [(location: SymbolLocation, edge: CallGraphEdge)] = []
    /// Keyed by the *occurrence's own* symbol USR -- "what does this symbol relate to" (the
    /// `occurrences(ofUSR:roles:)` query direction: `.accessorOf`/`.childOf`/`.extendedBy`
    /// resolved from a symbol's own definition site).
    fileprivate var relationsBySymbolUSR: [String: [RawRelation]] = [:]
    /// Keyed by the *relation target's* USR -- "what relates to this symbol" (the
    /// `occurrences(relatedToUSR:roles:)` query direction: `.baseOf`/`.extendedBy` resolved
    /// looking *at* a type from whatever references it).
    fileprivate var relatedToUSR: [String: [RawRelation]] = [:]
    /// How many real units the scan skipped because `allowedModuleNames` was non-`nil` and didn't
    /// contain that unit's own module name -- surfaced for `--verbose` diagnostics (issue: a shared,
    /// project-wide Xcode index store accumulates units from *any* build ever run against it,
    /// including an unrelated scheme's own test target from a completely separate invocation; see
    /// `allowedModuleNames`'s own doc comment).
    public fileprivate(set) var skippedUnitCount = 0

    /// `allowedModuleNames`, when non-`nil`, restricts the scan to units whose own
    /// `indexstore_unit_reader_get_module_name` is in this set -- real, confirmed gap on `Project
    /// Iris`: `Index.noindex/DataStore` is a single directory shared and accumulated across *every*
    /// build Xcode has ever run against this DerivedData folder, not scoped to the scheme/target
    /// this tool was actually asked to analyze. Confirmed directly: a real run's own index store
    /// carried real, indexed `lsboutiqueTests` (XCTest) units even though the analyzed scheme's own
    /// `.xcscheme` declares an empty `<Testables>` list and a plain `xcodebuild -scheme ls.net.ru
    /// build` never compiles that target at all -- those records were left over from some *other*,
    /// unrelated build (Xcode GUI, CI, a different tool invocation) that happened to touch the same
    /// DerivedData at some point. `nil` (the default) disables filtering entirely, unchanged from
    /// this type's original behavior -- every existing caller (SPM projects, whose compiler-
    /// arguments provider has no notion of "real module names" at all, and any test double) keeps
    /// scanning the whole store exactly as before.
    public init(storePath: String, toolchainLocator: ToolchainLocating = LiveToolchainLocator(), allowedModuleNames: Set<String>? = nil) throws {
        let dylibPath = try toolchainLocator.libIndexStorePath()
        if indexstore_shim_load(dylibPath) != 0 {
            throw RawIndexStoreError.loadFailed(String(cString: indexstore_shim_last_error()))
        }
        var error: indexstore_error_t?
        guard let store = indexstore_shim_store_create(storePath, &error) else {
            throw RawIndexStoreError.storeCreateFailed(rawIndexStoreDescribe(error))
        }
        defer { indexstore_shim_store_dispose(store) }
        try rawIndexStoreScan(store: store, into: self, allowedModuleNames: allowedModuleNames)

        // Reconcile deferred setter-named edges now that the whole store has been scanned -- see
        // `pendingSetterEdges`'s own doc comment.
        for edge in Self.realSetterEdges(pendingSetterEdges: pendingSetterEdges, getterCallLocations: getterCallLocations) {
            callEdgesByCallee[edge.calleeUSR, default: []].append(edge)
            callEdgesByFile[edge.location.file, default: []].append(edge)
        }
        pendingSetterEdges = []
        getterCallLocations = []
    }

    /// Pure reconciliation logic behind the read-only-property phantom-setter filter
    /// (`pendingSetterEdges`'s own doc comment) -- independently unit-testable without a real index
    /// store, mirroring `resolvedOwningPropertyUSR`'s own precedent. A setter-named edge survives
    /// exactly when its own position was *never* also a getter-named occurrence: a real write
    /// (`x = value`) only ever produces the setter occurrence alone (confirmed against a real
    /// corpus: `UIView.translatesAutoresizingMaskIntoConstraints = false` never has a co-located
    /// getter occurrence), while a read-only property's real Swift-compiler-confirmed
    /// `AccessKind::ReadWrite` inference for a chained member-access-then-call expression
    /// (`lib/Index/Index.cpp`'s own `initVarRefIndexSymbols`, `swiftlang/swift`) reports *both*
    /// pseudo-accessors at the identical position even though only the getter is real.
    static func realSetterEdges(
        pendingSetterEdges: [(location: SymbolLocation, edge: CallGraphEdge)], getterCallLocations: Set<SymbolLocation>
    ) -> [CallGraphEdge] {
        pendingSetterEdges.filter { !getterCallLocations.contains($0.location) }.map(\.edge)
    }

    // MARK: - IndexStoreQuerying

    public func definedSymbols(inFile path: String) -> [IndexedSymbol] {
        definedSymbolsByFile[path] ?? []
    }

    public func callGraphEdges(forUSR usr: String) -> [CallGraphEdge] {
        callEdgesByCallee[usr] ?? []
    }

    public func callSites(inFile path: String) -> [CallGraphEdge] {
        callEdgesByFile[path] ?? []
    }

    /// Two real gaps closed here, confirmed against a real ~40-dependency corpus
    /// (docs/task-external-property-accessor-usr-mismatch.md, §5-§6), on top of the original
    /// project-local-only behavior:
    /// 1. A reference-only occurrence's `.accessorOf` relation is now trusted (not just a
    ///    `.definition`-role one) when `usr` has no definition anywhere -- i.e., a genuinely
    ///    external symbol, which never has a local definition to begin with. Prefers a
    ///    definition-role relation when one exists, preserving today's project-local behavior
    ///    exactly. Verified reliable across nine real external accessor USRs before trusting
    ///    this: every one had either exactly one candidate or several byte-identical duplicates,
    ///    never genuine disagreement -- `accessorOwningPropertyUSR(_:)` still requires unanimous
    ///    agreement and returns `nil` rather than guessing if that ever changes.
    /// 2. A real call-graph edge can reference an external symbol through a Clang-Module-qualified
    ///    USR (`c:@CM@UIKit@@objc(cs)UIView(im)leadingAnchor`) that this index's own relation
    ///    storage never uses for the identical declaration (`c:objc(cs)UIView(im)leadingAnchor`,
    ///    no qualifier) -- confirmed for `leadingAnchor`/`trailingAnchor`/`setHidden:`, and
    ///    confirmed the qualifier stays identical across four different real importing contexts
    ///    (the main app plus three separate CocoaPods) in the same corpus, with zero real
    ///    qualified/unqualified collisions anywhere in that corpus's edge set. Falls back to the
    ///    stripped form only when the direct lookup finds nothing.
    public func owningPropertyUSR(forUSR usr: String) -> String? {
        if let direct = accessorOwningPropertyUSR(usr) {
            return direct
        }
        let stripped = Self.strippingClangModuleQualifier(usr)
        guard stripped != usr else { return nil }
        return accessorOwningPropertyUSR(stripped)
    }

    /// Adapts this client's own internal `RawRelation` storage (`fileprivate`, unreachable from
    /// tests) into the plain-tuple shape `resolvedOwningPropertyUSR(fromAccessorOfCandidates:)`
    /// takes, so that function's own aggregation/disagreement logic stays independently testable
    /// with synthetic data, without needing a real index store to exercise a disagreement this
    /// project's own real corpus never actually produced.
    private func accessorOwningPropertyUSR(_ usr: String) -> String? {
        let candidates = (relationsBySymbolUSR[usr] ?? [])
            .filter { $0.role & INDEXSTORE_SYMBOL_ROLE_REL_ACCESSOROF != 0 }
            .map { (targetUSR: $0.targetUSR, isDefinitionRole: $0.occurrenceRoles & INDEXSTORE_SYMBOL_ROLE_DEFINITION != 0) }
        return Self.resolvedOwningPropertyUSR(forUSR: usr, fromAccessorOfCandidates: candidates)
    }

    /// Requires every `.accessorOf` candidate (after preferring definition-role ones, matching
    /// `IndexStoreClient`'s own `occurrences(ofUSR: usr, roles: .definition)` scoping when a
    /// definition exists) to agree on the same `targetUSR` -- never `.first`-and-hope. On the real
    /// corpus this was verified against, every multi-candidate case was byte-identical duplicates,
    /// so this costs nothing on real data; a genuine disagreement (never observed, but not provably
    /// impossible) safely falls through to `nil` instead of guessing, matching this project's own
    /// Guiding Principle. `forUSR` is used only for the diagnostic message on disagreement --
    /// doesn't affect resolution.
    static func resolvedOwningPropertyUSR(forUSR usr: String, fromAccessorOfCandidates candidates: [(targetUSR: String, isDefinitionRole: Bool)]) -> String? {
        let definitionCandidates = candidates.filter(\.isDefinitionRole)
        let scoped = definitionCandidates.isEmpty ? candidates : definitionCandidates
        let targets = Set(scoped.map(\.targetUSR))
        guard targets.count == 1 else {
            if targets.count > 1 {
                writeStderr("Warning: ambiguous .accessorOf relation for \(usr) -- competing targets: \(targets.sorted().joined(separator: ", ")); leaving unresolved rather than guessing.")
            }
            return nil
        }
        return targets.first
    }

    /// Strips a leading Clang-Module qualifier (`@CM@<Module>@@`) from a USR, if present -- see
    /// `owningPropertyUSR(forUSR:)`'s own doc comment for why this exists. Returns `usr` unchanged
    /// if it doesn't start with this exact prefix shape.
    static func strippingClangModuleQualifier(_ usr: String) -> String {
        let prefix = "c:@CM@"
        guard usr.hasPrefix(prefix),
              let separatorRange = usr.range(of: "@@", range: usr.index(usr.startIndex, offsetBy: prefix.count)..<usr.endIndex) else {
            return usr
        }
        return "c:" + usr[separatorRange.upperBound...]
    }

    public func baseTypeUSRs(forUSR usr: String) -> [(usr: String, name: String)] {
        var results = (relatedToUSR[usr] ?? [])
            .filter { $0.role & INDEXSTORE_SYMBOL_ROLE_REL_BASEOF != 0 }
            .map { ($0.targetUSR, $0.targetName) }
        // Matches `IndexStoreClient`'s own `occurrences(ofUSR: usr, roles: .extendedBy)` scoping:
        // the occurrence's own role (not just the relation's role) must include `.extendedBy`.
        let extensionUSRs = (relationsBySymbolUSR[usr] ?? [])
            .filter { $0.occurrenceRoles & INDEXSTORE_SYMBOL_ROLE_REL_EXTENDEDBY != 0 && $0.role & INDEXSTORE_SYMBOL_ROLE_REL_EXTENDEDBY != 0 }
            .map(\.targetUSR)
        for extensionUSR in Set(extensionUSRs) {
            results.append(contentsOf: (relatedToUSR[extensionUSR] ?? [])
                .filter { $0.role & INDEXSTORE_SYMBOL_ROLE_REL_BASEOF != 0 }
                .map { ($0.targetUSR, $0.targetName) })
        }
        return results
    }

    public func containingExtensionUSR(forMemberUSR usr: String) -> String? {
        relationsBySymbolUSR[usr]?.first {
            $0.occurrenceRoles & INDEXSTORE_SYMBOL_ROLE_DEFINITION != 0 && $0.role & INDEXSTORE_SYMBOL_ROLE_REL_CHILDOF != 0
        }?.targetUSR
    }

    public func extendedTypeUSR(forExtensionUSR usr: String) -> String? {
        relatedToUSR[usr]?.first { $0.role & INDEXSTORE_SYMBOL_ROLE_REL_EXTENDEDBY != 0 }?.targetUSR
    }
}

public enum RawIndexStoreError: Error, Equatable {
    case loadFailed(String)
    case storeCreateFailed(String)
    case unitReadFailed(String, String)
    case recordReadFailed(String, String)
}

// MARK: - Scan internals (file-private top-level: see the type's own doc comment for why)

fileprivate struct RawRelation {
    let role: indexstore_symbol_role_t
    let targetUSR: String
    let targetName: String
    /// The role(s) of the *occurrence this relation was attached to* (not the relation's own
    /// role) -- `IndexStoreDB`'s real `owningPropertyUSR`/`containingExtensionUSR` scope their
    /// lookup to `occurrences(ofUSR: usr, roles: .definition)` specifically, not "any occurrence
    /// of `usr` anywhere." Found the hard way: a `.call`-role reference occurrence of an external
    /// SDK symbol with no local definition (e.g. `NSCell.setTitle:`, referenced but never defined
    /// in this index) can *itself* carry an `.accessorOf` relation to its owning property -- an
    /// unscoped lookup wrongly canonicalizes the setter call to the property, silently changing
    /// which declaration an edge's `calleeUSR` names. `IndexStoreDB`'s own `occurrences(ofUSR:
    /// roles: .definition)` returns empty for such a symbol (no local definition exists), so the
    /// real, correct answer is `nil` -- confirmed by this exact regression in
    /// `CompiledDependencyCLITests`'s golden fixture (docs/task-raw-indexstore-spike.md).
    let occurrenceRoles: indexstore_symbol_role_t
}

private func rawIndexStoreDescribe(_ error: indexstore_error_t?) -> String {
    guard let error else { return "unknown error" }
    defer { indexstore_shim_error_dispose(error) }
    guard let description = indexstore_shim_error_get_description(error) else { return "unknown error" }
    return String(cString: description)
}

private func rawIndexStoreString(_ ref: indexstore_string_ref_t) -> String {
    guard let data = ref.data, ref.length > 0 else { return "" }
    return data.withMemoryRebound(to: UInt8.self, capacity: ref.length) { pointer in
        String(decoding: UnsafeBufferPointer(start: pointer, count: ref.length), as: UTF8.self)
    }
}

/// One synchronous pass: every unit -> its record dependencies (each carrying the real filepath
/// `indexstore_occurrence_get_line_col` alone can't give you -- confirmed in the prior scratchpad
/// spike) -> every occurrence in each *distinct* record, exactly once (a record can be a
/// dependency of more than one unit, e.g. the same file compiled into two targets -- processed
/// once, not once per referencing unit, to avoid double-counting edges).
private func rawIndexStoreScan(store: indexstore_t, into client: RawIndexStoreClient, allowedModuleNames: Set<String>?) throws {
    var state = RawUnitScanState(
        client: Unmanaged.passUnretained(client).toOpaque(), store: store, processedRecords: [],
        allowedModuleNames: allowedModuleNames, error: nil
    )
    withUnsafeMutablePointer(to: &state) { statePointer in
        _ = indexstore_shim_store_units_apply_f(store, /* sorted */ 1, statePointer, rawIndexStoreUnitApplier)
    }
    if let error = state.error {
        throw error
    }
    if let debugPath = ProcessInfo.processInfo.environment["SWIFT_ISOLATION_MAP_DEBUG_UNIT_MODULES"] {
        try? state.debugUnitLog.joined(separator: "\n").write(toFile: debugPath, atomically: true, encoding: .utf8)
    }
}

private struct RawUnitScanState {
    let client: UnsafeMutableRawPointer
    let store: indexstore_t
    var processedRecords: Set<String>
    let allowedModuleNames: Set<String>?
    var error: RawIndexStoreError?
    var debugUnitLog: [String] = []
}

private func rawIndexStoreUnitApplier(context: UnsafeMutableRawPointer?, unitNameRef: indexstore_string_ref_t) -> Bool {
    let statePointer = context!.assumingMemoryBound(to: RawUnitScanState.self)
    let unitName = rawIndexStoreString(unitNameRef)

    var unitError: indexstore_error_t?
    guard let unit = indexstore_shim_unit_reader_create(statePointer.pointee.store, unitName, &unitError) else {
        statePointer.pointee.error = .unitReadFailed(unitName, rawIndexStoreDescribe(unitError))
        return true
    }
    defer { indexstore_shim_unit_reader_dispose(unit) }

    // `allowedModuleNames == nil` (the default) never filters anything -- unchanged prior behavior.
    // See `RawIndexStoreClient.allowedModuleNames`'s own doc comment for the real, confirmed gap
    // this closes: the shared, project-wide index store accumulates units from any build ever run
    // against this DerivedData, not just the scheme this tool was asked to analyze.
    //
    // A *system* unit (`indexstore_unit_reader_is_system_unit`, confirmed exported by the real
    // `libIndexStore.dylib`) is never filtered, regardless of `allowedModuleNames` -- confirmed the
    // hard way (a full real-corpus regression on Project Iris, `crossActorBoundaries` 1790->23198)
    // that a positive allow-list built purely from the app's own real *Swift* `-module-name` values
    // can never contain a precompiled SDK/Clang-module's own name (`UIKit`, `Foundation`,
    // `CoreGraphics`, ...), because those are never something the app's own Swift compiler
    // invocations declare as their `-module-name`. Filtering them out anyway silently destroyed the
    // `.accessorOf` (property<->synthesized-accessor) relation data for every SDK symbol project-
    // wide -- that relation's one authoritative `.definition`-role occurrence is recorded only when
    // *that SDK module's own* unit is indexed, never at an app call site that merely references it
    // (`RawIndexStoreClient.resolvedOwningPropertyUSR`'s own definition-role preference) -- so
    // `owningPropertyUSR(forUSR:)` silently went from resolving correctly to always returning `nil`
    // for e.g. `UIView.setBackgroundColor:`, breaking the external-isolation oracle's ability to
    // canonicalize the callee to a USR it actually has an answer for. The original motivating gap
    // (a *first-party* target from an unrelated build/scheme, e.g. `lsboutiqueTests`, polluting the
    // shared store) is unaffected by this exemption: a first-party target's own unit is never a
    // system unit, so it's still correctly excluded whenever its module name isn't in this run's own
    // real module set.
    if let allowedModuleNames = statePointer.pointee.allowedModuleNames {
        let isSystemUnit = indexstore_shim_unit_reader_is_system_unit(unit)
        let moduleName = rawIndexStoreString(indexstore_shim_unit_reader_get_module_name(unit))
        let allowed = isSystemUnit || allowedModuleNames.contains(moduleName)
        if ProcessInfo.processInfo.environment["SWIFT_ISOLATION_MAP_DEBUG_UNIT_MODULES"] != nil {
            let mainFile = rawIndexStoreString(indexstore_shim_unit_reader_get_main_file(unit))
            statePointer.pointee.debugUnitLog.append("\(allowed ? "ALLOW" : "SKIP") module=\(moduleName) system=\(isSystemUnit) unit=\(unitName) mainFile=\(mainFile)")
        }
        guard allowed else {
            let client = Unmanaged<RawIndexStoreClient>.fromOpaque(statePointer.pointee.client).takeUnretainedValue()
            client.skippedUnitCount += 1
            return true
        }
    }

    var dependencies: [(recordName: String, filepath: String)] = []
    withUnsafeMutablePointer(to: &dependencies) { dependenciesPointer in
        _ = indexstore_shim_unit_reader_dependencies_apply_f(unit, dependenciesPointer, rawIndexStoreDependencyApplier)
    }

    for dependency in dependencies where !statePointer.pointee.processedRecords.contains(dependency.recordName) {
        statePointer.pointee.processedRecords.insert(dependency.recordName)
        var recordError: indexstore_error_t?
        guard let record = indexstore_shim_record_reader_create(statePointer.pointee.store, dependency.recordName, &recordError) else {
            statePointer.pointee.error = .recordReadFailed(dependency.recordName, rawIndexStoreDescribe(recordError))
            continue
        }
        defer { indexstore_shim_record_reader_dispose(record) }

        var recordState = RawRecordScanState(client: statePointer.pointee.client, filepath: dependency.filepath)
        withUnsafeMutablePointer(to: &recordState) { recordStatePointer in
            _ = indexstore_shim_record_reader_occurrences_apply_f(record, recordStatePointer, rawIndexStoreOccurrenceApplier)
        }
    }
    return true
}

private func rawIndexStoreDependencyApplier(context: UnsafeMutableRawPointer?, dependency: indexstore_unit_dependency_t?) -> Bool {
    guard let dependency, indexstore_shim_unit_dependency_get_kind(dependency) == INDEXSTORE_UNIT_DEPENDENCY_RECORD else { return true }
    let recordName = rawIndexStoreString(indexstore_shim_unit_dependency_get_name(dependency))
    let filepath = rawIndexStoreString(indexstore_shim_unit_dependency_get_filepath(dependency))
    context!.assumingMemoryBound(to: [(recordName: String, filepath: String)].self).pointee.append((recordName, filepath))
    return true
}

private struct RawRecordScanState {
    let client: UnsafeMutableRawPointer
    let filepath: String
}

private func rawIndexStoreOccurrenceApplier(context: UnsafeMutableRawPointer?, occurrence: indexstore_occurrence_t?) -> Bool {
    guard let occurrence else { return true }
    let recordState = context!.assumingMemoryBound(to: RawRecordScanState.self).pointee
    let client = Unmanaged<RawIndexStoreClient>.fromOpaque(recordState.client).takeUnretainedValue()
    let filepath = recordState.filepath

    let symbol = indexstore_shim_occurrence_get_symbol(occurrence)
    let usr = rawIndexStoreString(indexstore_shim_symbol_get_usr(symbol))
    let name = rawIndexStoreString(indexstore_shim_symbol_get_name(symbol))
    let roles = indexstore_shim_occurrence_get_roles(occurrence)
    var line: UInt32 = 0, column: UInt32 = 0
    indexstore_shim_occurrence_get_line_col(occurrence, &line, &column)
    let location = SymbolLocation(file: filepath, line: Int(line), column: Int(column))

    if roles & INDEXSTORE_SYMBOL_ROLE_DEFINITION != 0 {
        client.definedSymbolsByFile[filepath, default: []].append(IndexedSymbol(usr: usr, name: name, location: location))
    }

    var rawRelations: [RawRelation] = []
    withUnsafeMutablePointer(to: &rawRelations) { relationsPointer in
        _ = indexstore_shim_occurrence_relations_apply_f(occurrence, relationsPointer, rawIndexStoreRelationApplier)
    }
    // `rawIndexStoreRelationApplier` runs with no visibility into the occurrence's own role
    // (its context pointer only carries the relation-accumulator array) -- stamped here instead,
    // once, since `roles` is already in scope at this call site.
    let relations = rawRelations.map { RawRelation(role: $0.role, targetUSR: $0.targetUSR, targetName: $0.targetName, occurrenceRoles: roles) }

    if !relations.isEmpty {
        client.relationsBySymbolUSR[usr, default: []].append(contentsOf: relations)
        for relation in relations {
            client.relatedToUSR[relation.targetUSR, default: []].append(RawRelation(role: relation.role, targetUSR: usr, targetName: name, occurrenceRoles: roles))
        }
    }

    if roles & INDEXSTORE_SYMBOL_ROLE_CALL != 0,
       let callerUSR = relations.first(where: { $0.role & INDEXSTORE_SYMBOL_ROLE_REL_CALLEDBY != 0 })?.targetUSR {
        let edge = CallGraphEdge(callerUSR: callerUSR, calleeUSR: usr, location: location)
        // See `pendingSetterEdges`'s own doc comment: a `setter:`-named occurrence is never added
        // directly here -- it's only a real edge if this exact position never also carried a
        // `getter:`-named one, which can't be known until the whole store has been scanned.
        if name.hasPrefix("setter:") {
            client.pendingSetterEdges.append((location, edge))
        } else {
            if name.hasPrefix("getter:") {
                client.getterCallLocations.insert(location)
            }
            client.callEdgesByCallee[usr, default: []].append(edge)
            client.callEdgesByFile[filepath, default: []].append(edge)
        }
    }
    return true
}

private func rawIndexStoreRelationApplier(context: UnsafeMutableRawPointer?, relation: indexstore_symbol_relation_t?) -> Bool {
    guard let relation else { return true }
    let role = indexstore_shim_symbol_relation_get_roles(relation)
    let targetSymbol = indexstore_shim_symbol_relation_get_symbol(relation)
    let targetUSR = rawIndexStoreString(indexstore_shim_symbol_get_usr(targetSymbol))
    let targetName = rawIndexStoreString(indexstore_shim_symbol_get_name(targetSymbol))
    context!.assumingMemoryBound(to: [RawRelation].self).pointee.append(RawRelation(role: role, targetUSR: targetUSR, targetName: targetName, occurrenceRoles: 0))
    return true
}
