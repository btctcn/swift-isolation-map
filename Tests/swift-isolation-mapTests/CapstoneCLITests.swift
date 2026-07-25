import Foundation
import Testing
import OutputFormat
@testable import ProjectResolution
@testable import swift_isolation_map

/// Capstone golden-fixture test for Priority 2 Phase 4: the first test that exercises *every*
/// phase composed together for real -- invokes the actual built CLI binary (not internal Swift
/// calls) end to end against `Tests/Fixtures/simple-actor/`, a real SPM package with one
/// deliberate cross-isolation call, and diffs the real JSON result.
///
/// `--force-reindex` is used deliberately (not a pre-built index store + a plain run): this is
/// the CLI's own real rebuild path (`resolveIndexStoreURL`'s `.rebuildThenProceed` branch,
/// `SwiftIsolationMap.build(...)`), the one branch that mutates external state -- the plan for
/// this phase explicitly called out budgeting real testing time for it, not just exercising the
/// already-fresh-store path.
@Suite("Capstone: end-to-end CLI invocation")
struct CapstoneCLITests {
    static func locateCLIBinary(repoRoot: URL) -> URL? {
        for configuration in ["release", "debug"] {
            let candidate = repoRoot.appendingPathComponent(".build/\(configuration)/swift-isolation-map")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    @Test("Real CLI invocation against a real fixture: one actor, one nonisolated caller, one high-risk edge")
    func endToEndCLIInvocationProducesExpectedReport() throws {
        let testFileDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CapstoneCLITests.swift -> swift-isolation-mapTests
            .deletingLastPathComponent() // swift-isolation-mapTests -> Tests
        let repoRoot = testFileDirectory.deletingLastPathComponent() // Tests -> repo root
        let fixtureRoot = testFileDirectory.appendingPathComponent("Fixtures/simple-actor")

        guard let cliBinary = Self.locateCLIBinary(repoRoot: repoRoot) else {
            Issue.record("No built swift-isolation-map binary found under \(repoRoot.path)/.build/{release,debug} -- run `swift build` first.")
            return
        }

        // Same precaution as the Phase 3 cross-file-witness golden test: clear the fixture's own
        // build/staleness state first, so this test always exercises a real, fresh rebuild rather
        // than silently reusing state left over from a previous run (or from manually compiling
        // this fixture while developing it).
        let fileManager = FileManager.default
        for relativePath in [".build", ".swift-isolation-map-manifest.json", ".swift-isolation-map-index-db"] {
            try? fileManager.removeItem(atPath: fixtureRoot.appendingPathComponent(relativePath).path)
        }

        let processRunner = LiveProcessRunner()
        let packagePath = fixtureRoot.appendingPathComponent("Package.swift").path
        let result = try processRunner.run(
            executable: cliBinary.path,
            arguments: [packagePath, "--scheme", "SimpleActorApp", "--output", "json", "--force-reindex"],
            workingDirectory: fixtureRoot
        )

        // Exactly one high-risk cross-isolation boundary exists in the fixture (nonisolated
        // `trigger` reaching `Counter.increment()`) -- the documented exit-code contract
        // (section 3.5.3: exit 1 iff any high-risk boundary exists) says this run must exit 1.
        #expect(result.exitCode == 1, "CLI stderr: \(result.standardError)")

        let report = try JSONDecoder().decode(AnalysisReport.self, from: Data(result.standardOutput.utf8))

        #expect(report.schemaVersion == AnalysisReportBuilder.schemaVersion)
        #expect(report.toolVersion == SwiftIsolationMap.toolVersion)
        // The real active toolchain's own compiler version -- not hardcoded, since it legitimately
        // varies across machines/CI images; fetched the same way the CLI itself does.
        let expectedCompilerVersion = try SwiftVersionDetection.compilerVersion(processRunning: processRunner)
        #expect(report.swiftVersion == expectedCompilerVersion)

        let counterNode = try #require(report.nodes.first { $0.name == "Counter" })
        #expect(counterNode.isolation == "actor(Counter)")
        let incrementNode = try #require(report.nodes.first { $0.name == "increment" && $0.isolation == "actor(Counter)" })
        let triggerNode = try #require(report.nodes.first { $0.name == "trigger" })
        #expect(triggerNode.isolation == "nonisolated")

        #expect(report.summary.actors == 1)
        #expect(report.summary.crossActorBoundaries == 1)
        #expect(report.summary.highRiskBoundaries == 1)

        let edge = try #require(report.edges.first)
        #expect(edge.callerUSR == triggerNode.usr)
        #expect(edge.calleeUSR == incrementNode.usr)
        #expect(edge.risk == .high)
        #expect(edge.callerIsolation == "nonisolated")
        #expect(edge.calleeIsolation == "actor(Counter)")

        // The real rebuild also wrote a staleness manifest, per `run()`'s own contract.
        let manifestURL = fixtureRoot.appendingPathComponent(".swift-isolation-map-manifest.json")
        #expect(fileManager.fileExists(atPath: manifestURL.path))
    }
}
