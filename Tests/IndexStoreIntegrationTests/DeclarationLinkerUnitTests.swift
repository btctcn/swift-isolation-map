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
    var callSitesByFile: [String: [CallGraphEdge]] = [:]
    var owningPropertyUSRByAccessorUSR: [String: String] = [:]
    var baseTypeUSRsByUSR: [String: [(usr: String, name: String)]] = [:]
    var containingExtensionUSRByMemberUSR: [String: String] = [:]
    var extendedTypeUSRByExtensionUSR: [String: String] = [:]
    private(set) var extendedTypeUSRCallCount = 0

    func definedSymbols(inFile path: String) -> [IndexedSymbol] {
        symbolsByFile[path] ?? []
    }

    func callGraphEdges(forUSR usr: String) -> [CallGraphEdge] {
        callEdgesByUSR[usr] ?? []
    }

    func callSites(inFile path: String) -> [CallGraphEdge] {
        callSitesByFile[path] ?? []
    }

    func owningPropertyUSR(forUSR usr: String) -> String? {
        owningPropertyUSRByAccessorUSR[usr]
    }

    func baseTypeUSRs(forUSR usr: String) -> [(usr: String, name: String)] {
        baseTypeUSRsByUSR[usr] ?? []
    }

    func containingExtensionUSR(forMemberUSR usr: String) -> String? {
        containingExtensionUSRByMemberUSR[usr]
    }

    func extendedTypeUSR(forExtensionUSR usr: String) -> String? {
        extendedTypeUSRCallCount += 1
        return extendedTypeUSRByExtensionUSR[usr]
    }
}

private func makeDeclaration(usr: String, name: String, location: SymbolLocation?, containingTypeUSR: String? = nil, superclassUSR: String? = nil, conformances: [ProtocolConformance] = [], isNestedType: Bool = false) -> DeclarationInfo {
    DeclarationInfo(usr: usr, name: name, containingTypeUSR: containingTypeUSR, superclassUSR: superclassUSR, conformances: conformances, isNestedType: isNestedType, location: location)
}

private func placeholderConformance(_ protocolUSR: String) -> ProtocolConformance {
    ProtocolConformance(protocolUSR: protocolUSR, protocolGlobalActorName: nil, declaredInSameFileAsPrimaryDefinition: false, declaredInSameContextAsWitness: true)
}

// MARK: - Gap B Phase I2: `.baseOf`-based inheritance resolution

@Test("A project-local protocol conformance resolves via the .baseOf relation query, on both the nominal's own entry and a member's propagated copy")
func baseOfResolutionRewritesNominalAndMemberCopy() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:Widget", name: "Widget", location: location)]
    fake.baseTypeUSRsByUSR["s:Widget"] = [(usr: "s:P", name: "P")]

    let nominal = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: location, conformances: [placeholderConformance("syntactic:P")])
    let member = makeDeclaration(usr: "syntactic:Widget.foo#0", name: "foo", location: nil, containingTypeUSR: "syntactic:Widget", conformances: [placeholderConformance("syntactic:P")])

    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [nominal, member], protocolGlobalActorNames: [:])])

    let linkedNominal = try #require(linked.declarations["s:Widget"])
    #expect(linkedNominal.conformances.first?.protocolUSR == "s:P")

    let linkedMember = try #require(linked.declarations.values.first { $0.name == "foo" })
    #expect(linkedMember.conformances.first?.protocolUSR == "s:P")
}

@Test("An external (SDK) protocol conformance resolves via the .baseOf relation query the same way a project-local one does")
func baseOfResolutionResolvesExternalProtocol() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:Widget", name: "Widget", location: location)]
    fake.baseTypeUSRsByUSR["s:Widget"] = [(usr: "c:objc(pl)UITableViewDataSource", name: "UITableViewDataSource")]

    let member = makeDeclaration(usr: "syntactic:Widget.tableView#0", name: "tableView", location: nil, containingTypeUSR: "syntactic:Widget", conformances: [placeholderConformance("syntactic:UITableViewDataSource")])
    let nominal = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: location)

    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [nominal, member], protocolGlobalActorNames: [:])])

    let linkedMember = try #require(linked.declarations.values.first { $0.name == "tableView" })
    #expect(linkedMember.conformances.first?.protocolUSR == "c:objc(pl)UITableViewDataSource")
}

