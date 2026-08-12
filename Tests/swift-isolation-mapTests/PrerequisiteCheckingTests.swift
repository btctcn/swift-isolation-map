import Foundation
import Testing
import IndexStoreIntegration
import ProjectResolution
import SourceKitDIntegration
@testable import swift_isolation_map

private let realSwiftPath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
private let libIndexStorePath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
private let sourcekitdInProcPath = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitdInProc.framework/sourcekitdInProc"

/// Stubs both `xcrun --find swift` (shared by both real locators) and makes both dylibs "exist" --
/// the healthy baseline every failure-mode test below starts from and deviates one piece at a time.
private func makeHealthyDoubles() -> (runner: FakeProcessRunner, fileSystem: FakeFileSystem) {
    let runner = FakeProcessRunner()
    runner.stub(executable: "xcrun", arguments: ["--find", "swift"], result: ProcessResult(exitCode: 0, standardOutput: realSwiftPath + "\n", standardError: ""))
    let fileSystem = FakeFileSystem()
    fileSystem.addFile(at: URL(fileURLWithPath: libIndexStorePath), contents: "fake")
    fileSystem.addFile(at: URL(fileURLWithPath: sourcekitdInProcPath), contents: "fake")
    return (runner, fileSystem)
}

@Test("Every prerequisite present -- no failures, for both an Xcode container and an SPM container")
func allPrerequisitesPresentProducesNoFailures() {
    let (runner, fileSystem) = makeHealthyDoubles()
    runner.stub(executable: "xcodebuild", arguments: ["-version"], result: ProcessResult(exitCode: 0, standardOutput: "Xcode 26.4\n", standardError: ""))
    runner.stub(executable: "swift", arguments: ["--version"], result: ProcessResult(exitCode: 0, standardOutput: "Apple Swift version 6.3\n", standardError: ""))

    let toolchainLocator = LiveToolchainLocator(processRunning: runner, fileSystem: fileSystem)
    let sourceKitDLocator = LiveSourceKitDLocator(processRunning: runner, fileSystem: fileSystem)

    #expect(PrerequisiteChecking.check(container: .xcodeproj(URL(fileURLWithPath: "/P.xcodeproj")), processRunning: runner, toolchainLocator: toolchainLocator, sourceKitDLocator: sourceKitDLocator).isEmpty)
    #expect(PrerequisiteChecking.check(container: .swiftPackage(URL(fileURLWithPath: "/P/Package.swift")), processRunning: runner, toolchainLocator: toolchainLocator, sourceKitDLocator: sourceKitDLocator).isEmpty)
}

@Test("xcrun itself failing is reported exactly once, not once per locator")
func xcrunFailureIsDeduplicated() {
    let runner = FakeProcessRunner()
    runner.stub(executable: "xcrun", arguments: ["--find", "swift"], result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "xcrun: error: unable to find utility \"swift\""))
    runner.stub(executable: "xcodebuild", arguments: ["-version"], result: ProcessResult(exitCode: 0, standardOutput: "Xcode 26.4\n", standardError: ""))
    let fileSystem = FakeFileSystem()

    let toolchainLocator = LiveToolchainLocator(processRunning: runner, fileSystem: fileSystem)
    let sourceKitDLocator = LiveSourceKitDLocator(processRunning: runner, fileSystem: fileSystem)

    let failures = PrerequisiteChecking.check(container: .xcodeproj(URL(fileURLWithPath: "/P.xcodeproj")), processRunning: runner, toolchainLocator: toolchainLocator, sourceKitDLocator: sourceKitDLocator)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("xcrun --find swift") == true)
}

@Test("libIndexStore.dylib missing on disk (xcrun otherwise healthy) is reported specifically, distinct from sourcekitdInProc")
func missingLibIndexStoreDylibIsReportedSpecifically() {
    let runner = FakeProcessRunner()
    runner.stub(executable: "xcrun", arguments: ["--find", "swift"], result: ProcessResult(exitCode: 0, standardOutput: realSwiftPath + "\n", standardError: ""))
    runner.stub(executable: "xcodebuild", arguments: ["-version"], result: ProcessResult(exitCode: 0, standardOutput: "Xcode 26.4\n", standardError: ""))
    let fileSystem = FakeFileSystem()
    fileSystem.addFile(at: URL(fileURLWithPath: sourcekitdInProcPath), contents: "fake") // only this one exists

    let toolchainLocator = LiveToolchainLocator(processRunning: runner, fileSystem: fileSystem)
    let sourceKitDLocator = LiveSourceKitDLocator(processRunning: runner, fileSystem: fileSystem)

    let failures = PrerequisiteChecking.check(container: .xcodeproj(URL(fileURLWithPath: "/P.xcodeproj")), processRunning: runner, toolchainLocator: toolchainLocator, sourceKitDLocator: sourceKitDLocator)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("libIndexStore.dylib") == true)
}

