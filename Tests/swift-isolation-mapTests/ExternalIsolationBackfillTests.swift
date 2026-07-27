import Foundation
import Testing
import IsolationCore
import IndexStoreIntegration
import ProjectResolution
import SourceKitDIntegration
@testable import swift_isolation_map

final class FakeCompilerArgumentsProviding: CompilerArgumentsProviding, @unchecked Sendable {
    var argumentsByFile: [String: [String]] = [:]

    func compilerArguments(forFile path: String) throws -> [String] {
        guard let arguments = argumentsByFile[path] else {
            throw CompilerArgumentsError.argumentsNotFound(file: path)
        }
        return arguments
    }
}

final class FakeSourceKitDQuerying: SourceKitDQuerying, @unchecked Sendable {
    var responsesByOffset: [Int: Result<CursorInfoResult, Error>] = [:]
    /// Total `cursorInfo` calls made -- lets a test prove a query was *never* made (Gap B Phase
    /// I3's dedup), not just that its absence didn't crash anything.
    private(set) var callCount = 0

    func cursorInfo(_ request: CursorInfoRequest) async throws -> CursorInfoResult {
        callCount += 1
        guard let outcome = responsesByOffset[request.byteOffset] else {
            throw SourceKitDQueryError.malformedResponse("no stub for offset \(request.byteOffset)")
        }
        return try outcome.get()
    }
}

/// Throws unconditionally -- these tests exercise the live oracle path (`compilerArguments`/
/// `sourceKitD` above), not the bulk cache, so `bulkSymbolGraphCache` must see an empty cache
/// (its own documented fail-soft contract on an unavailable environment), matching this suite's
/// pre-existing behavior before the bulk-cache environment provider existed.
final class FakeBulkExtractionEnvironmentProviding: BulkExtractionEnvironmentProviding, @unchecked Sendable {
    func environment() throws -> BulkExtractionEnvironment {
        throw BulkExtractionEnvironmentError.settingsUnavailable(reason: "not stubbed")
    }
}

private func mainActorSymbolGraph(usr: String) -> String {
    """
    {"symbols":[{"identifier":{"precise":"\(usr)"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"}]}]}
    """
}

private func noAttributeSymbolGraph(usr: String) -> String {
    """
    {"symbols":[{"identifier":{"precise":"\(usr)"},"declarationFragments":[]}]}
    """
}

private func makeFixture(contents: String, at path: String) -> FakeFileSystem {
    let fileSystem = FakeFileSystem()
    fileSystem.addFile(at: URL(fileURLWithPath: path), contents: contents)
    return fileSystem
}

@Test("An edge whose callee is external and resolves to a global actor gets backfilled, keyed by the callee's own USR")
func edgeLevelTriggerBackfillsOnSuccess() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:external.Callee", location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:external.Callee", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:external.Callee")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["s:external.Callee"]?.explicitIsolation == .globalActor(name: "MainActor"))
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("An edge whose callee the oracle cannot match at all is unknown, never fabricated as nonisolated")
func edgeLevelTriggerMarksUnknownOnNoMatch() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:external.Callee", location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // The result exists but its USR doesn't match the edge's callee at all -- a real, distinct
    // symbol got resolved at that position (e.g. stale offset), not the one we asked about.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:something.Unrelated", fullyAnnotatedDeclXML: nil, symbolGraphJSON: nil),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations.isEmpty)
    #expect(resolution.unknownUSRs == ["s:external.Callee"])
}

@Test("A matched result with no isolation attribute is a genuine nonisolated fact, not unknown")
func edgeLevelTriggerTreatsNoAttributeAsGenuineNonisolated() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let linked = LinkedAnalysis(
        declarations: [:],
        callGraph: [CallGraphEdge(callerUSR: "s:caller", calleeUSR: "s:external.Callee", location: location)]
    )
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:external.Callee", fullyAnnotatedDeclXML: nil, symbolGraphJSON: noAttributeSymbolGraph(usr: "s:external.Callee")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["s:external.Callee"]?.explicitIsolation == .nonisolated)
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("A declaration with an external superclass and no explicit isolation of its own gets the superclass backfilled")
func declarationLevelTriggerBackfillsSuperclass() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let declaration = DeclarationInfo(usr: "s:Sub", name: "Sub", superclassUSR: "s:external.Base", location: location)
    let linked = LinkedAnalysis(declarations: ["s:Sub": declaration], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Hovering the subclass's own declaration returns its already-fully-resolved effective
    // isolation, matched by the subclass's own USR (not the superclass's).
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Sub", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Sub")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["s:external.Base"]?.explicitIsolation == .globalActor(name: "MainActor"))
}

