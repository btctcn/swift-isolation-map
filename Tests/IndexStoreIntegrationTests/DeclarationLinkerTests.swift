import Foundation
import Testing
import IsolationCore
import SyntaxAnalysis
import ProjectResolution
@testable import IndexStoreIntegration

/// Golden-fixture test per the architecture spec's testing strategy (section 4, tier 3): builds
/// a real SPM package (`Tests/Fixtures/cross-file-witness/`) for real, indexes it for real, and
/// feeds the result through the *unmodified* Priority 1 `IsolationInferenceEngine` -- using that
/// already-trusted engine as the assertion oracle, per this phase's own "done" criterion.
///
/// The fixture is deliberately shaped as exactly the case plain SwiftSyntax (Phase 1 alone)
/// cannot resolve: `@MainActor protocol Refreshable` is declared in `Protocol.swift`,
/// `SyncCoordinator`'s primary declaration is in `SyncCoordinator.swift` (no conformance stated
/// there), and the conformance + witness are in a *third* file, `SyncCoordinatorRefreshable.swift`.
/// A single-file extraction of any one of these files could never know `refresh()` is
/// MainActor-isolated -- only this phase's cross-file linking (real USRs from IndexStoreDB +
/// merged `protocolGlobalActorNames`) can.
@Test("A cross-file protocol-witness call resolves correctly end to end, through the unmodified IsolationInferenceEngine")
func crossFileProtocolWitnessResolvesCorrectly() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DeclarationLinkerTests.swift -> IndexStoreIntegrationTests
        .deletingLastPathComponent() // IndexStoreIntegrationTests -> Tests
        .appendingPathComponent("Fixtures/cross-file-witness")
    let sourcesDirectory = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness")
    let indexStorePath = NSTemporaryDirectory() + "swift-isolation-map-test-cross-file-witness-store"
    let databasePath = NSTemporaryDirectory() + "swift-isolation-map-test-cross-file-witness-db"
    try? FileManager.default.removeItem(atPath: indexStorePath)
    try? FileManager.default.removeItem(atPath: databasePath)
    // Found the hard way (flaky on repeated runs): SwiftPM's incremental build sees unchanged
    // sources and skips recompilation entirely on a second run, which means it never actually
    // invokes the compiler to (re)populate the *new* -index-store-path -- silently leaving the
    // freshly-deleted store empty and every USR unresolved. Force a real rebuild every time by
    // clearing the fixture's own .build first, not just the destination index store path.
    try? FileManager.default.removeItem(atPath: fixtureRoot.appendingPathComponent(".build").path)

    // 1. Build the real fixture for real, indexing it to a throwaway path -- same command form
    // verified in the Phase 0 spike and used by Phase 2's IndexStoreLocator.
    let processRunner = LiveProcessRunner()
    let buildResult = try processRunner.run(
        executable: "swift",
        arguments: ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", indexStorePath],
        workingDirectory: fixtureRoot
    )
    #expect(buildResult.exitCode == 0, "fixture build failed: \(buildResult.standardError)")

    // 2. Extract declarations from each real source file (Phase 1, unmodified).
    let sourceFileNames = ["Protocol.swift", "SyncCoordinator.swift", "SyncCoordinatorRefreshable.swift", "main.swift"]
    let extractionResults = try sourceFileNames.map { fileName -> ExtractionResult in
        let fileURL = sourcesDirectory.appendingPathComponent(fileName)
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        return DeclarationExtractor.extractWithContext(source: source, fileName: fileURL.path)
    }

    // 3. Link via real IndexStoreDB data (Phase 3, this PR).
    let indexStoreClient = try IndexStoreClient(storePath: indexStorePath, databasePath: databasePath)
    let linker = DeclarationLinker(indexStore: indexStoreClient)
    let linked = linker.link(extractionResults)

    // 4. Feed into the unmodified Priority 1 engine and assert on the result.
    let engine = IsolationInferenceEngine(declarations: linked.declarations, callGraph: linked.callGraph, ruleSet: Swift63RuleSet())

    let coordinator = try #require(linked.declarations.values.first { $0.name == "SyncCoordinator" })
    // `Refreshable`'s own `func refresh()` requirement is a *different* declaration that also
    // happens to be named "refresh" -- disambiguate by containing type, the same fix Phase 1's
    // own tests needed for an identical protocol-requirement-vs-witness name collision.
    // `Dictionary.values` iteration order isn't deterministic, so a bare name match here would be
    // flaky rather than reliably wrong -- found exactly that way before adding this filter.
    let refresh = try #require(linked.declarations.values.first { $0.name == "refresh" && $0.containingTypeUSR == coordinator.usr })
    let unrelatedMethod = try #require(linked.declarations.values.first { $0.name == "unrelatedMethod" })
    let trigger = try #require(linked.declarations.values.first { $0.name == "trigger" })

    // Real USRs, not syntactic placeholders -- confirms the linking step actually ran.
    #expect(!coordinator.usr.hasPrefix("syntactic:"))
    #expect(!refresh.usr.hasPrefix("syntactic:"))

    // The core cross-file claim: refresh() is MainActor-isolated (inferred from a conformance
    // declared in a third file), an unrelated method on the same type is not, and the caller
    // (explicitly nonisolated) is not.
    #expect(engine.resolveIsolation(for: refresh.usr) == .globalActor(name: "MainActor"))
    #expect(engine.resolveIsolation(for: unrelatedMethod.usr) == .nonisolated)
    #expect(engine.resolveIsolation(for: trigger.usr) == .nonisolated)

    // The real call graph (from IndexStoreDB, not fixture data) contains the trigger -> refresh
    // edge, and the engine's crossIsolationEdges() correctly flags it as crossing an isolation
    // boundary -- the actual end-to-end signal this whole phase exists to produce.
    let crossEdges = engine.crossIsolationEdges()
    #expect(crossEdges.contains { $0.callerUSR == trigger.usr && $0.calleeUSR == refresh.usr })
}

