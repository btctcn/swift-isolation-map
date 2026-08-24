import Foundation
import Testing
import OutputFormat
@testable import ProjectResolution

/// Golden-fixture regression test for Issue #40 (`Tests/Fixtures/third-party-global-actor`): a
/// real, compiling out-of-tree SwiftPM package dependency (`ExternalDep`) declares its own custom
/// `@globalActor` (`ThirdPartyActor`), invisible to the analyzed project's own syntactic scan by
/// construction. Same real-CLI-subprocess tier as `CompiledDependencyCLITests.swift`, paired with
/// real `swiftc -typecheck` ground truth for both fixture calls, not just an assertion against
/// this tool's own output -- the same discipline that investigation used throughout.
@Suite("Issue #40: real third-party global actor, closure-attribute recognition + external isolation")
struct ThirdPartyGlobalActorCLITests {
    static let fixtureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ThirdPartyGlobalActorCLITests.swift -> swift-isolation-mapTests
        .deletingLastPathComponent() // swift-isolation-mapTests -> Tests
        .appendingPathComponent("Fixtures/third-party-global-actor")

    static let externalDepRoot = fixtureRoot.appendingPathComponent("ExternalDep")
    static let consumerRoot = fixtureRoot.appendingPathComponent("Consumer")

    static func sdkPath() throws -> String {
        let result = try LiveProcessRunner().run(executable: "xcrun", arguments: ["--show-sdk-path", "--sdk", "macosx"], workingDirectory: nil)
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func targetTriple() -> String {
        #if arch(arm64)
        return "arm64-apple-macosx13.0"
        #else
        return "x86_64-apple-macosx13.0"
        #endif
    }

    /// Real `xcrun swiftc -typecheck` ground truth, mirroring `CompiledDependencyCLITests
    /// .typecheckDiagnostics` -- the same paired-with-the-real-compiler discipline, here proving
    /// `ThirdPartyActor` is a genuine, working global actor (not a hypothetical shape) before
    /// trusting any assertion about how this tool reports it.
    static func typecheckDiagnostics(_ source: String) throws -> (exitCode: Int32, output: String) {
        let sdk = try sdkPath()
        let modulesDirectory = try modulesDirectory()
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("third-party-global-actor-proof-\(UUID().uuidString).swift")
        try source.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let result = try LiveProcessRunner().run(
            executable: "xcrun",
            arguments: ["swiftc", "-swift-version", "6", "-sdk", sdk, "-target", targetTriple(), "-I", modulesDirectory.path, "-typecheck", tempFile.path],
            workingDirectory: nil
        )
        return (result.exitCode, result.standardOutput + result.standardError)
    }

    /// `ExternalDep` is a real SwiftPM package `Consumer` depends on via `.package(path:)` --
    /// building `Consumer` once (which this test's own `runCLI()` already does, indirectly, via
    /// the CLI's own indexing build) leaves `ThirdPartyActorKit.swiftmodule` right where SwiftPM
    /// always puts a dependency's own build products: `<bin-path>/Modules/`.
    static func modulesDirectory() throws -> URL {
        let result = try LiveProcessRunner().run(executable: "swift", arguments: ["build", "--show-bin-path"], workingDirectory: consumerRoot)
        let binPath = URL(fileURLWithPath: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        return binPath.appendingPathComponent("Modules")
    }

    static func runCLI() throws -> AnalysisReport {
        let processRunner = LiveProcessRunner()
        // fixtureRoot = Tests/Fixtures/third-party-global-actor -> up three levels -> repo root.
        let repoRoot = fixtureRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let cliBinary = CapstoneCLITests.locateCLIBinary(repoRoot: repoRoot) else {
            Issue.record("No built swift-isolation-map binary found -- run `swift build` first.")
            throw CocoaError(.fileNoSuchFile)
        }
        for relativePath in [".build", ".swift-isolation-map-manifest.json", ".swift-isolation-map-index-db", ".swift-isolation-map-index-store"] {
            try? FileManager.default.removeItem(atPath: consumerRoot.appendingPathComponent(relativePath).path)
        }
        let result = try processRunner.run(
            executable: cliBinary.path,
            arguments: [consumerRoot.appendingPathComponent("Package.swift").path, "--scheme", "Consumer", "--output", "json", "--force-reindex"],
            workingDirectory: consumerRoot
        )
        return try JSONDecoder().decode(AnalysisReport.self, from: Data(result.standardOutput.utf8))
    }

    @Test("A closure attributed with a real third-party global actor (Task { @ThirdPartyActor in ... }) is recognized as genuinely protected, not reported as a false-positive high-risk boundary")
    func closureAttributedWithThirdPartyGlobalActorIsRecognized() throws {
        let report = try Self.runCLI()

        func usr(named name: String) throws -> String {
            try #require(report.nodes.first { $0.name == name }).usr
        }
        func edges(from callerName: String) throws -> [AnalysisEdge] {
            let callerUSR = try usr(named: callerName)
            return report.edges.filter { $0.callerUSR == callerUSR }
        }

        // --- Ground truth: the attributed call genuinely compiles clean (real protection) ---
        let (protectedExit, _) = try Self.typecheckDiagnostics("""
            import ThirdPartyActorKit
            func callFromNonisolated() {
                Task { @ThirdPartyActor in
                    thirdPartyIsolatedWork()
                }
            }
            """)
        #expect(protectedExit == 0, "the closure genuinely protects this call -- if this fails, the fixture itself no longer proves what this test claims")

        // --- Ground truth: the exact same call, minus the attribute, is a hard compile error ---
        let (unprotectedExit, unprotectedOutput) = try Self.typecheckDiagnostics("""
            import ThirdPartyActorKit
            func callFromNonisolated() {
                Task {
                    thirdPartyIsolatedWork()
                }
            }
            """)
        #expect(unprotectedExit != 0, "ThirdPartyActor must be a real, enforced global actor -- otherwise this whole fixture proves nothing")
        #expect(unprotectedOutput.contains("global actor 'ThirdPartyActor'-isolated"))

        // --- The tool's own report: no false-positive high-risk edge for the protected call ---
        let protectedEdges = try edges(from: "callFromNonisolated")
        #expect(
            !protectedEdges.contains { $0.risk == .high && !$0.isUnknown },
            "Issue #40's own preserved-false-positive shape: before the fix, ClosureIsolationExtractor.classify couldn't recognize @ThirdPartyActor (invisible to this project's own syntactic scan), so callFromNonisolated resolved plain nonisolated and this edge was wrongly flagged high risk despite the closure genuinely protecting it"
        )

        // --- The tool's own report: the genuinely risky, unprotected control IS flagged ---
        // Real, correctly-awaited nonisolated -> globalActor crossing -- matches this tool's own
        // precedent (CompiledDependencyCLITests' Mechanism A): deliberately still .high, migration
        // debt, not a false positive.
        let controlEdges = try edges(from: "plainDirectCall")
        #expect(!controlEdges.isEmpty)
        #expect(controlEdges.allSatisfy { $0.risk == .high && !$0.isUnknown })

        // --- The callee's own external isolation resolves correctly, not just the edge shape ---
        // An externally-backfilled node has no human-readable name of its own (`AnalysisReportBuilder
        // .build`'s own edge-level backfill always uses the USR itself as `name`, matching
        // `ExternalIsolationBackfill.applyEdgeLevelOutcomes`) -- looked up via the control edge's own
        // `calleeUSR`, not by a name string this node was never going to carry.
        let calleeUSR = try #require(controlEdges.first).calleeUSR
        let calleeNode = try #require(report.nodes.first { $0.usr == calleeUSR })
        #expect(calleeNode.isolation == "globalActor(ThirdPartyActor)")
    }
}
