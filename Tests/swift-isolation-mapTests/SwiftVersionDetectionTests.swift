import Foundation
import Testing
@testable import ProjectResolution
@testable import swift_isolation_map

@Suite("SwiftVersionDetection")
struct SwiftVersionDetectionTests {
    // Real `xcodebuild -showBuildSettings -project SQLumen.xcodeproj -scheme SQLumen` output,
    // captured empirically (see docs/priority-2-phase-4-cli-wiring.md) -- deliberately includes
    // `EFFECTIVE_SWIFT_VERSION` alongside `SWIFT_VERSION`, since a naive substring match on the
    // real project would have false-positive-matched the wrong line.
    static let realShowBuildSettingsOutput = """
        Build settings for action build and target SQLumen:
            DEVELOPMENT_TEAM =
            EFFECTIVE_SWIFT_VERSION = 5
            SWIFT_VERSION = 5.0
        """

    @Test("Xcode language mode: parses SWIFT_VERSION, not EFFECTIVE_SWIFT_VERSION")
    func xcodeLanguageModeParsesRealOutput() throws {
        let runner = FakeProcessRunner()
        let projectURL = URL(fileURLWithPath: "/tmp/SQLumen.xcodeproj")
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showBuildSettings", "-scheme", "SQLumen", "-project", projectURL.path],
            result: ProcessResult(exitCode: 0, standardOutput: Self.realShowBuildSettingsOutput, standardError: "")
        )
        let mode = try SwiftVersionDetection.xcodeLanguageMode(
            container: .xcodeproj(projectURL),
            schemeName: "SQLumen",
            processRunning: runner
        )
        #expect(mode == "5.0")
    }

    @Test("Xcode language mode: uses -workspace for .xcworkspace containers")
    func xcodeLanguageModeUsesWorkspaceFlag() throws {
        let runner = FakeProcessRunner()
        let workspaceURL = URL(fileURLWithPath: "/tmp/App.xcworkspace")
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showBuildSettings", "-scheme", "App", "-workspace", workspaceURL.path],
            result: ProcessResult(exitCode: 0, standardOutput: "    SWIFT_VERSION = 6.0", standardError: "")
        )
        let mode = try SwiftVersionDetection.xcodeLanguageMode(
            container: .xcworkspace(workspaceURL),
            schemeName: "App",
            processRunning: runner
        )
        #expect(mode == "6.0")
    }

    @Test("Xcode language mode: throws when the setting is missing")
    func xcodeLanguageModeThrowsWhenSettingMissing() {
        let runner = FakeProcessRunner()
        let projectURL = URL(fileURLWithPath: "/tmp/Empty.xcodeproj")
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showBuildSettings", "-scheme", "Empty", "-project", projectURL.path],
            result: ProcessResult(exitCode: 0, standardOutput: "    DEVELOPMENT_TEAM =", standardError: "")
        )
        #expect(throws: SwiftVersionDetectionError.swiftVersionSettingNotFound) {
            try SwiftVersionDetection.xcodeLanguageMode(container: .xcodeproj(projectURL), schemeName: "Empty", processRunning: runner)
        }
    }

    @Test("Xcode language mode: throws when xcodebuild exits non-zero")
    func xcodeLanguageModeThrowsOnFailure() {
        let runner = FakeProcessRunner()
        let projectURL = URL(fileURLWithPath: "/tmp/Broken.xcodeproj")
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showBuildSettings", "-scheme", "Broken", "-project", projectURL.path],
            result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "scheme not found")
        )
        #expect(throws: SwiftVersionDetectionError.xcodebuildFailed(exitCode: 1, standardError: "scheme not found")) {
            try SwiftVersionDetection.xcodeLanguageMode(container: .xcodeproj(projectURL), schemeName: "Broken", processRunning: runner)
        }
    }

    // Real `swift --version` output, captured empirically: the version is on stdout, the
    // `swift-driver version:` line is on stderr.
    @Test("Compiler version: parses real `swift --version` output")
    func compilerVersionParsesRealOutput() throws {
        let runner = FakeProcessRunner()
        runner.stub(
            executable: "swift",
            arguments: ["--version"],
            result: ProcessResult(
                exitCode: 0,
                standardOutput: "Apple Swift version 6.3 (swiftlang-6.3.0.123.5 clang-2100.0.123.102)\nTarget: arm64-apple-macosx26.0",
                standardError: "swift-driver version: 1.148.6"
            )
        )
        #expect(try SwiftVersionDetection.compilerVersion(processRunning: runner) == "6.3")
    }

    @Test("Compiler version: throws on unrecognized output")
    func compilerVersionThrowsOnUnrecognizedOutput() {
        let runner = FakeProcessRunner()
        runner.stub(executable: "swift", arguments: ["--version"], result: ProcessResult(exitCode: 0, standardOutput: "nonsense", standardError: ""))
        #expect(throws: SwiftVersionDetectionError.self) {
            try SwiftVersionDetection.compilerVersion(processRunning: runner)
        }
    }

    @Test("Effective version: language mode < 6 wins regardless of compiler version")
    func effectiveVersionPrefersLanguageModeBelowSix() {
        #expect(SwiftVersionDetection.effectiveVersion(languageMode: "5.0", compilerVersion: "6.3") == "5.0")
        #expect(SwiftVersionDetection.effectiveVersion(languageMode: "4.2", compilerVersion: "6.3") == "4.2")
    }

    @Test("Effective version: language mode 6+ defers to the compiler version")
    func effectiveVersionPrefersCompilerVersionAtSixOrAbove() {
        #expect(SwiftVersionDetection.effectiveVersion(languageMode: "6.0", compilerVersion: "6.3") == "6.3")
        #expect(SwiftVersionDetection.effectiveVersion(languageMode: "6.0", compilerVersion: "6.0") == "6.0")
    }
}
