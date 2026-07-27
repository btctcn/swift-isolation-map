import Foundation
import Testing
import OutputFormat
@testable import ProjectResolution
@testable import swift_isolation_map

/// Golden-fixture matrix for the compiled-dependency-isolation research thread
/// (`docs/task-compiled-dependency-isolation.md`, `docs/compiled-dependency-isolation-sourcekit-lsp-spike.md`).
/// Same tier as `CapstoneCLITests.swift` (real CLI subprocess, `--force-reindex --output json`),
/// but against `Tests/Fixtures/compiled-dependency/Consumer`, which is wired to a real, purpose-
/// built out-of-tree compiled dependency (`Tests/Fixtures/compiled-dependency/ExternalDep`) --
/// built fresh by this test, every run, never pre-built/committed (binary artifacts vary by
/// toolchain). Every case is paired with a real `swiftc -typecheck` ground-truth check, not just
/// an assertion against the tool's own output -- the same discipline every finding in the
/// research thread itself used (`repro2.swift`).
@Suite("Compiled-dependency isolation: golden fixture matrix")
struct CompiledDependencyCLITests {
    static let fixtureRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CompiledDependencyCLITests.swift -> swift-isolation-mapTests
        .deletingLastPathComponent() // swift-isolation-mapTests -> Tests
        .appendingPathComponent("Fixtures/compiled-dependency")

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

    /// Builds `ExternalDep`'s two targets fresh, matching the exact recipe the research spike
    /// proved out empirically (`docs/compiled-dependency-isolation-sourcekit-lsp-spike.md`):
    /// no `-enable-library-evolution` (genuine case 4, confirmed below to produce zero
    /// `.swiftinterface` files), `ExternalDepDefault` additionally compiled with
    /// `-default-isolation MainActor`.
    static func buildExternalDep() throws {
        let sdk = try sdkPath()
        let target = targetTriple()
        let runner = LiveProcessRunner()

        try? FileManager.default.removeItem(at: externalDepRoot.appendingPathComponent("build"))

        let coreBuildDir = externalDepRoot.appendingPathComponent("build/Core")
        try FileManager.default.createDirectory(at: coreBuildDir, withIntermediateDirectories: true)
        let coreResult = try runner.run(
            executable: "xcrun",
            arguments: [
                "swiftc", "-swift-version", "5", "-sdk", sdk, "-target", target,
                "-emit-module", "-emit-library",
                "-module-name", "ExternalDepCore",
                "-o", coreBuildDir.appendingPathComponent("libExternalDepCore.dylib").path,
                "-emit-module-path", coreBuildDir.appendingPathComponent("ExternalDepCore.swiftmodule").path,
                externalDepRoot.appendingPathComponent("Sources/ExternalDepCore/ExternalDepCore.swift").path
            ],
            workingDirectory: nil
        )
        #expect(coreResult.exitCode == 0, "ExternalDepCore build failed: \(coreResult.standardError)")

        let defaultBuildDir = externalDepRoot.appendingPathComponent("build/Default")
        try FileManager.default.createDirectory(at: defaultBuildDir, withIntermediateDirectories: true)
        let defaultResult = try runner.run(
            executable: "xcrun",
            arguments: [
                "swiftc", "-swift-version", "6", "-sdk", sdk, "-target", target,
                "-default-isolation", "MainActor",
                "-emit-module", "-emit-library",
                "-module-name", "ExternalDepDefault",
                "-o", defaultBuildDir.appendingPathComponent("libExternalDepDefault.dylib").path,
                "-emit-module-path", defaultBuildDir.appendingPathComponent("ExternalDepDefault.swiftmodule").path,
                externalDepRoot.appendingPathComponent("Sources/ExternalDepDefault/ExternalDepDefault.swift").path
            ],
            workingDirectory: nil
        )
        #expect(defaultResult.exitCode == 0, "ExternalDepDefault build failed: \(defaultResult.standardError)")

        // Case 4 must be genuine: confirm no `.swiftinterface` was produced anywhere, not assumed.
        for dir in [coreBuildDir, defaultBuildDir] {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            #expect(!contents.contains { $0.hasSuffix(".swiftinterface") }, "case 4 requires zero .swiftinterface files in \(dir.path)")
        }
    }

