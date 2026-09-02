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

private func makeDeclaration(
    usr: String, name: String, location: SymbolLocation?, containingTypeUSR: String? = nil, superclassUSR: String? = nil,
    conformances: [ProtocolConformance] = [], isNestedType: Bool = false,
    hasPreconcurrencyAttribute: Bool = false, isNonisolatedUnsafe: Bool = false
) -> DeclarationInfo {
    DeclarationInfo(
        usr: usr, name: name, containingTypeUSR: containingTypeUSR, superclassUSR: superclassUSR, conformances: conformances,
        isNestedType: isNestedType, location: location,
        hasPreconcurrencyAttribute: hasPreconcurrencyAttribute, isNonisolatedUnsafe: isNonisolatedUnsafe
    )
}

private func placeholderConformance(_ protocolUSR: String, isUnchecked: Bool = false, isPreconcurrency: Bool = false) -> ProtocolConformance {
    ProtocolConformance(
        protocolUSR: protocolUSR, protocolGlobalActorName: nil, declaredInSameFileAsPrimaryDefinition: false, declaredInSameContextAsWitness: true,
        isUnchecked: isUnchecked, isPreconcurrency: isPreconcurrency
    )
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

@Test("A duplicate, verbatim-identical (name, USR) base-type entry resolves, it is not treated as a collision")
func baseOfResolutionDedupesIdenticalDuplicateEntry() throws {
    // Confirmed against a real project: IndexStoreDB's `.baseOf` relation can report one real
    // base type twice with the exact same USR both times (observed for a direct `UIViewController`
    // subclass) -- this must resolve normally, unlike the genuine same-name-different-USR
    // collision above. The pre-fix version of this loop conflated the two cases, silently leaving
    // the subclass's `superclassUSR` as an unresolved placeholder and its isolation as
    // `nonisolated` instead of inheriting `@MainActor` from `UIViewController`.
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:Widget", name: "Widget", location: location)]
    fake.baseTypeUSRsByUSR["s:Widget"] = [
        (usr: "c:objc(cs)UIViewController", name: "UIViewController"),
        (usr: "c:objc(cs)UIViewController", name: "UIViewController")
    ]

    let nominal = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: location, superclassUSR: "syntactic:UIViewController")
    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [nominal], protocolGlobalActorNames: [:])])

    let linkedNominal = try #require(linked.declarations["s:Widget"])
    #expect(linkedNominal.superclassUSR == "c:objc(cs)UIViewController")
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