@Test("A declaration with its own explicit isolation is never queried -- it's not a safe representative for its superclass")
func declarationWithOwnExplicitIsolationIsSkipped() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let declaration = DeclarationInfo(
        usr: "s:Sub", name: "Sub", explicitIsolation: .nonisolated, superclassUSR: "s:external.Base", location: location
    )
    let linked = LinkedAnalysis(declarations: ["s:Sub": declaration], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    // No stubbed arguments/response at all -- if the code queries anyway, the test fails loudly
    // (argumentsNotFound / no stub), proving the skip actually happens rather than just asserting
    // an absence of output that could also mean "silently swallowed an error".
    let sourceKitD = FakeSourceKitDQuerying()

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations.isEmpty)
    #expect(resolution.unknownUSRs.isEmpty)
}

@Test("A declaration conforming to an external, same-file-declared protocol gets protocolGlobalActorName rewritten on its own entry, not a new declarations[protocolUSR] entry")
func declarationLevelTriggerRewritesConformance() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let conformance = ProtocolConformance(
        protocolUSR: "s:external.View", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: true, declaredInSameContextAsWitness: false
    )
    let declaration = DeclarationInfo(usr: "s:MyView", name: "MyView", conformances: [conformance], location: location)
    let linked = LinkedAnalysis(declarations: ["s:MyView": declaration], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:MyView", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:MyView")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["s:external.View"] == nil)
    #expect(resolution.updatedDeclarations["s:MyView"]?.conformances.first?.protocolGlobalActorName == "MainActor")
}

@Test("A declaration-level oracle failure marks the declaration and its direct members unknown")
func declarationLevelTriggerFailurePropagatesToDirectMembers() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let subclass = DeclarationInfo(usr: "s:Sub", name: "Sub", superclassUSR: "s:external.Base", location: location)
    let member = DeclarationInfo(usr: "s:Sub.method", name: "method", containingTypeUSR: "s:Sub", location: location)
    let linked = LinkedAnalysis(declarations: ["s:Sub": subclass, "s:Sub.method": member], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    sourceKitD.responsesByOffset[0] = .failure(SourceKitDQueryError.requestFailed("boom"))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.unknownUSRs == ["s:Sub", "s:Sub.method"])
    #expect(resolution.backfilledDeclarations["s:external.Base"] == nil)
}

@Test("Gap B Phase I3: two members of the same nominal type sharing the same unresolved conformance are resolved with only one live oracle query, both copies rewritten")
func declarationLevelTriggerDedupesPerMemberConformanceCopies() async throws {
    // Two distinct locations (different byte offsets) so a real second query, if one happened,
    // would be distinguishable from reusing the first query's cached outcome.
    let location1 = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    let location2 = SymbolLocation(file: "/f.swift", line: 2, column: 1)
    let conformance = ProtocolConformance(
        protocolUSR: "s:external.P", protocolGlobalActorName: nil,
        declaredInSameFileAsPrimaryDefinition: false, declaredInSameContextAsWitness: true
    )
    // Both members of the same nominal ("s:Widget", via containingTypeUSR), each carrying its
    // own propagated copy of the exact same still-unresolved conformance -- exactly the real
    // corpus shape Phase I3 exists for (`SyntaxAnalysis.DeclarationExtractor` attaches a copy of
    // the enclosing type's conformances to every member).
    let method1 = DeclarationInfo(usr: "s:Widget.method1", name: "method1", containingTypeUSR: "s:Widget", conformances: [conformance], location: location1)
    let method2 = DeclarationInfo(usr: "s:Widget.method2", name: "method2", containingTypeUSR: "s:Widget", conformances: [conformance], location: location2)
    let linked = LinkedAnalysis(declarations: ["s:Widget.method1": method1, "s:Widget.method2": method2], callGraph: [])
    let fileSystem = makeFixture(contents: "first\nsecond\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Both offsets are stubbed (so the test is robust to `Dictionary` iteration order deciding
    // which member is visited first) but both resolve to the same actor -- what actually proves
    // the dedup is `callCount == 1` below, not which specific offset got hit.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Widget.method1", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Widget.method1")),
        secondary: []
    ))
    sourceKitD.responsesByOffset[6] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Widget.method2", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Widget.method2")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(sourceKitD.callCount == 1)
    #expect(resolution.updatedDeclarations["s:Widget.method1"]?.conformances.first?.protocolGlobalActorName == "MainActor")
    #expect(resolution.updatedDeclarations["s:Widget.method2"]?.conformances.first?.protocolGlobalActorName == "MainActor")
}
