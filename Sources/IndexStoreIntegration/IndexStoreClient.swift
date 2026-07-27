import Foundation
import IsolationCore
import IndexStoreDB

/// A definition-role symbol occurrence found by scanning one file's real index data --
/// deliberately minimal (just enough for USR-linking), not a leak of IndexStoreDB's own types.
public struct IndexedSymbol: Equatable, Sendable {
    public let usr: String
    public let name: String
    public let location: IsolationCore.SymbolLocation

    public init(usr: String, name: String, location: IsolationCore.SymbolLocation) {
        self.usr = usr
        self.name = name
        self.location = location
    }
}

/// Narrow protocol surface over IndexStoreDB's real API, so anything downstream that needs call-
/// graph/symbol data can be tested against a fake without a real index store. Mirrors exactly the
/// two queries the architecture spec's hybrid design needs (section 2.1-2.2): symbols in a file
/// (for USR-linking against Phase 1's syntactic `DeclarationInfo`s) and the call graph for a USR.
public protocol IndexStoreQuerying: Sendable {
    func definedSymbols(inFile path: String) -> [IndexedSymbol]
    func callGraphEdges(forUSR usr: String) -> [CallGraphEdge]
    func callSites(inFile path: String) -> [CallGraphEdge]
    func owningPropertyUSR(forUSR usr: String) -> String?
    func baseTypeUSRs(forUSR usr: String) -> [(usr: String, name: String)]
}

/// Wraps `IndexStoreDB`/`IndexStoreLibrary` -- confirmed working end to end against a real
/// toolchain and a real index store in the Phase 0 spike (docs/priority-2-phase-0-spike.md).
/// `libIndexStore` is `dlopen`'d at runtime via `toolchainLocator`, never linked at build time.
///
/// `@unchecked Sendable`: `IndexStoreDB` (the C++-backed class this wraps) predates Swift
/// concurrency and isn't itself marked `Sendable`, but it's an index database designed for
/// concurrent read access from multiple query sites (that's the entire point of `sourcekit-lsp`
/// sharing one instance across concurrent requests) -- read-only queries after initialization are
/// safe. This wrapper exposes no mutable state of its own.
public final class IndexStoreClient: IndexStoreQuerying, @unchecked Sendable {
    private let db: IndexStoreDB

    /// Serializes `IndexStoreLibrary`/`IndexStoreDB` *construction* only (not queries after
    /// initialization) across concurrently-running `IndexStoreClient` instances -- defensive,
    /// since `dlopen`/library-loading global state in the C++ layer is a plausible concurrent-
    /// initialization risk even though concurrent *reads* afterward are fine (per `sourcekit-lsp`
    /// sharing one already-initialized instance across concurrent requests). Added while
    /// investigating an intermittent test-suite segfault; kept as reasonable defensive practice,
    /// but the actual root cause of that segfault turned out to be unrelated (a debug-build-only
    /// crash in the swift-testing/Swift-runtime combination once this C++ dependency is linked
    /// into the same test bundle -- release builds are unaffected). See
    /// docs/priority-2-phase-3-linking.md for the full investigation; CI runs tests in release
    /// configuration because of this finding.
    private static let initializationLock = NSLock()

    public init(storePath: String, databasePath: String, toolchainLocator: ToolchainLocating = LiveToolchainLocator()) throws {
        Self.initializationLock.lock()
        defer { Self.initializationLock.unlock() }
        let dylibPath = try toolchainLocator.libIndexStorePath()
        let library = try IndexStoreLibrary(dylibPath: dylibPath)
        self.db = try IndexStoreDB(
            storePath: storePath,
            databasePath: databasePath,
            library: library,
            waitUntilDoneInitializing: true
        )
    }

    /// Only `.definition`-role occurrences -- `symbolOccurrences(inFilePath:)` also returns pure
    /// references/calls physically located in this file (e.g. a call to a function declared
    /// elsewhere), which represent *usages*, not declarations, and would be noise for USR-linking
    /// against Phase 1's syntactic `DeclarationInfo`s (which represent declarations only).
    public func definedSymbols(inFile path: String) -> [IndexedSymbol] {
        db.symbolOccurrences(inFilePath: path)
            .filter { $0.roles.contains(.definition) }
            .map {
                IndexedSymbol(
                    usr: $0.symbol.usr,
                    name: $0.symbol.name,
                    location: IsolationCore.SymbolLocation(file: $0.location.path, line: $0.location.line, column: $0.location.utf8Column)
                )
            }
    }

    /// Architecture spec section 2.2's described algorithm ("for each occurrence, find the
    /// containing symbol via `.childOf` relations, walking up") doesn't match IndexStoreDB's
    /// actual relation roles -- verified empirically (a real two-function fixture, one calling
    /// the other): a `.call`-role occurrence's `.relations` carries `.calledBy`/`.containedBy`,
    /// not `.childOf`, pointing directly at the caller. No "walking up" needed; the relation
    /// already names the immediate caller.
    public func callGraphEdges(forUSR usr: String) -> [CallGraphEdge] {
        db.occurrences(ofUSR: usr, roles: .call).compactMap { occurrence in
            guard let callerUSR = occurrence.relations.first(where: { $0.roles.contains(.calledBy) })?.symbol.usr else {
                return nil
            }
            return CallGraphEdge(
                callerUSR: callerUSR,
                calleeUSR: usr,
                location: IsolationCore.SymbolLocation(file: occurrence.location.path, line: occurrence.location.line, column: occurrence.location.utf8Column)
            )
        }
    }