/// Verifies, against a real index store (not assumed from reading `swiftlang/indexstore-db`'s
/// source alone -- the code that actually *populates* which occurrence carries `.accessorOf`
/// lives in the Swift compiler itself, not anything checked out in this repo), which side of the
/// relation carries the accessor->property mapping: on the accessor's own definition occurrence
/// (pointing at the property), or on the property's own occurrence (pointing at each accessor).
/// Gap A, docs/task-compiled-dependency-isolation-usr-granularity.md -- `SyncCoordinator.counter`
/// (`Tests/Fixtures/cross-file-witness/Sources/CrossFileWitness/SyncCoordinator.swift`) is a
/// plain stored property added specifically for this test.
@Test("owningPropertyUSR(forUSR:) maps a real synthesized getter/setter USR back to the property's own real USR")
func owningPropertyUSRMapsRealAccessorToItsProperty() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/cross-file-witness")
    let sourcesDirectory = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness")
    let indexStorePath = NSTemporaryDirectory() + "swift-isolation-map-test-accessor-usr-store"
    let databasePath = NSTemporaryDirectory() + "swift-isolation-map-test-accessor-usr-db"
    try? FileManager.default.removeItem(atPath: indexStorePath)
    try? FileManager.default.removeItem(atPath: databasePath)
    try? FileManager.default.removeItem(atPath: fixtureRoot.appendingPathComponent(".build").path)

    let processRunner = LiveProcessRunner()
    let buildResult = try processRunner.run(
        executable: "swift",
        arguments: ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", indexStorePath],
        workingDirectory: fixtureRoot
    )
    #expect(buildResult.exitCode == 0, "fixture build failed: \(buildResult.standardError)")

    let indexStoreClient = try IndexStoreClient(storePath: indexStorePath, databasePath: databasePath)

    // Real symbols reported by IndexStoreDB at `counter`'s own declaration location -- per
    // `DeclarationLinker.disambiguate`'s own established, already-verified finding, a stored
    // property's implicit getter/setter report at the *same* (line, column) as the property
    // itself, distinguished only by name (`getter:counter`/`setter:counter` vs. plain `counter`).
    let counterFile = sourcesDirectory.appendingPathComponent("SyncCoordinator.swift").path
    let symbolsAtLocation = indexStoreClient.definedSymbols(inFile: counterFile).filter { $0.name.contains("counter") }
    let property = try #require(symbolsAtLocation.first { $0.name == "counter" })
    let getter = try #require(symbolsAtLocation.first { $0.name == "getter:counter" })
    let setter = try #require(symbolsAtLocation.first { $0.name == "setter:counter" })

    #expect(indexStoreClient.owningPropertyUSR(forUSR: getter.usr) == property.usr)
    #expect(indexStoreClient.owningPropertyUSR(forUSR: setter.usr) == property.usr)
    // The property's own USR is not itself an accessor of anything.
    #expect(indexStoreClient.owningPropertyUSR(forUSR: property.usr) == nil)
}