@Test("A same-bare-name collision among a nominal's base types is skipped, not guessed")
func baseOfResolutionSkipsSameBareNameCollision() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:Widget", name: "Widget", location: location)]
    // Two distinct real base types that both trim to the same bare name "Foo".
    fake.baseTypeUSRsByUSR["s:Widget"] = [(usr: "s:ModuleA.Foo", name: "Foo"), (usr: "s:ModuleB.Foo", name: "Foo")]

    let nominal = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: location, conformances: [placeholderConformance("syntactic:Foo")])
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [nominal], protocolGlobalActorNames: [:])])

    let linkedNominal = try #require(linked.declarations["s:Widget"])
    #expect(linkedNominal.conformances.first?.protocolUSR == "syntactic:Foo")
}

@Test("A superclass reference whose nominal never resolved to a real USR is left as the placeholder, not guessed")
func baseOfResolutionLeavesPlaceholderWhenNominalUnresolved() throws {
    let fake = FakeIndexStoreQuerying()
    // No symbolsByFile entry at all -- Widget's own declaration never resolves to a real USR
    // (the extension-only-type limitation this file's own header comment already documents).
    let nominal = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: nil, superclassUSR: "syntactic:Base")
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [nominal], protocolGlobalActorNames: [:])])

    let linkedNominal = try #require(linked.declarations["syntactic:Widget"])
    #expect(linkedNominal.superclassUSR == "syntactic:Base")
}

@Test("A bare-name reference to a nested type resolves via the unique qualified-key fallback")
func nestingMismatchFallbackResolvesUniqueQualifiedKey() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:Inner", name: "Inner", location: location)]

    // `Inner`'s own declaration placeholder is qualified ("syntactic:Outer.Inner"), but a
    // reference to it from an inheritance clause is always a bare name ("syntactic:Inner") --
    // confirmed a real mismatch by reading `SyntacticIdentity.typeUSR(_:)` vs. `typeUSR(named:)`.
    let inner = makeDeclaration(usr: "syntactic:Outer.Inner", name: "Inner", location: location, isNestedType: true)
    let referencer = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: nil, superclassUSR: "syntactic:Inner")

    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [inner, referencer], protocolGlobalActorNames: [:])])

    let linkedReferencer = try #require(linked.declarations["syntactic:Widget"])
    #expect(linkedReferencer.superclassUSR == "s:Inner")
}

@Test("Multiple same-bare-name nested types leave the bare-name reference unresolved rather than guessing")
func nestingMismatchFallbackSkipsAmbiguousBareName() throws {
    let fake = FakeIndexStoreQuerying()
    let locationA = SymbolLocation(file: "/a.swift", line: 1, column: 1)
    let locationB = SymbolLocation(file: "/b.swift", line: 1, column: 1)
    fake.symbolsByFile["/a.swift"] = [IndexedSymbol(usr: "s:A.Inner", name: "Inner", location: locationA)]
    fake.symbolsByFile["/b.swift"] = [IndexedSymbol(usr: "s:B.Inner", name: "Inner", location: locationB)]

    let innerA = makeDeclaration(usr: "syntactic:A.Inner", name: "Inner", location: locationA, isNestedType: true)
    let innerB = makeDeclaration(usr: "syntactic:B.Inner", name: "Inner", location: locationB, isNestedType: true)
    let referencer = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: nil, superclassUSR: "syntactic:Inner")

    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [innerA, innerB, referencer], protocolGlobalActorNames: [:])])

    let linkedReferencer = try #require(linked.declarations["syntactic:Widget"])
    #expect(linkedReferencer.superclassUSR == "syntactic:Inner")
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

@Test("Both callerUSR and calleeUSR are canonicalized through owningPropertyUSR when either side is a synthesized accessor")
func bothSidesOfAnEdgeAreCanonicalizedThroughAccessorOwner() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:real", name: "target", location: location)]
    // The raw edge IndexStoreDB reports: a property observer's own synthesized-accessor USR
    // calling into another property's synthesized-accessor USR.
    fake.callEdgesByUSR["s:real"] = [
        CallGraphEdge(callerUSR: "s:willSetAccessor", calleeUSR: "s:real", location: location)
    ]
    fake.owningPropertyUSRByAccessorUSR["s:willSetAccessor"] = "s:observedProperty"
    fake.owningPropertyUSRByAccessorUSR["s:real"] = "s:realProperty"

    let declaration = makeDeclaration(usr: "syntactic:target", name: "target", location: location)
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    let edge = try #require(linked.callGraph.first)
    #expect(edge.callerUSR == "s:observedProperty")
    #expect(edge.calleeUSR == "s:realProperty")
}