@Test("link(_:) backfills a per-requirement (not whole-protocol) global-actor attribute across files, matched by the witness's own name (PlatformView/Swiftfin shape)")
func conformanceBackfillsPerRequirementGlobalActorNameAcrossFiles() throws {
    let fake = FakeIndexStoreQuerying()
    // Simulates: PlatformView.swift declares `protocol PlatformView: View { @MainActor var
    // iOSView: ... { get } }` -- no attribute on the protocol itself, only on this one
    // requirement -- contributing "PlatformView" -> "iOSView" -> "MainActor" to its own
    // ExtractionResult's protocolRequirementGlobalActorNames. LetterPickerBar.swift's own
    // extraction (a different file) never saw that protocol declaration at all.
    let matchingConformance = ProtocolConformance(
        protocolUSR: "syntactic:PlatformView", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: false, declaredInSameContextAsWitness: true
    )
    let matchingWitness = makeDeclaration(usr: "syntactic:LetterPickerBar.iOSView#0", name: "iOSView", location: nil, conformances: [matchingConformance])
    // A different requirement's own copy of the same conformance, on a differently-named member
    // -- must not pick up "iOSView"'s own per-requirement attribute.
    let nonMatchingConformance = ProtocolConformance(
        protocolUSR: "syntactic:PlatformView", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: false, declaredInSameContextAsWitness: true
    )
    let nonMatchingWitness = makeDeclaration(usr: "syntactic:LetterPickerBar.someOtherMember#1", name: "someOtherMember", location: nil, conformances: [nonMatchingConformance])

    let extractionResults = [
        ExtractionResult(declarations: [matchingWitness, nonMatchingWitness], protocolGlobalActorNames: [:]),
        ExtractionResult(declarations: [], protocolGlobalActorNames: [:], protocolRequirementGlobalActorNames: ["PlatformView": ["iOSView": "MainActor"]]),
    ]
    let linked = DeclarationLinker(indexStore: fake).link(extractionResults)

    let linkedMatching = try #require(linked.declarations.values.first { $0.name == "iOSView" })
    #expect(linkedMatching.conformances.first?.protocolGlobalActorName == "MainActor")

    let linkedNonMatching = try #require(linked.declarations.values.first { $0.name == "someOtherMember" })
    #expect(linkedNonMatching.conformances.first?.protocolGlobalActorName == nil)
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

// MARK: - Stray duplicate file poisoning the merged location (issue #123)

@Test("DeclarationLinker.merged(_:_:filesWithIndexedSymbols:) prefers the location backed by real indexed symbols, regardless of which side is `existing`")
func mergedPrefersIndexedLocationOverUnindexed() {
    let realLocation = SymbolLocation(file: "/Widget.swift", line: 3, column: 7)
    let strayLocation = SymbolLocation(file: "/Widget 2.swift", line: 3, column: 7)
    let real = DeclarationInfo(usr: "s:real", name: "Widget", conformances: [], location: realLocation)
    let stray = DeclarationInfo(usr: "s:real", name: "Widget", conformances: [], location: strayLocation)
    let filesWithIndexedSymbols: Set<String> = ["/Widget.swift"]

    // The stray file's own name sorts first lexically (a space, 0x20, sorts before ".", 0x2E) --
    // exactly the real Project Iris shape (docs/task-own-module-declaration-gaps.md §4) that made
    // plain `??` pick it whenever it happened to be `existing`. Both orders must still pick the
    // indexed one.
    #expect(DeclarationLinker.merged(stray, real, filesWithIndexedSymbols: filesWithIndexedSymbols).location == realLocation)
    #expect(DeclarationLinker.merged(real, stray, filesWithIndexedSymbols: filesWithIndexedSymbols).location == realLocation)
}

@Test("DeclarationLinker.merged(_:_:filesWithIndexedSymbols:) falls back to preferring `existing` when both or neither side is indexed")
func mergedFallsBackToExistingWhenIndexingStatusMatches() {
    let locationA = SymbolLocation(file: "/A.swift", line: 1, column: 1)
    let locationB = SymbolLocation(file: "/B.swift", line: 1, column: 1)
    let declA = DeclarationInfo(usr: "s:real", name: "Widget", conformances: [], location: locationA)
    let declB = DeclarationInfo(usr: "s:real", name: "Widget", conformances: [], location: locationB)

    // Neither file indexed (e.g. two stray files sharing a USR) -- no worse than before this fix.
    #expect(DeclarationLinker.merged(declA, declB, filesWithIndexedSymbols: []).location == locationA)
    #expect(DeclarationLinker.merged(declB, declA, filesWithIndexedSymbols: []).location == locationB)

    // Both files indexed (the legitimate two-real-declarations-collide-by-name edge case) -- same
    // unconditional `??`-style behavior as before this fix, since indexing status alone can't
    // distinguish them either.
    let bothIndexed: Set<String> = ["/A.swift", "/B.swift"]
    #expect(DeclarationLinker.merged(declA, declB, filesWithIndexedSymbols: bothIndexed).location == locationA)
    #expect(DeclarationLinker.merged(declB, declA, filesWithIndexedSymbols: bothIndexed).location == locationB)
}

@Test("link(_:) prefers the real, compiled file's location over a stray uncompiled duplicate's, even when the stray file is processed first (real Project Iris SubscriptionNotifCell/\" 2.swift\" shape)")
func linkPrefersIndexedFileOverStrayDuplicate() throws {
    let fake = FakeIndexStoreQuerying()
    let realLocation = SymbolLocation(file: "/SubscriptionNotifCell.swift", line: 5, column: 7)
    // Only the real file has any real indexed symbol -- the stray duplicate was never compiled,
    // exactly the real corpus shape this test reproduces.
    fake.symbolsByFile["/SubscriptionNotifCell.swift"] = [IndexedSymbol(usr: "s:real", name: "SubscriptionNotifCell", location: realLocation)]

    let strayLocation = SymbolLocation(file: "/SubscriptionNotifCell 2.swift", line: 5, column: 7)
    let strayDeclaration = makeDeclaration(usr: "syntactic:SubscriptionNotifCell", name: "SubscriptionNotifCell", location: strayLocation)
    let realDeclaration = makeDeclaration(usr: "syntactic:SubscriptionNotifCell", name: "SubscriptionNotifCell", location: realLocation)

    // Stray file listed *first* -- matching the real bug's own lexical sort (a space sorts before
    // "."), which is exactly what made the stray copy win before this fix, order-dependently.
    let linked = DeclarationLinker(indexStore: fake).link([
        ExtractionResult(declarations: [strayDeclaration, realDeclaration], protocolGlobalActorNames: [:])
    ])

    #expect(try #require(linked.declarations["s:real"]).location == realLocation)
}

// MARK: - Escape-hatch fields must survive linking, not just extraction
// (docs/task-escape-hatch-and-preconcurrency-severity.md) -- a real bug found on a real corpus
// (Kingfisher's own `WeakBox`/`Image.swift` malloc-key `let`s): `DeclarationLinker.link()` rewrites
// a declaration's USR/references through several field-by-field reconstructions, none of which
// listed `hasPreconcurrencyAttribute`/`isNonisolatedUnsafe` (or `ProtocolConformance.isUnchecked`/
// `.isPreconcurrency`) -- silently dropping them back to their `false` defaults on every real
// declaration that passes through `link()`, i.e. every declaration in the whole real report.

@Test("DeclarationLinker.merged(_:_:) preserves hasPreconcurrencyAttribute/isNonisolatedUnsafe from either side (OR, not AND -- only one side's file extraction can ever see the attribute at all)")
func mergedPreservesEscapeHatchFlags() {
    let unsafe = DeclarationInfo(usr: "s:real", name: "counter", conformances: [], isNonisolatedUnsafe: true)
    let plain = DeclarationInfo(usr: "s:real", name: "counter", conformances: [])
    #expect(DeclarationLinker.merged(unsafe, plain).isNonisolatedUnsafe)
    #expect(DeclarationLinker.merged(plain, unsafe).isNonisolatedUnsafe)

    let annotated = DeclarationInfo(usr: "s:real", name: "Widget", conformances: [], hasPreconcurrencyAttribute: true)
    let unannotated = DeclarationInfo(usr: "s:real", name: "Widget", conformances: [])
    #expect(DeclarationLinker.merged(annotated, unannotated).hasPreconcurrencyAttribute)
    #expect(DeclarationLinker.merged(unannotated, annotated).hasPreconcurrencyAttribute)
}

@Test("A real link() pass preserves isNonisolatedUnsafe and hasPreconcurrencyAttribute through USR rewriting -- the exact real-corpus regression (Kingfisher's WeakBox/Image.swift malloc keys)")
func linkPreservesEscapeHatchFlagsThroughUSRRewrite() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:WeakBox", name: "WeakBox", location: location)]

    let unsafeProperty = makeDeclaration(usr: "syntactic:counter#0", name: "counter", location: SymbolLocation(file: "/f.swift", line: 2, column: 1), isNonisolatedUnsafe: true)
    let annotatedType = makeDeclaration(usr: "syntactic:WeakBox", name: "WeakBox", location: location, hasPreconcurrencyAttribute: true)

    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [unsafeProperty, annotatedType], protocolGlobalActorNames: [:])])

    let linkedProperty = try #require(linked.declarations.values.first { $0.name == "counter" })
    #expect(linkedProperty.isNonisolatedUnsafe)
    let linkedType = try #require(linked.declarations["s:WeakBox"])
    #expect(linkedType.hasPreconcurrencyAttribute)
}

