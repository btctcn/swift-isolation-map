import Foundation
import Testing
import IsolationCore
import SyntaxAnalysis
@testable import IndexStoreIntegration

/// Canned-data unit tests for `DeclarationLinker`'s matching/disambiguation algorithm --
/// deliberately no real index store involved (that's `DeclarationLinkerTests.swift`'s golden-
/// fixture test), per the architecture spec's testing strategy: pure logic gets unit tests
/// against fixtures, real end-to-end behavior gets a separate golden-fixture test.
final class FakeIndexStoreQuerying: IndexStoreQuerying, @unchecked Sendable {
    var symbolsByFile: [String: [IndexedSymbol]] = [:]
    var callEdgesByUSR: [String: [CallGraphEdge]] = [:]

    func definedSymbols(inFile path: String) -> [IndexedSymbol] {
        symbolsByFile[path] ?? []
    }

    func callGraphEdges(forUSR usr: String) -> [CallGraphEdge] {
        callEdgesByUSR[usr] ?? []
    }
}

private func makeDeclaration(usr: String, name: String, location: SymbolLocation?, containingTypeUSR: String? = nil, conformances: [ProtocolConformance] = []) -> DeclarationInfo {
    DeclarationInfo(usr: usr, name: name, containingTypeUSR: containingTypeUSR, conformances: conformances, location: location)
}

@Test("A single candidate at a location resolves without needing a name match")
func singleCandidateResolvesWithoutNameMatch() {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:real", name: "TotallyDifferentName", location: location)]

    let declaration = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: location)
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    #expect(linked.declarations["s:real"] != nil)
    #expect(linked.declarations["syntactic:Widget"] == nil)
}

@Test("Multiple candidates at the same location disambiguate by exact name match")
func multipleCandidatesDisambiguateByExactName() {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 2, column: 9)
    fake.symbolsByFile["/f.swift"] = [
        IndexedSymbol(usr: "s:getter", name: "getter:currentUser", location: location),
        IndexedSymbol(usr: "s:setter", name: "setter:currentUser", location: location),
        IndexedSymbol(usr: "s:property", name: "currentUser", location: location)
    ]

    let declaration = makeDeclaration(usr: "syntactic:Foo.currentUser#0", name: "currentUser", location: location)
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    #expect(linked.declarations["s:property"] != nil)
    #expect(linked.declarations["s:getter"] == nil)
    #expect(linked.declarations["s:setter"] == nil)
}

@Test("Multiple candidates disambiguate by prefix-before-parenthesis for a method with parameter labels")
func multipleCandidatesDisambiguateByPrefix() {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 4, column: 10)
    fake.symbolsByFile["/f.swift"] = [
        IndexedSymbol(usr: "s:unrelated", name: "loginAttempt", location: location),
        IndexedSymbol(usr: "s:login", name: "login(as:)", location: location)
    ]

    // DeclarationInfo.name is the bare base name (matches SwiftSyntax's node.name.text), while
    // IndexStoreDB's symbol name includes parameter labels -- this is the real, empirically-
    // confirmed mismatch the prefix heuristic exists for.
    let declaration = makeDeclaration(usr: "syntactic:Foo.login#0", name: "login", location: location)
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    #expect(linked.declarations["s:login"] != nil)
    #expect(linked.declarations["s:unrelated"] == nil)
}

@Test("An unresolvable ambiguity (no name signal at all) leaves the placeholder USR rather than guessing")
func unresolvableAmbiguityLeavesPlaceholder() {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [
        IndexedSymbol(usr: "s:one", name: "somethingElse", location: location),
        IndexedSymbol(usr: "s:two", name: "somethingDifferent", location: location)
    ]

    let declaration = makeDeclaration(usr: "syntactic:Ambiguous", name: "Ambiguous", location: location)
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    #expect(linked.declarations["syntactic:Ambiguous"] != nil)
    #expect(linked.declarations["s:one"] == nil)
    #expect(linked.declarations["s:two"] == nil)
}

@Test("A conformance to a protocol declared in a different file gets protocolGlobalActorName backfilled from the merged map")
func conformanceBackfillsGlobalActorNameFromMergedMap() throws {
    let fake = FakeIndexStoreQuerying()
    // Simulates: Protocol.swift declares `@MainActor protocol Refreshable`, contributing
    // "Refreshable" -> "MainActor" to its own ExtractionResult's protocolGlobalActorNames --
    // but SyncCoordinator.swift's own extraction (a different file) never saw that protocol
    // declaration, so its conformance came out with protocolGlobalActorName == nil.
    let conformance = ProtocolConformance(
        protocolUSR: "syntactic:Refreshable",
        protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: false,
        declaredInSameContextAsWitness: true
    )
    let witness = makeDeclaration(usr: "syntactic:SyncCoordinator.refresh#0", name: "refresh", location: nil, conformances: [conformance])

    let extractionResults = [
        ExtractionResult(declarations: [witness], protocolGlobalActorNames: [:]),
        ExtractionResult(declarations: [], protocolGlobalActorNames: ["Refreshable": "MainActor"])
    ]
    let linked = DeclarationLinker(indexStore: fake).link(extractionResults)

    let linkedWitness = try #require(linked.declarations.values.first { $0.name == "refresh" })
    #expect(linkedWitness.conformances.first?.protocolGlobalActorName == "MainActor")
}

@Test("callGraphEdges are fetched for every real USR that was successfully linked")
func callGraphEdgesFetchedForLinkedUSRs() {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:real", name: "target", location: location)]
    let expectedEdge = CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:real", location: location)
    fake.callEdgesByUSR["s:real"] = [expectedEdge]

    let declaration = makeDeclaration(usr: "syntactic:target", name: "target", location: location)
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    #expect(linked.callGraph == [expectedEdge])
}