    /// `xcrun swiftc -typecheck`, real toolchain, real diagnostics -- the same paired ground-truth
    /// discipline every finding in the research thread used (`repro2.swift`). `-swift-version 6`
    /// matches `Consumer/Package.swift`'s own `swift-tools-version: 6.0` (SwiftPM's real compiled
    /// language mode for this fixture, confirmed to matter empirically: an earlier `-swift-version
    /// 5` ground-truth check for the same code gave a different diagnostic level).
    static func typecheckDiagnostics(_ source: String, extraArguments: [String] = []) throws -> (exitCode: Int32, output: String) {
        let sdk = try sdkPath()
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("compiled-dep-proof-\(UUID().uuidString).swift")
        try source.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }
        let result = try LiveProcessRunner().run(
            executable: "xcrun",
            arguments: ["swiftc", "-swift-version", "6", "-sdk", sdk, "-target", targetTriple()] + extraArguments + ["-typecheck", tempFile.path],
            workingDirectory: nil
        )
        return (result.exitCode, result.standardOutput + result.standardError)
    }

    static func runCLI() throws -> AnalysisReport {
        let processRunner = LiveProcessRunner()
        // fixtureRoot = Tests/Fixtures/compiled-dependency -> up three levels -> repo root.
        let repoRoot = fixtureRoot.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let cliBinary = CapstoneCLITests.locateCLIBinary(repoRoot: repoRoot) else {
            Issue.record("No built swift-isolation-map binary found -- run `swift build` first.")
            throw CocoaError(.fileNoSuchFile)
        }
        for relativePath in [".build", ".swift-isolation-map-manifest.json", ".swift-isolation-map-index-db"] {
            try? FileManager.default.removeItem(atPath: consumerRoot.appendingPathComponent(relativePath).path)
        }
        let result = try processRunner.run(
            executable: cliBinary.path,
            arguments: [consumerRoot.appendingPathComponent("Package.swift").path, "--scheme", "Consumer", "--output", "json", "--force-reindex"],
            workingDirectory: consumerRoot
        )
        return try JSONDecoder().decode(AnalysisReport.self, from: Data(result.standardOutput.utf8))
    }

    @Test("The full compiled-dependency fixture matrix resolves correctly, matched against real swiftc ground truth for every case")
    func fullFixtureMatrix() throws {
        try Self.buildExternalDep()
        let report = try Self.runCLI()

        // Robust by construction: looks up the real (possibly USR-mangled, possibly compressed --
        // confirmed empirically that a name-substring match on a mangled USR is NOT reliable, e.g.
        // "ModuleDefaultIsolated"'s mangling compresses away the literal substring because it
        // shares characters with its own module name "ExternalDepDefault") USR via the human-
        // readable node name the report already carries correctly, then matches edges by that
        // real USR -- never by guessing at mangled-name substrings.
        func usr(named name: String) throws -> String {
            try #require(report.nodes.first { $0.name == name }).usr
        }
        func edges(from callerName: String) throws -> [AnalysisEdge] {
            let callerUSR = try usr(named: callerName)
            return report.edges.filter { $0.callerUSR == callerUSR }
        }
        func edges(to calleeName: String) throws -> [AnalysisEdge] {
            let calleeUSR = try usr(named: calleeName)
            return report.edges.filter { $0.calleeUSR == calleeUSR }
        }

        // --- Mechanism A: real ObjC-bridged SDK type (NSCell) ---
        #expect(try usr(named: "ProjectCell").isEmpty == false)
        let projectCellNode = try #require(report.nodes.first { $0.name == "ProjectCell" })
        #expect(projectCellNode.isolation == "globalActor(MainActor)")
        let mechanismAEdges = try edges(from: "callMechanismA")
        #expect(!mechanismAEdges.isEmpty)
        #expect(mechanismAEdges.allSatisfy { $0.risk == .high && !$0.isUnknown })
        // ObjC-bridged (NS_SWIFT_UI_ACTOR/`@preconcurrency`-treated) isolation violations are real
        // but the compiler downgrades them to *warnings*, not hard errors, for Apple-SDK migration
        // compatibility -- confirmed empirically, differs from the pure-Swift cases below. Still a
        // real, checkable ground-truth signal: the specific diagnostic text must be present.
        let (mechanismAExit, mechanismAOutput) = try Self.typecheckDiagnostics("""
            import AppKit
            final class GroundTruthCell: NSCell {
                func touch() { title = "x" }
            }
            func callFromNonisolated() {
                GroundTruthCell().touch()
            }
            """)
        #expect(mechanismAExit == 0, "ObjC-bridged violations are warnings, not hard errors -- exit 0 is the real, correct ground truth")
        #expect(mechanismAOutput.contains("main actor-isolated instance method 'touch()'"))
        #expect(mechanismAOutput.contains("main actor isolation inferred from inheritance from class 'NSCell'"))

        // --- Mechanism B: real pure-Swift SDK protocol (SwiftUI.View) ---
        let projectViewNode = try #require(report.nodes.first { $0.name == "ProjectView" })
        #expect(projectViewNode.isolation == "globalActor(MainActor)")
        // `View`'s synthesized struct initializer does *not* itself inherit the protocol's
        // `@MainActor` isolation (confirmed empirically, see `MechanismB.swift`'s own comment) --
        // the ground truth to check is `.body`, the protocol's real isolated requirement.
        let (mechanismBExit, mechanismBOutput) = try Self.typecheckDiagnostics("""
            import SwiftUI
            struct GroundTruthView: View { var body: some View { Text("hi") } }
            func callFromNonisolated() async {
                _ = await GroundTruthView().body
            }
            """)
        #expect(mechanismBExit != 0, "SwiftUI.View's body requirement isolation must be real")
        #expect(mechanismBOutput.contains("main actor-isolated context"))

        // --- Case 4: .swiftmodule-only dependency, attribute-less inheritance chain ---
        let subclassNode = try #require(report.nodes.first { $0.name == "ProjectSubclassOfInferredChild" })
        #expect(subclassNode.isolation == "globalActor(MainActor)")
        let case4Edges = try edges(from: "callCase4")
        #expect(!case4Edges.isEmpty)
        #expect(case4Edges.allSatisfy { $0.risk == .high && !$0.isUnknown })
        let coreBuildDir = Self.externalDepRoot.appendingPathComponent("build/Core").path
        let (case4Exit, _) = try Self.typecheckDiagnostics("""
            import ExternalDepCore
            final class GroundTruthSubclass: InferredChild {}
            func callFromNonisolated() {
                GroundTruthSubclass().touch()
            }
            """, extraArguments: ["-I", coreBuildDir])
        #expect(case4Exit != 0, "case 4's inherited, attribute-less isolation must be real -- pure Swift, not ObjC-bridged, so this is a hard error")

        // --- DivergentIsolation: member/type isolation divergence, USR selection proof ---
        // The `nonisolated init()` call must NOT be a finding at all (no edge for it).
        let divergentInitUSR = try usr(named: "callDivergentInit")
        #expect(!report.edges.contains { $0.callerUSR == divergentInitUSR })
        let divergentMethodEdges = try edges(from: "callDivergentMethod")
        #expect(!divergentMethodEdges.isEmpty)
        #expect(divergentMethodEdges.allSatisfy { $0.risk == .high && !$0.isUnknown })
        let (divergentInitExit, _) = try Self.typecheckDiagnostics("""
            import ExternalDepCore
            func constructFromNonisolated() -> DivergentIsolation {
                DivergentIsolation()
            }
            """, extraArguments: ["-I", coreBuildDir])
        #expect(divergentInitExit == 0, "the nonisolated init must genuinely compile without await -- this is the edge that must not be a finding")
        let (divergentMethodExit, _) = try Self.typecheckDiagnostics("""
            import ExternalDepCore
            func callMethodFromNonisolated(_ value: DivergentIsolation) {
                value.isolatedMethod()
            }
            """, extraArguments: ["-I", coreBuildDir])
        #expect(divergentMethodExit != 0, "the @MainActor method must genuinely require isolation -- pure Swift, hard error")

        // --- Module-default isolation (SE-0466): no attribute anywhere, module build flag only ---
        let moduleDefaultEdges = try edges(from: "callModuleDefault")
        #expect(!moduleDefaultEdges.isEmpty)
        #expect(moduleDefaultEdges.allSatisfy { $0.risk == .high && !$0.isUnknown })
        let defaultBuildDir = Self.externalDepRoot.appendingPathComponent("build/Default").path
        let (moduleDefaultExit, _) = try Self.typecheckDiagnostics("""
            import ExternalDepDefault
            func callFromNonisolated(_ value: ModuleDefaultIsolated) {
                value.touch()
            }
            """, extraArguments: ["-I", defaultBuildDir])
        #expect(moduleDefaultExit != 0, "module-default isolation must be real even with no attribute anywhere -- pure Swift, hard error")

        // --- Negative control: genuinely, unambiguously nonisolated ---
        let negativeControlUSR = try usr(named: "callNegativeControl")
        #expect(!report.edges.contains { $0.callerUSR == negativeControlUSR })
        let (negativeControlExit, _) = try Self.typecheckDiagnostics("""
            import ExternalDepCore
            func callFromNonisolated() {
                PlainNonisolated().touch()
            }
            """, extraArguments: ["-I", coreBuildDir])
        #expect(negativeControlExit == 0, "the negative control must genuinely compile clean -- no false positive")

        // --- unknown, not silently miscounted: a real, naturally-occurring USR-granularity miss ---
        // `cell.title = "x"` desugars to a call into NSCell's ObjC-bridged property setter, whose
        // USR `sourcekitd` cursor-info cannot match at that source position (same class of
        // granularity mismatch as the `Counter.value` accessor case found in `CapstoneCLITests`,
        // see docs/priority-3-phase-c-oracle-triggers.md) -- correctly `unknown`, not a confirmed
        // risk, never silently dropped or miscounted either.
        let setterEdges = report.edges.filter { $0.calleeUSR.contains("NSCell") && $0.calleeUSR.contains("setTitle") }
        let setterEdge = try #require(setterEdges.first)
        #expect(setterEdge.isUnknown)
        // The callee resolves to `.unspecified` (never backfilled), which the *existing*,
        // unmodified risk formula already keys off of, so this edge reads `medium`, not `high`
        // (`riskLevel`'s `.high` branch requires the callee to resolve `isIsolated`, which
        // `.unspecified` never does). The formula-level guarantee that an `isUnknown` edge whose
        // *raw* risk would be `.high` is still excluded from `highRiskBoundaries` is verified
        // directly, with hand-constructed data, in `AnalysisReportBuilderTests.swift` -- not
        // naturally reproducible from this real fixture, since every edge-level unknown here
        // structurally resolves through `.unspecified`.
        #expect(setterEdge.risk == .medium)
        #expect(!report.edges.contains { $0.isUnknown && $0.risk == .high })
    }
}