@Test("A real link() pass preserves ProtocolConformance.isUnchecked/isPreconcurrency through .baseOf-relation relinking -- the same real-corpus regression, conformance side (Kingfisher's WeakBox: @unchecked Sendable)")
func linkPreservesConformanceEscapeHatchFlagsThroughRelink() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    fake.symbolsByFile["/f.swift"] = [IndexedSymbol(usr: "s:WeakBox", name: "WeakBox", location: location)]
    fake.baseTypeUSRsByUSR["s:WeakBox"] = [(usr: "s:Sendable", name: "Sendable")]

    let nominal = makeDeclaration(
        usr: "syntactic:WeakBox", name: "WeakBox", location: location,
        conformances: [placeholderConformance("syntactic:Sendable", isUnchecked: true)]
    )

    let linked = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [nominal], protocolGlobalActorNames: [:])])

    let linkedNominal = try #require(linked.declarations["s:WeakBox"])
    #expect(linkedNominal.conformances.first?.isUnchecked == true)
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

@Test("link(_:) never rewrites a member's containingTypeUSR/protocolUSR to an unrelated, same-named real type declared in a file that was never compiled (GestureView/Swiftfin shape)")
func linkNeverBleedsAcrossTwoUnrelatedSameNamedTypesInDifferentUncompiledFiles() throws {
    // Real shape confirmed on `Swiftfin`: `GestureView` is declared once for iOS
    // (`Swiftfin/Components/GestureView.swift`, compiled/indexed) and once, completely
    // independently, for tvOS (`Swiftfin tvOS/Components/GestureView.swift`, never compiled when
    // only the iOS scheme is analyzed) -- two wholly unrelated types sharing a bare name.
    let iosLocation = SymbolLocation(file: "/Swiftfin/GestureView.swift", line: 14, column: 8)
    let tvOSMemberLocation = SymbolLocation(file: "/Swiftfin tvOS/GestureView.swift", line: 16, column: 10)

    let iosType = makeDeclaration(usr: "syntactic:GestureView", name: "GestureView", location: iosLocation)
    let iosMember = makeDeclaration(
        usr: "syntactic:GestureView.makeUIView#40", name: "makeUIView", location: SymbolLocation(file: "/Swiftfin/GestureView.swift", line: 16, column: 10),
        containingTypeUSR: "syntactic:GestureView", conformances: [placeholderConformance("syntactic:PlatformViewRepresentable")]
    )
    // The tvOS-only file's own member: a *different* byte offset in its own placeholder `usr`
    // (an unrelated file's own body is never byte-for-byte identical) but the identical bare
    // `containingTypeUSR`/`protocolUSR` strings -- neither file's own syntactic extraction has any
    // notion of the other file at all -- and its own file has zero real indexed symbols: it was
    // never compiled for this analysis.
    let tvOSMember = makeDeclaration(
        usr: "syntactic:GestureView.makeUIView#99", name: "makeUIView", location: tvOSMemberLocation,
        containingTypeUSR: "syntactic:GestureView", conformances: [placeholderConformance("syntactic:PlatformViewRepresentable")]
    )

    let fake = FakeIndexStoreQuerying()
    // Only the iOS file has any real indexed symbols -- the tvOS file is entirely absent from the
    // index, exactly as it would be when only the iOS scheme was built/indexed.
    fake.symbolsByFile["/Swiftfin/GestureView.swift"] = [
        IndexedSymbol(usr: "s:realGestureView", name: "GestureView", location: iosLocation),
        IndexedSymbol(usr: "s:realGestureView.makeUIView", name: "makeUIView", location: SymbolLocation(file: "/Swiftfin/GestureView.swift", line: 16, column: 10)),
    ]

    let linked = DeclarationLinker(indexStore: fake).link([
        ExtractionResult(declarations: [iosType, iosMember], protocolGlobalActorNames: [:]),
        ExtractionResult(declarations: [tvOSMember], protocolGlobalActorNames: [:]),
    ])

    let linkedIOSMember = try #require(linked.declarations["s:realGestureView.makeUIView"])
    #expect(linkedIOSMember.containingTypeUSR == "s:realGestureView", "the real iOS member's own containingTypeUSR must still resolve normally")

    // The tvOS member's own `usr` never matched anything real (its file has no indexed symbols),
    // so it's still keyed by its original placeholder -- find it that way.
    let linkedTVOSMember = try #require(linked.declarations["syntactic:GestureView.makeUIView#99"])
    #expect(
        linkedTVOSMember.containingTypeUSR == "syntactic:GestureView",
        "an uncompiled file's own member must never inherit an unrelated, same-named real type's USR"
    )
    #expect(
        linkedTVOSMember.conformances.first?.protocolUSR == "syntactic:PlatformViewRepresentable",
        "an uncompiled file's own conformance reference must never resolve through an unrelated real type either"
    )
}