/// Verifies, against a real index store, which side of IndexStoreDB's `.baseOf` relation carries
/// the supertype/conformance mapping -- Gap B, docs/task-gap-b-implementation-plan.md's Phase I2.
/// Deliberately reuses `cross-file-witness`'s existing `extension SyncCoordinator: Refreshable`
/// (`SyncCoordinatorRefreshable.swift`) rather than a fresh `class C: P` fixture: an
/// extension-declared conformance is the corpus's *dominant* real-world shape (confirmed against
/// `~/ios`), and a fixture with only a direct `class C: P` conformance would validate the relation
/// without validating the shape that actually produced the 28134-trigger real-world problem.
@Test("baseTypeUSRs(forUSR:) resolves a real supertype/conformance, including one declared via an extension")
func baseTypeUSRsResolvesRealSupertypesIncludingExtensionDeclared() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/cross-file-witness")
    let sourcesDirectory = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness")
    let indexStorePath = NSTemporaryDirectory() + "swift-isolation-map-test-baseof-store"
    let databasePath = NSTemporaryDirectory() + "swift-isolation-map-test-baseof-db"
    try? FileManager.default.removeItem(atPath: indexStorePath)
    try? FileManager.default.removeItem(atPath: databasePath)
    try? FileManager.default.removeItem(atPath: fixtureRoot.appendingPathComponent(".build").path)

    let processRunner = LiveProcessRunner()
    let buildResult = try processRunner.run(
        executable: "swift",
        arguments: ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", indexStorePath],
        workingDirectory: fixtureRoot
    )
    #expect(buildResult.exitCode == 0, "fixture build failed: \(buildResult.standardError)")

    let indexStoreClient = try IndexStoreClient(storePath: indexStorePath, databasePath: databasePath)

    let coordinatorFile = sourcesDirectory.appendingPathComponent("SyncCoordinator.swift").path
    let coordinator = try #require(indexStoreClient.definedSymbols(inFile: coordinatorFile).first { $0.name == "SyncCoordinator" })

    let protocolFile = sourcesDirectory.appendingPathComponent("Protocol.swift").path
    let refreshable = try #require(indexStoreClient.definedSymbols(inFile: protocolFile).first { $0.name == "Refreshable" })

    // `SyncCoordinator`'s own conformance to `Refreshable` is declared in a *third* file
    // (`SyncCoordinatorRefreshable.swift`, via `extension SyncCoordinator: Refreshable`) --
    // neither `SyncCoordinator`'s nor `Refreshable`'s own declaration file. `baseTypeUSRs`
    // must surface it anyway, purely from the index relation.
    let baseTypes = indexStoreClient.baseTypeUSRs(forUSR: coordinator.usr)
    #expect(baseTypes.contains { $0.usr == refreshable.usr })

    // The reverse direction must not hold: `Refreshable` (a protocol, no base types of its own
    // in this fixture) does not report `SyncCoordinator` as one of its own base types -- confirms
    // the relation wasn't queried backwards.
    let reverseBaseTypes = indexStoreClient.baseTypeUSRs(forUSR: refreshable.usr)
    #expect(!reverseBaseTypes.contains { $0.usr == coordinator.usr })

    // The *direct* inheritance shape (declared on the primary declaration itself, e.g.
    // `class DerivedWidget: BaseWidget {}`, `DirectInheritance.swift`) resolves through the same
    // query without needing the extension hop -- confirmed separately from the extension-declared
    // shape above, not assumed to work the same way just because both use `.baseOf`.
    let directInheritanceFile = sourcesDirectory.appendingPathComponent("DirectInheritance.swift").path
    let directSymbols = indexStoreClient.definedSymbols(inFile: directInheritanceFile)
    let baseWidget = try #require(directSymbols.first { $0.name == "BaseWidget" })
    let derivedWidget = try #require(directSymbols.first { $0.name == "DerivedWidget" })
    let derivedBaseTypes = indexStoreClient.baseTypeUSRs(forUSR: derivedWidget.usr)
    #expect(derivedBaseTypes.contains { $0.usr == baseWidget.usr })
}

