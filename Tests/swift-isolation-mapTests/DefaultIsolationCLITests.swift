import Foundation
import Testing
import OutputFormat
@testable import ProjectResolution
@testable import swift_isolation_map

/// Regression test for issue #30 / docs/task-default-isolation-detection.md: confirms the real,
/// live CLI end to end, not just `Swift62RuleSet`/`Swift63RuleSet` in isolation -- this is exactly
/// the level a first, real live run against this fixture caught a genuine bug at (searching for
/// `-default-isolation` in the *first* file `compilerArguments` could resolve, which was
/// `Package.swift` itself, carrying no such flag, rather than a real target source file) that a
/// pure unit test on the rule sets alone would never have exercised.
@Suite("Default isolation (SE-0466): real end-to-end detection")
struct DefaultIsolationCLITests {
    @Test("Real CLI invocation against a fixture with `-default-isolation MainActor` configured")
    func endToEndCLIInvocationDetectsConfiguredDefaultIsolation() throws {
        let testFileDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DefaultIsolationCLITests.swift -> swift-isolation-mapTests
            .deletingLastPathComponent() // swift-isolation-mapTests -> Tests
        let repoRoot = testFileDirectory.deletingLastPathComponent() // Tests -> repo root
        let fixtureRoot = testFileDirectory.appendingPathComponent("Fixtures/default-isolation")

        guard let cliBinary = CapstoneCLITests.locateCLIBinary(repoRoot: repoRoot) else {
            Issue.record("No built swift-isolation-map binary found under \(repoRoot.path)/.build/{release,debug} -- run `swift build` first.")
            return
        }

        // Same precaution as CapstoneCLITests: always exercise a real, fresh rebuild rather than
        // silently reusing state left over from a previous run.
        let fileManager = FileManager.default
        for relativePath in [".build", ".swift-isolation-map-manifest.json"] {
            try? fileManager.removeItem(atPath: fixtureRoot.appendingPathComponent(relativePath).path)
        }

        let processRunner = LiveProcessRunner()
        let packagePath = fixtureRoot.appendingPathComponent("Package.swift").path
        let result = try processRunner.run(
            executable: cliBinary.path,
            arguments: [packagePath, "--scheme", "DefaultIsolationApp", "--output", "json", "--force-reindex"],
            workingDirectory: fixtureRoot
        )

        #expect(result.exitCode == 0, "CLI stderr: \(result.standardError)")

        let report = try JSONDecoder().decode(AnalysisReport.self, from: Data(result.standardOutput.utf8))

        // The module-default-eligible type picks up the real, configured MainActor default.
        let widgetNode = try #require(report.nodes.first { $0.name == "Widget" })
        #expect(widgetNode.isolation == "globalActor(MainActor)")
        let renderNode = try #require(report.nodes.first { $0.name == "render" })
        #expect(renderNode.isolation == "globalActor(MainActor)")

        // An explicit `nonisolated` attribute still wins over the configured default (rule 1 beats
        // rule 4) -- confirms this fix didn't regress explicit-attribute priority.
        let optedOutNode = try #require(report.nodes.first { $0.name == "ExplicitlyOptedOut" })
        #expect(optedOutNode.isolation == "nonisolated")

        #expect(report.summary.mainActorTypes == 1)
    }
}