// MARK: - Same-bare-name type-declaration collision (issue #95, docs/task-objc-enum-accessor-linking.md §3)

@Test("link(_:) keeps two genuinely different, unrelated types that merely share a bare name as two separate entries, not merged into one (real LogLevel/Project Iris/MindboxLogger shape)")
func linkKeepsTwoUnrelatedSameNamedCompiledTypesSeparate() throws {
    // Real shape confirmed on Project Iris: the app's own module declares its own `LogLevel` enum,
    // completely unrelated to the `MindboxLogger` pod's own, separately-compiled `LogLevel` enum.
    // Unlike the GestureView/Swiftfin shape above, *both* files here are genuinely compiled/indexed
    // -- this is not an uncompiled-file problem, it's a bare-name placeholder collision between two
    // real, independently-resolvable declarations.
    let podLocation = SymbolLocation(file: "/Pods/MindboxLogger/LogLevel.swift", line: 23, column: 13)
    let appLocation = SymbolLocation(file: "/App/LogLevel.swift", line: 12, column: 13)

    let podType = makeDeclaration(usr: "syntactic:LogLevel", name: "LogLevel", location: podLocation)
    let appType = makeDeclaration(usr: "syntactic:LogLevel", name: "LogLevel", location: appLocation)

    let fake = FakeIndexStoreQuerying()
    fake.symbolsByFile["/Pods/MindboxLogger/LogLevel.swift"] = [
        IndexedSymbol(usr: "c:@M@MindboxLogger@E@LogLevel", name: "LogLevel", location: podLocation),
    ]
    fake.symbolsByFile["/App/LogLevel.swift"] = [
        IndexedSymbol(usr: "s:9Ls_net_ru8LogLevelO", name: "LogLevel", location: appLocation),
    ]

    let linked = DeclarationLinker(indexStore: fake).link([
        ExtractionResult(declarations: [podType], protocolGlobalActorNames: [:]),
        ExtractionResult(declarations: [appType], protocolGlobalActorNames: [:]),
    ])

    let linkedPodType = try #require(
        linked.declarations["c:@M@MindboxLogger@E@LogLevel"],
        "the pod's own LogLevel must resolve to its own real Clang USR, independent of the app's own colliding placeholder"
    )
    let linkedAppType = try #require(
        linked.declarations["s:9Ls_net_ru8LogLevelO"],
        "the app's own LogLevel must resolve to its own real Swift-mangled USR, independent of the pod's own colliding placeholder"
    )
    #expect(linkedPodType.location == podLocation)
    #expect(linkedAppType.location == appLocation)
    #expect(linked.declarations.count == 2, "the two unrelated types must never be silently merged into one entry")
}

