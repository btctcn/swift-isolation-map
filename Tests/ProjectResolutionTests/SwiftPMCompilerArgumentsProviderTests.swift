import Foundation
import Testing
@testable import ProjectResolution

@Test
func compilerArgumentsRunsBuildOnceAndParsesRealArgumentsForTheRequestedFile() throws {
    let runner = FakeProcessRunner()
    let packageDirectory = URL(fileURLWithPath: "/project")
    let compileLine = """
    /usr/bin/swift-frontend -frontend -c -primary-file /project/Sources/Demo/Widget.swift -target arm64-apple-macosx13.0 -sdk /SDK -module-name Demo
    """
    runner.stub(
        executable: "swift",
        arguments: ["build", "-v"],
        result: ProcessResult(exitCode: 0, standardOutput: compileLine, standardError: "")
    )

    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: packageDirectory, processRunning: runner)
    let args = try provider.compilerArguments(forFile: "/project/Sources/Demo/Widget.swift")
    #expect(args.contains("-target"))
    #expect(args.contains("arm64-apple-macosx13.0"))

    // A second call must not shell out again -- the build log is parsed once and cached.
    _ = try provider.compilerArguments(forFile: "/project/Sources/Demo/Widget.swift")
    #expect(runner.invocations.count == 1)
}

@Test
func compilerArgumentsThrowsForAFileNeverSeenInTheBuildLog() throws {
    let runner = FakeProcessRunner()
    let packageDirectory = URL(fileURLWithPath: "/project")
    runner.stub(
        executable: "swift",
        arguments: ["build", "-v"],
        result: ProcessResult(exitCode: 0, standardOutput: "Build complete!", standardError: "")
    )
    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: packageDirectory, processRunning: runner)
    #expect(throws: CompilerArgumentsError.argumentsNotFound(file: "/project/Sources/Demo/Missing.swift")) {
        try provider.compilerArguments(forFile: "/project/Sources/Demo/Missing.swift")
    }
}

@Test
func compilerArgumentsThrowsWhenTheBuildItselfFails() throws {
    let runner = FakeProcessRunner()
    let packageDirectory = URL(fileURLWithPath: "/project")
    runner.stub(
        executable: "swift",
        arguments: ["build", "-v"],
        result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "error: broken package")
    )
    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: packageDirectory, processRunning: runner)
    #expect(throws: CompilerArgumentsError.self) {
        try provider.compilerArguments(forFile: "/project/Sources/Demo/Widget.swift")
    }
}

/// Live-toolchain tier, same discipline as `DeclarationLinkerTests.swift`: a real `swift build -v`
/// against a real fixture package, asserting the returned arguments are genuinely usable (contain
/// a real `-target`/`-sdk`, not just present).
@Test
func realBuildAgainstSimpleActorFixtureProducesUsableCompilerArguments() throws {
    let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("simple-actor")
    let mainFile = fixtureDirectory
        .appendingPathComponent("Sources")
        .appendingPathComponent("SimpleActorApp")
        .appendingPathComponent("main.swift")
        .resolvingSymlinksInPath()
        .path
    // Found the same way `DeclarationLinkerTests.swift` did: an incremental `swift build` sees
    // unchanged sources and skips recompilation entirely, which means `-v` emits no compile lines
    // at all on a second run against a fixture whose `.build` is already up to date -- force a
    // real rebuild every time by clearing it first.
    try? FileManager.default.removeItem(atPath: fixtureDirectory.appendingPathComponent(".build").path)

    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: fixtureDirectory)
    let args = try provider.compilerArguments(forFile: mainFile)
    #expect(args.contains("-target"))
    #expect(args.contains("-sdk"))
    #expect(args.contains(mainFile))
}