/// Copies `cross-file-witness` (source only, never any stale `.build`) into a fresh, unique temp
/// directory. Several tests in this file build this fixture; running `swift build` concurrently
/// against one *shared* directory's `.build/build.db` was found, empirically, to race (a real
/// SwiftPM build-database "disk I/O error" under concurrent `swift-testing` execution) once enough
/// tests did it at once -- giving each test its own private copy removes the race entirely rather
/// than serializing around it.
///
/// **Real-path resolution below is load-bearing, not cosmetic**: `NSTemporaryDirectory()` returns
/// a path under `/var/folders/...`, but `/var` is an APFS *firmlink* to `/private/var` on macOS --
/// not a regular symlink, so `Foundation`'s `URL.resolvingSymlinksInPath()` does *not* resolve it
/// (confirmed empirically: it returned the path completely unchanged). The real compiler/index-
/// store machinery records every source file's path already resolved (`/private/var/folders/...`,
/// confirmed via the POSIX `realpath(3)` call below, and via a real build+index showing IndexStoreDB's
/// own recorded locations in that form) -- an unresolved-path copy left every declaration's own
/// location using the *unresolved* form, which then never matched any real indexed symbol's
/// location, silently leaving `containingTypeUSR` unresolved (a real, subtle path-identity bug
/// found and fixed this session, not a guess). `realpath(3)` (not `resolvingSymlinksInPath`)
/// correctly resolves firmlinks since it asks the OS/VFS directly, not a naive per-component
/// `readlink` walk -- called on `NSTemporaryDirectory()` itself (which exists) before appending
/// this fixture copy's own not-yet-existing subdirectory name.
private func copiedCrossFileWitnessFixture() throws -> URL {
    let originalRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/cross-file-witness")
    var pathBuffer = [Int8](repeating: 0, count: Int(PATH_MAX))
    let realTempDir: URL
    if let resolved = realpath(NSTemporaryDirectory(), &pathBuffer) {
        realTempDir = URL(fileURLWithPath: String(cString: resolved))
    } else {
        realTempDir = URL(fileURLWithPath: NSTemporaryDirectory())
    }
    let copyRoot = realTempDir.appendingPathComponent("swift-isolation-map-fixture-copy-\(UUID().uuidString)")
    try? FileManager.default.removeItem(at: copyRoot)
    try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true)
    for name in ["Package.swift", "Sources"] {
        try FileManager.default.copyItem(at: originalRoot.appendingPathComponent(name), to: copyRoot.appendingPathComponent(name))
    }
    return copyRoot
}