// MARK: - Transitive protocol-inheritance expansion (docs/task-transitive-protocol-conformance.md)

@Test("link(_:) expands a type's conformance to a project-local protocol to also include that protocol's own external ancestor, letting the existing external-backfill machinery resolve it (PlatformView/Swiftfin shape)")
func linkExpandsConformanceThroughProtocolInheritanceChain() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/LetterPickerBar.swift", line: 12, column: 8)
    fake.symbolsByFile["/LetterPickerBar.swift"] = [IndexedSymbol(usr: "s:realLetterPickerBar", name: "LetterPickerBar", location: location)]

    // Real shape: `struct LetterPickerBar: PlatformView { ... }`, and completely separately,
    // `protocol PlatformView: View { ... }` (PlatformView.swift, a different file, never
    // contributes a `helper`/`letterBar`-shaped member of its own -- only its own inheritance
    // clause matters here).
    let conformance = placeholderConformance("syntactic:PlatformView")
    let helper = makeDeclaration(
        usr: "syntactic:LetterPickerBar.helper#0", name: "helper", location: nil,
        containingTypeUSR: "syntactic:LetterPickerBar", conformances: [conformance]
    )
    let type = makeDeclaration(usr: "syntactic:LetterPickerBar", name: "LetterPickerBar", location: location, conformances: [conformance])

    let extractionResults = [
        ExtractionResult(declarations: [type, helper], protocolGlobalActorNames: [:]),
        ExtractionResult(declarations: [], protocolGlobalActorNames: [:], protocolInheritedProtocolNames: ["PlatformView": ["View"]]),
    ]
    let linked = DeclarationLinker(indexStore: fake).link(extractionResults)

    let linkedHelper = try #require(linked.declarations.values.first { $0.name == "helper" })
    let protocolUSRs = Set(linkedHelper.conformances.map(\.protocolUSR))
    #expect(protocolUSRs == ["syntactic:PlatformView", "syntactic:View"], "the transitively-inherited ancestor must be added, not substituted for the original")

    let addedConformance = try #require(linkedHelper.conformances.first { $0.protocolUSR == "syntactic:View" })
    #expect(
        addedConformance.declaredInSameContextAsWitness == conformance.declaredInSameContextAsWitness,
        "the synthetic ancestor entry must carry the same locality flags as the conformance that introduced it"
    )
}