@Test("An edge whose USRs are not accessors at all pass through unchanged")
func nonAccessorEdgePassesThroughUnchanged() {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:real", name: "target", location: location)]
    let expectedEdge = CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:real", location: location)
    fake.callEdgesByUSR["s:real"] = [expectedEdge]
    // owningPropertyUSRByAccessorUSR left empty -- neither USR is an accessor.

    let declaration = makeDeclaration(usr: "syntactic:target", name: "target", location: location)
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    #expect(linked.callGraph == [expectedEdge])
}

@Test("A call site whose callee is external (not a project-local USR) is folded into callGraph -- the case callGraphEdges(forUSR:) can never surface on its own")
func externalCallSiteIsFoldedIntoCallGraph() {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:caller", name: "caller", location: location)]
    let externalEdge = CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:external.NotInThisProject", location: location)
    fake.callSitesByFile["/f.swift"] = [externalEdge]

    let declaration = makeDeclaration(usr: "syntactic:caller", name: "caller", location: location)
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    #expect(linked.callGraph.contains(externalEdge))
}

@Test("A call site whose callee is already a known project-local USR is not duplicated into callGraph")
func knownCallSiteIsNotDuplicated() {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:real", name: "target", location: location)]
    let expectedEdge = CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:real", location: location)
    fake.callEdgesByUSR["s:real"] = [expectedEdge]
    // The same edge, also surfaced via callSites(inFile:) -- must not appear twice in callGraph.
    fake.callSitesByFile["/f.swift"] = [expectedEdge]

    let declaration = makeDeclaration(usr: "syntactic:target", name: "target", location: location)
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    #expect(linked.callGraph == [expectedEdge])
}

// MARK: - Extension-of-an-external-type fix (docs/task-external-type-extension-isolation.md)

@Test("A member's containingTypeUSR resolves via the .childOf/.extendedBy chain when the extended type has no primary declaration")
func extensionContainingTypeResolvesViaChildOfExtendedByChain() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:realMethod", name: "method", location: location)]
    fake.containingExtensionUSRByMemberUSR["s:realMethod"] = "s:extensionUSR"
    fake.extendedTypeUSRByExtensionUSR["s:extensionUSR"] = "c:objc(cs)ExternalType"

    let member = makeDeclaration(usr: "syntactic:Widget.method#0", name: "method", location: location, containingTypeUSR: "syntactic:ExternalType")
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [member], protocolGlobalActorNames: [:])])

    let linkedMember = try #require(linked.declarations["s:realMethod"])
    #expect(linkedMember.containingTypeUSR == "c:objc(cs)ExternalType")
}

@Test("Hop 2 (.extendedBy) is memoized per distinct extension USR, not queried once per member")
func extensionContainingTypeHop2IsMemoizedPerExtension() throws {
    let fake = FakeIndexStoreQuerying()
    let location1 = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let location2 = SymbolLocation(file: "/f.swift", line: 2, column: 1)
    fake.symbolsByFile["/f.swift"] = [
        IndexedSymbol(usr: "s:realMethod1", name: "method1", location: location1),
        IndexedSymbol(usr: "s:realMethod2", name: "method2", location: location2)
    ]
    // Both members declared in the same extension block -- same hop-1 answer.
    fake.containingExtensionUSRByMemberUSR["s:realMethod1"] = "s:extensionUSR"
    fake.containingExtensionUSRByMemberUSR["s:realMethod2"] = "s:extensionUSR"
    fake.extendedTypeUSRByExtensionUSR["s:extensionUSR"] = "c:objc(cs)ExternalType"

    let member1 = makeDeclaration(usr: "syntactic:Widget.method1#0", name: "method1", location: location1, containingTypeUSR: "syntactic:ExternalType")
    let member2 = makeDeclaration(usr: "syntactic:Widget.method2#1", name: "method2", location: location2, containingTypeUSR: "syntactic:ExternalType")
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [member1, member2], protocolGlobalActorNames: [:])])

    #expect(fake.extendedTypeUSRCallCount == 1)
    #expect(linked.declarations["s:realMethod1"]?.containingTypeUSR == "c:objc(cs)ExternalType")
    #expect(linked.declarations["s:realMethod2"]?.containingTypeUSR == "c:objc(cs)ExternalType")
}

