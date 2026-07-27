import Foundation
import Testing
import IsolationCore
import IndexStoreIntegration
import ProjectResolution
import SourceKitDIntegration
import SyntaxAnalysis
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

@Test("A member whose containingTypeUSR was rewritten to a real external USR (extension-of-external-type fix) gets that type's isolation backfilled via its own hover")
func declarationLevelTriggerBackfillsExtendedExternalContainingType() async {
    let location = SymbolLocation(file: "/f.swift", line: 1, column: 1)
    // Mirrors DeclarationLinker's own .childOf/.extendedBy fix: containingTypeUSR already
    // rewritten to a real, external USR (e.g. UIViewController's own clang USR) by the time
    // ExternalIsolationBackfill sees it.
    let member = DeclarationInfo(usr: "s:Widget.method", name: "method", containingTypeUSR: "c:objc(cs)ExternalType", location: location)
    let linked = LinkedAnalysis(declarations: ["s:Widget.method": member], callGraph: [])
    let fileSystem = makeFixture(contents: "x\n", at: "/f.swift")
    let compilerArguments = FakeCompilerArgumentsProviding()
    compilerArguments.argumentsByFile["/f.swift"] = ["-sdk", "/SDK"]
    let sourceKitD = FakeSourceKitDQuerying()
    // Hovering the member's own declaration returns its already-fully-resolved effective
    // isolation, inherited from the extended external type -- same "hover the project's own
    // declaration" shape already established for the external-superclass case.
    sourceKitD.responsesByOffset[0] = .success(CursorInfoResult(
        primary: CursorInfoSymbol(usr: "s:Widget.method", fullyAnnotatedDeclXML: nil, symbolGraphJSON: mainActorSymbolGraph(usr: "s:Widget.method")),
        secondary: []
    ))

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
        processRunning: FakeProcessRunner(), environmentProvider: FakeBulkExtractionEnvironmentProviding(), bulkModuleNames: []
    )

    #expect(resolution.backfilledDeclarations["c:objc(cs)ExternalType"]?.explicitIsolation == .globalActor(name: "MainActor"))
}

/// A real environment (real SDK path, real target), so `ExternalIsolationBackfill.resolve`'s own
/// bulk-cache phase performs a real `AppKit` `symbolgraph-extract` -- the last unverified seam in
/// the extension-of-an-external-type fix (docs/task-external-type-extension-isolation.md):
/// `DeclarationLinker`'s `.childOf`/`.extendedBy` chain rewrites `containingTypeUSR` to
/// `"c:objc(cs)NSView"` (confirmed live in `DeclarationLinkerTests.swift`), and this test confirms
/// that *same* real key is what the real bulk cache backfills -- not just two isolated tests that
/// happen to use the same literal string.
private struct RealAppKitEnvironmentProviding: BulkExtractionEnvironmentProviding {
    func environment() throws -> BulkExtractionEnvironment {
        let sdkResult = try LiveProcessRunner().run(executable: "xcrun", arguments: ["--sdk", "macosx", "--show-sdk-path"], workingDirectory: nil)
        let sdkPath = sdkResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #if arch(arm64)
        let target = "arm64-apple-macosx13.0"
        #else
        let target = "x86_64-apple-macosx13.0"
        #endif
        return BulkExtractionEnvironment(sdkPath: sdkPath, target: target, discoveredModules: [])
    }
}