@Test("link(_:) walks a multi-hop protocol-inheritance chain to its end, not just one level")
func linkExpandsConformanceThroughMultiHopChain() throws {
    let fake = FakeIndexStoreQuerying()
    let conformance = placeholderConformance("syntactic:A")
    let declaration = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: nil, conformances: [conformance])

    // A -> B -> C -> View: the ancestor three hops away must still be found.
    let extractionResults = [
        ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:]),
        ExtractionResult(
            declarations: [], protocolGlobalActorNames: [:],
            protocolInheritedProtocolNames: ["A": ["B"], "B": ["C"], "C": ["View"]]
        ),
    ]
    let linked = DeclarationLinker(indexStore: fake).link(extractionResults)

    let linkedWidget = try #require(linked.declarations.values.first { $0.name == "Widget" })
    let protocolUSRs = Set(linkedWidget.conformances.map(\.protocolUSR))
    #expect(protocolUSRs == ["syntactic:A", "syntactic:B", "syntactic:C", "syntactic:View"])
}

@Test("link(_:) never infinite-loops on a protocol-inheritance cycle")
func linkToleratesAProtocolInheritanceCycleWithoutHanging() throws {
    let fake = FakeIndexStoreQuerying()
    let conformance = placeholderConformance("syntactic:A")
    let declaration = makeDeclaration(usr: "syntactic:Widget", name: "Widget", location: nil, conformances: [conformance])

    // A -> B -> A: not valid Swift, but the graph walk must not hang if it ever occurred (e.g. a
    // tool/data inconsistency), matching the "never guess, never crash" philosophy elsewhere in
    // this file.
    let extractionResults = [
        ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:]),
        ExtractionResult(declarations: [], protocolGlobalActorNames: [:], protocolInheritedProtocolNames: ["A": ["B"], "B": ["A"]]),
    ]
    let linked = DeclarationLinker(indexStore: fake).link(extractionResults)

    let linkedWidget = try #require(linked.declarations.values.first { $0.name == "Widget" })
    let protocolUSRs = Set(linkedWidget.conformances.map(\.protocolUSR))
    #expect(protocolUSRs == ["syntactic:A", "syntactic:B"])
}

// MARK: - Local declaration completeness fallback (docs/task-indexstore-declaration-completeness.md)

@Test("unresolvedPlaceholders(for:) returns a declaration whose location-based match found nothing, paired with its real location")
func unresolvedPlaceholdersReportsLocationMatchMisses() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/Widget.swift", line: 10, column: 5)
    // Deliberately no `fake.symbolsByFile` entry for this file at all -- the bulk index simply
    // never reports an occurrence here, exactly the real symptom (`IndexStoreDB`'s own
    // `symbolOccurrences(inFilePath:)` returning incomplete data under load, not a lookup bug in
    // this project's own matching code).
    let declaration = makeDeclaration(usr: "syntactic:Widget#0", name: "Widget", location: location)

    let unresolved = DeclarationLinker(indexStore: fake).unresolvedPlaceholders(for: [ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])

    #expect(unresolved.count == 1)
    #expect(unresolved.first?.placeholder == "syntactic:Widget#0")
    #expect(unresolved.first?.location == location)
}