@Test("Resolution is per-extension, not per-bare-name: two same-named extended types in different modules resolve independently")
func extensionContainingTypeResolutionIsPerExtensionNotPerBareName() throws {
    let fake = FakeIndexStoreQuerying()
    let location1 = SymbolLocation(file: "/a.swift", line: 1, column: 1)
    let location2 = SymbolLocation(file: "/b.swift", line: 1, column: 1)
    fake.symbolsByFile["/a.swift"] = [IndexedSymbol(usr: "s:methodA", name: "methodA", location: location1)]
    fake.symbolsByFile["/b.swift"] = [IndexedSymbol(usr: "s:methodB", name: "methodB", location: location2)]
    // Two distinct extension blocks, both extending something named "SameName" -- but in two
    // different modules, hence two different real extended-type USRs.
    fake.containingExtensionUSRByMemberUSR["s:methodA"] = "s:extensionA"
    fake.containingExtensionUSRByMemberUSR["s:methodB"] = "s:extensionB"
    fake.extendedTypeUSRByExtensionUSR["s:extensionA"] = "c:objc(cs)ModuleA.SameName"
    fake.extendedTypeUSRByExtensionUSR["s:extensionB"] = "c:objc(cs)ModuleB.SameName"

    // Both members' own syntactic placeholder shares the exact same bare-name containingTypeUSR
    // today -- the pre-fix collision this test exists to rule out.
    let memberA = makeDeclaration(usr: "syntactic:SameName.methodA#0", name: "methodA", location: location1, containingTypeUSR: "syntactic:SameName")
    let memberB = makeDeclaration(usr: "syntactic:SameName.methodB#0", name: "methodB", location: location2, containingTypeUSR: "syntactic:SameName")
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [memberA, memberB], protocolGlobalActorNames: [:])])

    #expect(linked.declarations["s:methodA"]?.containingTypeUSR == "c:objc(cs)ModuleA.SameName")
    #expect(linked.declarations["s:methodB"]?.containingTypeUSR == "c:objc(cs)ModuleB.SameName")
}

@Test("A member whose own USR never resolved to a real USR is left unchanged -- no hop-1 entry point")
func extensionContainingTypeLeftUnchangedWhenMemberUSRUnresolved() throws {
    let fake = FakeIndexStoreQuerying()
    // No symbolsByFile entry at all -- the member's own placeholder never resolves to a real USR.
    let member = makeDeclaration(usr: "syntactic:Widget.method#0", name: "method", location: nil, containingTypeUSR: "syntactic:ExternalType")
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [member], protocolGlobalActorNames: [:])])

    let linkedMember = try #require(linked.declarations["syntactic:Widget.method#0"])
    #expect(linkedMember.containingTypeUSR == "syntactic:ExternalType")
}

@Test("A member whose hop-1/hop-2 chain doesn't resolve is left unchanged, not guessed")
func extensionContainingTypeLeftUnchangedWhenChainMisses() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:realMethod", name: "method", location: location)]
    // containingExtensionUSRByMemberUSR left empty -- hop 1 misses entirely.

    let member = makeDeclaration(usr: "syntactic:Widget.method#0", name: "method", location: location, containingTypeUSR: "syntactic:ExternalType")
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [member], protocolGlobalActorNames: [:])])

    #expect(linked.declarations["s:realMethod"]?.containingTypeUSR == "syntactic:ExternalType")
}

// MARK: - Cross-file type-entry collision fix (docs/task-cross-file-type-entry-collision.md)

@Test("DeclarationLinker.merged(_:_:) prefers a non-nil superclassUSR/location/isActorType/explicitIsolation from either side")
func mergedPrefersNonNilSingularFields() {
    let rich = DeclarationInfo(
        usr: "s:real", name: "AppDelegate", explicitIsolation: nil, isActorType: false,
        superclassUSR: "s:Base", conformances: [], location: SymbolLocation(file: "/AppDelegate.swift", line: 8, column: 7)
    )
    let empty = DeclarationInfo(usr: "s:real", name: "AppDelegate", conformances: [])

    let merged = DeclarationLinker.merged(rich, empty)
    #expect(merged.superclassUSR == "s:Base")
    #expect(merged.location == SymbolLocation(file: "/AppDelegate.swift", line: 8, column: 7))

    // Order shouldn't matter for which side contributes the fact.
    let mergedReversed = DeclarationLinker.merged(empty, rich)
    #expect(mergedReversed.superclassUSR == "s:Base")
    #expect(mergedReversed.location == SymbolLocation(file: "/AppDelegate.swift", line: 8, column: 7))
}

