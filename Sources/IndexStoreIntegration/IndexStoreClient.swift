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
}