    /// Every `.call`-role occurrence in a file, regardless of whether the callee is a USR this
    /// project already knows about. `callGraphEdges(forUSR:)` is a *reverse* lookup -- it can only
    /// ever be queried with a USR the caller already has in hand, which today means every USR ever
    /// passed to it is project-local (`DeclarationLinker.link` calls it once per real USR in its
    /// own rewrite map). That means the combined call graph this project builds today can
    /// structurally never contain an edge whose *callee* is external -- confirmed by reading both
    /// call sites, not assumed. This query closes that gap: scanning by *file* rather than by
    /// known USR surfaces calls to external callees too (needed for the compiled-dependency-
    /// isolation oracle's edge-level trigger, see docs/task-compiled-dependency-isolation.md).
    /// Maps a synthesized property/subscript accessor's own USR (getter/setter/willSet/didSet)
    /// back to the owning property's canonical USR, via IndexStoreDB's `.accessorOf` relation --
    /// `nil` for a USR that isn't an accessor at all, or any other lookup miss. This exists because
    /// `IndexStoreDB`'s call graph (`callGraphEdges`/`callSites` above) records a property
    /// read/write as a call to the accessor's own *distinct* USR, never the property's -- while
    /// this project's own `declarations` dictionary (and any bulk/live external-isolation oracle
    /// result) is always keyed by the property's single canonical USR. Confirmed empirically
    /// (`DeclarationLinkerTests.swift`'s direction test) which side of the relation carries it,
    /// rather than assumed -- the code that actually populates this relation lives in the Swift
    /// compiler itself, not anything checked out in this repo.
    public func owningPropertyUSR(forUSR usr: String) -> String? {
        db.occurrences(ofUSR: usr, roles: .definition)
            .first?.relations.first(where: { $0.roles.contains(.accessorOf) })?.symbol.usr
    }

    /// Every real supertype/conformed-protocol referenced in `usr`'s own inheritance clause(s),
    /// via IndexStoreDB's `.baseOf` relation ("A is base of B"). Direction and shape confirmed
    /// empirically against a real index store, not assumed from reading
    /// `swiftlang/indexstore-db`'s source alone (`DeclarationLinkerTests.swift`'s direction test,
    /// `cross-file-witness`'s existing `extension SyncCoordinator: Refreshable` fixture) --
    /// mirrors `owningPropertyUSR`'s own verify-before-trust discipline. Two real shapes, both
    /// needed:
    /// 1. **Direct inheritance** (`class C: Base`, declared on the primary declaration itself):
    ///    `occurrences(relatedToUSR: usr, roles: .baseOf)` returns `Base`'s own occurrence
    ///    directly, `usr` being the relation's target.
    /// 2. **Extension-declared conformance** (`extension C: P { ... }`, confirmed the corpus's
    ///    dominant real shape): the `.baseOf` relation's target is *not* `usr` itself but a
    ///    synthetic per-extension USR (IndexStoreDB mangles one from the extension's first
    ///    member, e.g. `s:e:...`) -- found only by first resolving `usr`'s own `.extendedBy`
    ///    relations (`occurrences(ofUSR: usr, roles: .extendedBy)`) to each extension's USR, then
    ///    querying `.baseOf` relative to *that* USR. Confirmed via `debugDump`-style raw relation
    ///    inspection during implementation, matching the research response's own pre-registered
    ///    P1 prediction ("if the relation instead targets the extension symbol, add one hop").
    /// This is a *relation* query, not a name/location match: it resolves a project-local
    /// protocol/superclass reference the same way it resolves an SDK/external one, with no name
    /// tables and no "known SDK name" special-casing.
    public func baseTypeUSRs(forUSR usr: String) -> [(usr: String, name: String)] {
        var results = db.occurrences(relatedToUSR: usr, roles: .baseOf).map { ($0.symbol.usr, $0.symbol.name) }
        let extensionUSRs = db.occurrences(ofUSR: usr, roles: .extendedBy).flatMap { occurrence in
            occurrence.relations.filter { $0.roles.contains(.extendedBy) }.map { $0.symbol.usr }
        }
        for extensionUSR in Set(extensionUSRs) {
            results.append(contentsOf: db.occurrences(relatedToUSR: extensionUSR, roles: .baseOf).map { ($0.symbol.usr, $0.symbol.name) })
        }
        return results
    }

    public func callSites(inFile path: String) -> [CallGraphEdge] {
        db.symbolOccurrences(inFilePath: path)
            .filter { $0.roles.contains(.call) }
            .compactMap { occurrence in
                guard let callerUSR = occurrence.relations.first(where: { $0.roles.contains(.calledBy) })?.symbol.usr else {
                    return nil
                }
                return CallGraphEdge(
                    callerUSR: callerUSR,
                    calleeUSR: occurrence.symbol.usr,
                    location: IsolationCore.SymbolLocation(file: occurrence.location.path, line: occurrence.location.line, column: occurrence.location.utf8Column)
                )
            }
    }
}