@Test("A genuinely missing xcodebuild (env's own not-found shape) gets the install/xcode-select hint, not a raw exit-127 dump")
func missingXcodebuildGetsTheNotFoundHint() {
    let (runner, fileSystem) = makeHealthyDoubles()
    runner.stub(executable: "xcodebuild", arguments: ["-version"], result: ProcessResult(exitCode: 127, standardOutput: "", standardError: "env: xcodebuild: No such file or directory\n"))

    let toolchainLocator = LiveToolchainLocator(processRunning: runner, fileSystem: fileSystem)
    let sourceKitDLocator = LiveSourceKitDLocator(processRunning: runner, fileSystem: fileSystem)

    let failures = PrerequisiteChecking.check(container: .xcworkspace(URL(fileURLWithPath: "/P.xcworkspace")), processRunning: runner, toolchainLocator: toolchainLocator, sourceKitDLocator: sourceKitDLocator)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("Install Xcode from the App Store") == true)
}

@Test("xcodebuild present but restricted to Command Line Tools only gets the specific xcode-select remediation")
func commandLineToolsOnlyGetsTheXcodeSelectHint() {
    let (runner, fileSystem) = makeHealthyDoubles()
    runner.stub(
        executable: "xcodebuild", arguments: ["-version"],
        result: ProcessResult(
            exitCode: 1, standardOutput: "",
            standardError: "xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance"
        )
    )

    let toolchainLocator = LiveToolchainLocator(processRunning: runner, fileSystem: fileSystem)
    let sourceKitDLocator = LiveSourceKitDLocator(processRunning: runner, fileSystem: fileSystem)

    let failures = PrerequisiteChecking.check(container: .xcodeproj(URL(fileURLWithPath: "/P.xcodeproj")), processRunning: runner, toolchainLocator: toolchainLocator, sourceKitDLocator: sourceKitDLocator)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("sudo xcode-select -s") == true)
    // The real underlying message stays present too -- the hint augments it, never replaces it.
    #expect(failures.first?.contains("command line tools instance") == true)
}

@Test("A genuinely missing swift (SPM container) gets the swift.org install hint")
func missingSwiftForSPMContainerGetsTheInstallHint() {
    let (runner, fileSystem) = makeHealthyDoubles()
    runner.stub(executable: "swift", arguments: ["--version"], result: ProcessResult(exitCode: 127, standardOutput: "", standardError: "env: swift: No such file or directory\n"))

    let toolchainLocator = LiveToolchainLocator(processRunning: runner, fileSystem: fileSystem)
    let sourceKitDLocator = LiveSourceKitDLocator(processRunning: runner, fileSystem: fileSystem)

    let failures = PrerequisiteChecking.check(container: .swiftPackage(URL(fileURLWithPath: "/P/Package.swift")), processRunning: runner, toolchainLocator: toolchainLocator, sourceKitDLocator: sourceKitDLocator)
    #expect(failures.count == 1)
    #expect(failures.first?.contains("swift.org") == true)
}

@Test("Multiple independent failures are all collected, not just the first")
func multipleFailuresAreAllCollected() {
    let runner = FakeProcessRunner()
    runner.stub(executable: "xcrun", arguments: ["--find", "swift"], result: ProcessResult(exitCode: 0, standardOutput: realSwiftPath + "\n", standardError: ""))
    runner.stub(executable: "xcodebuild", arguments: ["-version"], result: ProcessResult(exitCode: 127, standardOutput: "", standardError: "env: xcodebuild: No such file or directory\n"))
    let fileSystem = FakeFileSystem() // neither dylib exists

    let toolchainLocator = LiveToolchainLocator(processRunning: runner, fileSystem: fileSystem)
    let sourceKitDLocator = LiveSourceKitDLocator(processRunning: runner, fileSystem: fileSystem)

    let failures = PrerequisiteChecking.check(container: .xcodeproj(URL(fileURLWithPath: "/P.xcodeproj")), processRunning: runner, toolchainLocator: toolchainLocator, sourceKitDLocator: sourceKitDLocator)
    // libIndexStore missing + sourcekitdInProc missing + xcodebuild missing = 3 independent, distinct failures.
    #expect(failures.count == 3)
}
