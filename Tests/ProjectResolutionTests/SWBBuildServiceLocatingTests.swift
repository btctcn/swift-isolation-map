import Foundation
import Testing
@testable import ProjectResolution

@Test("The bundle is found relative to a real xcode-select -p output")
func bundleIsFoundRelativeToXcodeSelectOutput() throws {
    let processRunning = FakeProcessRunner()
    processRunning.stub(
        executable: "xcode-select", arguments: ["-p"],
        result: ProcessResult(exitCode: 0, standardOutput: "/Applications/Xcode-26.4.0.app/Contents/Developer\n", standardError: "")
    )
    let fileSystem = FakeFileSystem()
    let bundleURL = URL(fileURLWithPath: "/Applications/Xcode-26.4.0.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle")
    fileSystem.addDirectory(at: bundleURL)

    let locator = LiveSWBBuildServiceLocator(processRunning: processRunning, fileSystem: fileSystem)
    let result = try locator.serviceBundleURL()

    #expect(result == bundleURL)
}

@Test("A different active Xcode's bundle is found too, not just one hardcoded install")
func bundleIsFoundForADifferentActiveXcode() throws {
    let processRunning = FakeProcessRunner()
    processRunning.stub(
        executable: "xcode-select", arguments: ["-p"],
        result: ProcessResult(exitCode: 0, standardOutput: "/Applications/Xcode-27.0.0-Beta.5.app/Contents/Developer", standardError: "")
    )
    let fileSystem = FakeFileSystem()
    let bundleURL = URL(fileURLWithPath: "/Applications/Xcode-27.0.0-Beta.5.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle")
    fileSystem.addDirectory(at: bundleURL)

    let locator = LiveSWBBuildServiceLocator(processRunning: processRunning, fileSystem: fileSystem)
    let result = try locator.serviceBundleURL()

    #expect(result == bundleURL)
}

@Test("A non-zero xcode-select exit code throws xcodeSelectFailed, not a path built from garbage output")
func xcodeSelectFailureThrows() {
    let processRunning = FakeProcessRunner()
    processRunning.stub(
        executable: "xcode-select", arguments: ["-p"],
        result: ProcessResult(exitCode: 2, standardOutput: "", standardError: "xcode-select: error: unable to get active developer directory")
    )
    let locator = LiveSWBBuildServiceLocator(processRunning: processRunning, fileSystem: FakeFileSystem())

    #expect(throws: SWBBuildServiceLocatingError.xcodeSelectFailed(
        exitCode: 2, standardError: "xcode-select: error: unable to get active developer directory"
    )) {
        try locator.serviceBundleURL()
    }
}

@Test("A missing bundle (an Xcode install without SwiftBuild.framework) throws bundleNotFound, not a false positive")
func missingBundleThrowsBundleNotFound() {
    let processRunning = FakeProcessRunner()
    processRunning.stub(
        executable: "xcode-select", arguments: ["-p"],
        result: ProcessResult(exitCode: 0, standardOutput: "/Applications/Xcode-old.app/Contents/Developer", standardError: "")
    )
    let locator = LiveSWBBuildServiceLocator(processRunning: processRunning, fileSystem: FakeFileSystem())

    #expect(throws: SWBBuildServiceLocatingError.bundleNotFound(
        "/Applications/Xcode-old.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle"
    )) {
        try locator.serviceBundleURL()
    }
}

@Test("A real file at the bundle path (not a directory) is treated as not found -- .bundle is a directory")
func aPlainFileAtTheBundlePathIsNotFound() {
    let processRunning = FakeProcessRunner()
    processRunning.stub(
        executable: "xcode-select", arguments: ["-p"],
        result: ProcessResult(exitCode: 0, standardOutput: "/Applications/Xcode-26.4.0.app/Contents/Developer", standardError: "")
    )
    let fileSystem = FakeFileSystem()
    // Registered as a *file*, not a directory -- `fileExists(at:)` would wrongly say "found" here
    // if the locator used it instead of `directoryExists(at:)`, since a real `.bundle` is a
    // directory on disk.
    fileSystem.addFile(
        at: URL(fileURLWithPath: "/Applications/Xcode-26.4.0.app/Contents/SharedFrameworks/SwiftBuild.framework/Versions/A/PlugIns/SWBBuildService.bundle"),
        contents: Data()
    )
    let locator = LiveSWBBuildServiceLocator(processRunning: processRunning, fileSystem: fileSystem)

    #expect(throws: SWBBuildServiceLocatingError.self) {
        try locator.serviceBundleURL()
    }
}