@Test("End to end, real toolchain: an extension member of a real external @MainActor SDK type (NSView) resolves correctly through DeclarationLinker + ExternalIsolationBackfill + the unmodified IsolationInferenceEngine")
func extensionOfExternalTypeResolvesEndToEndWithRealAppKit() async throws {
    // A private copy, not the shared fixture path: several tests across two test targets build
    // `cross-file-witness` concurrently, and running `swift build` against one *shared*
    // `.build/build.db` was found, empirically, to race under concurrent `swift-testing`
    // execution (a real SwiftPM build-database "disk I/O error") -- see
    // `DeclarationLinkerTests.swift`'s own `copiedCrossFileWitnessFixture()` doc comment.
    let originalRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ExternalIsolationBackfillTests.swift -> swift-isolation-mapTests
        .deletingLastPathComponent() // swift-isolation-mapTests -> Tests
        .appendingPathComponent("Fixtures/cross-file-witness")
    // Real-path (`realpath(3)`, not `resolvingSymlinksInPath`) resolution is load-bearing here,
    // not cosmetic -- see `DeclarationLinkerTests.swift`'s `copiedCrossFileWitnessFixture()` doc
    // comment: `/var` (hence `NSTemporaryDirectory()`) is an APFS *firmlink* to `/private/var` on
    // macOS, invisible to `Foundation`'s own symlink-resolution API, but real to the compiler/
    // index-store machinery, which records every source file's path already resolved.
    var pathBuffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    let realTempDir: URL
    if let resolved = realpath(NSTemporaryDirectory(), &pathBuffer) {
        realTempDir = URL(fileURLWithPath: String(cString: resolved))
    } else {
        realTempDir = URL(fileURLWithPath: NSTemporaryDirectory())
    }
    let fixtureRoot = realTempDir.appendingPathComponent("swift-isolation-map-fixture-copy-\(UUID().uuidString)")
    try? FileManager.default.removeItem(at: fixtureRoot)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    for name in ["Package.swift", "Sources"] {
        try FileManager.default.copyItem(at: originalRoot.appendingPathComponent(name), to: fixtureRoot.appendingPathComponent(name))
    }
    let sourcesDirectory = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness")
    let indexStorePath = NSTemporaryDirectory() + "swift-isolation-map-test-extend2end-store-\(UUID().uuidString)"
    let databasePath = NSTemporaryDirectory() + "swift-isolation-map-test-extend2end-db-\(UUID().uuidString)"

    let processRunner = LiveProcessRunner()
    let buildResult = try processRunner.run(
        executable: "swift",
        arguments: ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", indexStorePath],
        workingDirectory: fixtureRoot
    )
    #expect(buildResult.exitCode == 0, "fixture build failed: \(buildResult.standardError)")

    let extensionFile = sourcesDirectory.appendingPathComponent("ExtensionOfExternalType.swift")
    let source = try String(contentsOf: extensionFile, encoding: .utf8)
    let extractionResult = DeclarationExtractor.extractWithContext(source: source, fileName: extensionFile.path)

    let indexStoreClient = try IndexStoreClient(storePath: indexStorePath, databasePath: databasePath)
    let linker = DeclarationLinker(indexStore: indexStoreClient)
    let linked = linker.link([extractionResult])

    let realExtensionMethod = try #require(linked.declarations.values.first { $0.name == "realExtensionMethod" })
    #expect(realExtensionMethod.containingTypeUSR == "c:objc(cs)NSView")

    let resolution = await ExternalIsolationBackfill.resolve(
        linked: linked,
        compilerArguments: FakeCompilerArgumentsProviding(),
        sourceKitD: FakeSourceKitDQuerying(),
        fileSystem: LiveFileSystem(),
        processRunning: processRunner,
        environmentProvider: RealAppKitEnvironmentProviding(),
        bulkModuleNames: ["AppKit"]
    )

    #expect(resolution.backfilledDeclarations["c:objc(cs)NSView"]?.explicitIsolation == .globalActor(name: "MainActor"))

    var declarations = linked.declarations
    declarations.merge(resolution.backfilledDeclarations) { existing, _ in existing }
    let engine = IsolationInferenceEngine(declarations: declarations, callGraph: linked.callGraph, ruleSet: Swift63RuleSet())
    #expect(engine.resolveIsolation(for: realExtensionMethod.usr) == .globalActor(name: "MainActor"))
}