@Test("DeclarationLinker.merged(_:_:) concatenates conformances from both sides rather than picking one")
func mergedConcatenatesConformances() {
    let conformanceA = placeholderConformance("syntactic:ProtoA")
    let conformanceB = placeholderConformance("syntactic:ProtoB")
    let fileA = DeclarationInfo(usr: "s:real", name: "AppDelegate", conformances: [conformanceA])
    let fileB = DeclarationInfo(usr: "s:real", name: "AppDelegate", conformances: [conformanceB])

    let merged = DeclarationLinker.merged(fileA, fileB)
    let mergedProtocolUSRs = Set(merged.conformances.map(\.protocolUSR))
    #expect(mergedProtocolUSRs == ["syntactic:ProtoA", "syntactic:ProtoB"])
}

@Test("DeclarationLinker.merged(_:_:) is conservative (AND) for isEligibleForModuleDefaultIsolation")
func mergedIsConservativeForModuleDefaultEligibility() {
    let eligible = DeclarationInfo(usr: "s:real", name: "Widget", conformances: [], isEligibleForModuleDefaultIsolation: true)
    let ineligible = DeclarationInfo(usr: "s:real", name: "Widget", conformances: [], isEligibleForModuleDefaultIsolation: false)

    #expect(DeclarationLinker.merged(eligible, ineligible).isEligibleForModuleDefaultIsolation == false)
    #expect(DeclarationLinker.merged(ineligible, eligible).isEligibleForModuleDefaultIsolation == false)
    #expect(DeclarationLinker.merged(eligible, eligible).isEligibleForModuleDefaultIsolation == true)
}

@Test("link(_:) merges a type's primary-declaration entry with its extension-in-a-different-file entry, regardless of processing order")
func linkMergesCrossFileTypeEntriesRegardlessOfOrder() throws {
    let location = SymbolLocation(file: "/AppDelegate.swift", line: 1, column: 7)
    let conformanceFromPrimaryFile = placeholderConformance("syntactic:ProductNotificationSchedulerDelegate")
    let conformanceFromExtensionFile = placeholderConformance("syntactic:InAppMessagesDelegate")

    // Primary file: real location, a superclass, one conformance -- mirrors `AppDelegate.swift`
    // itself (`class AppDelegate: MindboxAppDelegate, ...`).
    let primaryFileEntry = makeDeclaration(
        usr: "syntactic:AppDelegate", name: "AppDelegate", location: location,
        superclassUSR: "syntactic:MindboxAppDelegate", conformances: [conformanceFromPrimaryFile]
    )
    // A different file's own extension of the same type: no location (no primary declaration in
    // that file), no superclass, a *different* conformance -- mirrors
    // `AppDelegateGiftCertificateEdgeCasesTests.swift`'s own `extension AppDelegate { ... }`.
    let extensionFileEntry = makeDeclaration(
        usr: "syntactic:AppDelegate", name: "AppDelegate", location: nil, conformances: [conformanceFromExtensionFile]
    )

    let fake = FakeIndexStoreQuerying()
    fake.symbolsByFile["/AppDelegate.swift"] = [IndexedSymbol(usr: "s:realAppDelegate", name: "AppDelegate", location: location)]

    for order in [[primaryFileEntry, extensionFileEntry], [extensionFileEntry, primaryFileEntry]] {
        let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: order, protocolGlobalActorNames: [:])])
        let merged = try #require(linked.declarations["s:realAppDelegate"])

        #expect(merged.location == location, "real location must survive regardless of processing order")
        #expect(merged.superclassUSR == "syntactic:MindboxAppDelegate", "superclass must survive regardless of processing order")
        let conformanceUSRs = Set(merged.conformances.map(\.protocolUSR))
        #expect(
            conformanceUSRs == ["syntactic:ProductNotificationSchedulerDelegate", "syntactic:InAppMessagesDelegate"],
            "both files' conformances must be present regardless of processing order"
        )
    }
}
