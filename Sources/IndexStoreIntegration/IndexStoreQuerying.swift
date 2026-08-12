import Foundation
import IsolationCore

/// A definition-role symbol occurrence found by scanning one file's real index data --
/// deliberately minimal (just enough for USR-linking), not a leak of any specific index reader's
/// own internal types.
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

/// Narrow protocol surface over the real index store, so anything downstream that needs call-
/// graph/symbol data can be tested against a fake without a real index store. Mirrors exactly the
/// queries the architecture spec's hybrid design needs (section 2.1-2.2): symbols in a file (for
/// USR-linking against Phase 1's syntactic `DeclarationInfo`s) and the call graph for a USR.
/// `RawIndexStoreClient` is the sole real conformer (`docs/task-raw-indexstore-spike.md`) -- kept
/// as its own protocol, separate from that one concrete type, so fakes/tests don't need a real
/// index store at all.
public protocol IndexStoreQuerying: Sendable {
    func definedSymbols(inFile path: String) -> [IndexedSymbol]
    func callGraphEdges(forUSR usr: String) -> [CallGraphEdge]
    func callSites(inFile path: String) -> [CallGraphEdge]
    func owningPropertyUSR(forUSR usr: String) -> String?
    func baseTypeUSRs(forUSR usr: String) -> [(usr: String, name: String)]
    func containingExtensionUSR(forMemberUSR usr: String) -> String?
    func extendedTypeUSR(forExtensionUSR usr: String) -> String?
}
