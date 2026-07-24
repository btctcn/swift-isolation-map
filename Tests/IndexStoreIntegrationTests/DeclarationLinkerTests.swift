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