/// Extension-of-an-external-type fix (docs/task-external-type-extension-isolation.md): verifies
/// the `.childOf`/`.extendedBy` chain (`containingExtensionUSR` + `extendedTypeUSR`) resolves a
/// member's extended type correctly for three real shapes -- a genuinely external SDK type
/// (`NSView`, real AppKit, `@MainActor`), a nested extended type (V4), and a generic extended type
/// (V4) -- against a real index store, not assumed.
@Test("containingExtensionUSR + extendedTypeUSR resolve the real extended type for an external SDK type, a nested type, and a generic type")
func extensionChainResolvesExternalNestedAndGenericExtendedTypes() throws {
    let fixtureRoot = try copiedCrossFileWitnessFixture()
    let sourcesDirectory = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness")
    let indexStorePath = NSTemporaryDirectory() + "swift-isolation-map-test-extchain-store-\(UUID().uuidString)"
    let databasePath = NSTemporaryDirectory() + "swift-isolation-map-test-extchain-db-\(UUID().uuidString)"

    let processRunner = LiveProcessRunner()
    let buildResult = try processRunner.run(
        executable: "swift",
        arguments: ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", indexStorePath],
        workingDirectory: fixtureRoot
    )
    #expect(buildResult.exitCode == 0, "fixture build failed: \(buildResult.standardError)")

    let indexStoreClient = try IndexStoreClient(storePath: indexStorePath, databasePath: databasePath)
    let extensionFile = sourcesDirectory.appendingPathComponent("ExtensionOfExternalType.swift").path
    let symbols = indexStoreClient.definedSymbols(inFile: extensionFile)

    // Real SDK type (external, no primary declaration in this project) -- the motivating shape.
    let realExtensionMethod = try #require(symbols.first { $0.name == "realExtensionMethod()" })
    let realExtensionUSR = try #require(indexStoreClient.containingExtensionUSR(forMemberUSR: realExtensionMethod.usr))
    let realExtendedTypeUSR = try #require(indexStoreClient.extendedTypeUSR(forExtensionUSR: realExtensionUSR))
    #expect(realExtendedTypeUSR == "c:objc(cs)NSView")

    // V4: nested extended type.
    let nestedInner = try #require(symbols.first { $0.name == "Inner" })
    let nestedMethod = try #require(symbols.first { $0.name == "nestedExtensionMethod()" })
    let nestedExtensionUSR = try #require(indexStoreClient.containingExtensionUSR(forMemberUSR: nestedMethod.usr))
    let nestedExtendedTypeUSR = try #require(indexStoreClient.extendedTypeUSR(forExtensionUSR: nestedExtensionUSR))
    #expect(nestedExtendedTypeUSR == nestedInner.usr)

    // V4: generic extended type.
    let genericContainer = try #require(symbols.first { $0.name == "GenericContainer" })
    let genericMethod = try #require(symbols.first { $0.name == "genericExtensionMethod()" })
    let genericExtensionUSR = try #require(indexStoreClient.containingExtensionUSR(forMemberUSR: genericMethod.usr))
    let genericExtendedTypeUSR = try #require(indexStoreClient.extendedTypeUSR(forExtensionUSR: genericExtensionUSR))
    #expect(genericExtendedTypeUSR == genericContainer.usr)
}

/// The full `DeclarationLinker.link(_:)` pass: `realExtensionMethod`'s `containingTypeUSR` (a
/// `syntactic:NSView` placeholder with no primary declaration to resolve against) gets rewritten
/// to `NSView`'s own real clang USR, exactly the fact `ExternalIsolationBackfill` needs to backfill
/// its isolation and `IsolationInferenceEngine` needs to propagate it -- confirming the full
/// pipeline seam this task's own DoD insists on, not just the two raw index queries above.
@Test("DeclarationLinker.link(_:) rewrites an extension member's containingTypeUSR to the real extended type's USR")
func linkRewritesExtensionMemberContainingTypeUSR() throws {
    let fixtureRoot = try copiedCrossFileWitnessFixture()
    let sourcesDirectory = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness")
    let indexStorePath = NSTemporaryDirectory() + "swift-isolation-map-test-extlink-store-\(UUID().uuidString)"
    let databasePath = NSTemporaryDirectory() + "swift-isolation-map-test-extlink-db-\(UUID().uuidString)"

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
}