@Test("unresolvedPlaceholders(for:) omits a declaration that resolved successfully, and one with no real location at all")
func unresolvedPlaceholdersOmitsResolvedAndLocationlessDeclarations() throws {
    let fake = FakeIndexStoreQuerying()
    let location = SymbolLocation(file: "/Widget.swift", line: 10, column: 5)
    fake.symbolsByFile["/Widget.swift"] = [IndexedSymbol(usr: "s:realWidget", name: "Widget", location: location)]

    let resolved = makeDeclaration(usr: "syntactic:Widget#0", name: "Widget", location: location)
    let locationless = makeDeclaration(usr: "syntactic:Member#1", name: "member", location: nil)

    let unresolved = DeclarationLinker(indexStore: fake).unresolvedPlaceholders(
        for: [ExtractionResult(declarations: [resolved, locationless], protocolGlobalActorNames: [:])]
    )

    #expect(unresolved.isEmpty)
}

@Test("link(_:usrRewriteMapOverrides:) rescues a declaration the bulk index's own location match missed, using the live-fallback-provided real USR")
func linkAppliesUsrRewriteMapOverrides() throws {
    let fake = FakeIndexStoreQuerying()
    // No `fake.symbolsByFile` entry -- bulk location matching finds nothing for this declaration,
    // mirroring the real, confirmed symptom.
    let declaration = makeDeclaration(usr: "syntactic:Widget#0", name: "Widget", location: SymbolLocation(file: "/Widget.swift", line: 10, column: 5))

    let withoutOverride = DeclarationLinker(indexStore: fake).link([ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])])
    #expect(withoutOverride.declarations["syntactic:Widget#0"] != nil, "without a live fallback, the declaration stays under its own unresolved placeholder USR")
    #expect(withoutOverride.declarations["s:realWidgetFromLiveQuery"] == nil)

    let withOverride = DeclarationLinker(indexStore: fake).link(
        [ExtractionResult(declarations: [declaration], protocolGlobalActorNames: [:])],
        usrRewriteMapOverrides: ["syntactic:Widget#0": "s:realWidgetFromLiveQuery"]
    )
    let rescued = try #require(withOverride.declarations["s:realWidgetFromLiveQuery"], "a live-fallback override must rewrite the declaration to its real USR, exactly as a successful bulk-index match would have")
    #expect(rescued.name == "Widget")
}

// MARK: - Issue #40: additionalGlobalActorNames feeds Rule A's closure classification

@Test("link(additionalGlobalActorNames:) lets Rule A recognize a closure attribute this run's own syntactic scan could never see (a real @globalActor declared in a compiled dependency)")
func additionalGlobalActorNamesFeedsClosureClassification() {
    let fake = FakeIndexStoreQuerying()
    let record = ClosureLiteralRecord(
        file: "/f.swift", startLine: 1, startColumn: 1, endLine: 3, endColumn: 1,
        signatureAttributeName: "ThirdPartyActor", enclosingCallReceiver: nil, enclosingCallMember: nil
    )
    let extractionResult = ExtractionResult(declarations: [], protocolGlobalActorNames: [:], closureLiteralRecords: [record])

    let withoutDiscoveredName = DeclarationLinker(indexStore: fake).link([extractionResult])
    #expect(withoutDiscoveredName.closuresByFile["/f.swift"]?.first?.isolationOverride == nil, "without the discovered name, this project's own syntactic scan has no way to know ThirdPartyActor is a real global actor -- Rule A correctly falls back to unknown/inherits")

    let withDiscoveredName = DeclarationLinker(indexStore: fake).link([extractionResult], additionalGlobalActorNames: ["ThirdPartyActor"])
    #expect(withDiscoveredName.closuresByFile["/f.swift"]?.first?.isolationOverride == .globalActor(name: "ThirdPartyActor"))
    #expect(withDiscoveredName.globalActorNames.contains("ThirdPartyActor"), "also exposed on LinkedAnalysis itself, so ExternalIsolationBackfill's own live-oracle GlobalActorNameValidation checks get the same expanded set for free")
}
