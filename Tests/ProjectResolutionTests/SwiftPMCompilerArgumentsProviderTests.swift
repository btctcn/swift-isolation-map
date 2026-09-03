import Foundation
import Testing
@testable import ProjectResolution

/// 10 distinct compile lines (`LiveSwiftPMCompilerArgumentsProvider.minimumUsableFileCountFallback`'s
/// own real value, used when a caller doesn't pass `expectedFileCount`) -- a stub this small on its
/// own would otherwise trigger the retry-with-clean path (issue #142) every test below not
/// specifically testing that path, so this shared fixture keeps every other test exercising only
/// the plain, single-invocation case it means to.
private func manyFilesCompileLog(realFile: String = "/project/Sources/Demo/Widget.swift") -> String {
    var lines = (0..<9).map {
        "/usr/bin/swift-frontend -frontend -c -primary-file /project/Sources/Demo/Padding\($0).swift -target arm64-apple-macosx13.0 -sdk /SDK -module-name Demo"
    }
    lines.append("/usr/bin/swift-frontend -frontend -c -primary-file \(realFile) -target arm64-apple-macosx13.0 -sdk /SDK -module-name Demo")
    return lines.joined(separator: "\n")
}

@Test
func compilerArgumentsRunsBuildOnceAndParsesRealArgumentsForTheRequestedFile() throws {
    let runner = FakeProcessRunner()
    let packageDirectory = URL(fileURLWithPath: "/project")
    runner.stub(
        executable: "swift",
        arguments: ["build", "-v"],
        result: ProcessResult(exitCode: 0, standardOutput: manyFilesCompileLog(), standardError: "")
    )

    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: packageDirectory, processRunning: runner)
    let args = try provider.compilerArguments(forFile: "/project/Sources/Demo/Widget.swift")
    #expect(args.contains("-target"))
    #expect(args.contains("arm64-apple-macosx13.0"))

    // A second call must not shell out again -- the build log is parsed once and cached. Already
    // at/above minimumUsableFileCount, so no retry-with-clean fires either -- exactly one real
    // invocation total.
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

// MARK: - Retry-with-clean when the incremental parse looks suspiciously incomplete (issue #142)

@Test
func aSuspiciouslySmallInitialParseTriggersACleanRetryAndUsesItsResult() throws {
    let runner = FakeProcessRunner()
    let packageDirectory = URL(fileURLWithPath: "/project")
    // First (plain incremental) attempt: only 1 real compile line -- below
    // minimumUsableFileCount (10), exactly the real, reproduced shape (issue #142: an
    // already-up-to-date SwiftPM target prints no compile line at all for files it doesn't
    // recompile this run).
    var callCount = 0
    runner.onRun = { executable, arguments in
        guard executable == "swift", arguments == ["build", "-v"] else { return nil }
        callCount += 1
        if callCount == 1 {
            return ProcessResult(
                exitCode: 0,
                standardOutput: "/usr/bin/swift-frontend -frontend -c -primary-file /project/Sources/Demo/Widget.swift -target arm64-apple-macosx13.0 -sdk /SDK -module-name Demo",
                standardError: ""
            )
        }
        // Retry (post-clean): a real, complete listing.
        return ProcessResult(exitCode: 0, standardOutput: manyFilesCompileLog(), standardError: "")
    }
    runner.stub(executable: "swift", arguments: ["package", "clean"], result: ProcessResult(exitCode: 0, standardOutput: "", standardError: ""))

    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: packageDirectory, processRunning: runner)
    let args = try provider.compilerArguments(forFile: "/project/Sources/Demo/Widget.swift")
    #expect(args.contains("-target"))
    // The retry's own arguments are what actually got returned/cached -- confirmed by also
    // resolving a file only the retry's complete listing has.
    let paddingArgs = try provider.compilerArguments(forFile: "/project/Sources/Demo/Padding0.swift")
    #expect(paddingArgs.contains("-target"))
    #expect(callCount == 2, "exactly one retry, not a loop")
}

@Test
func atOrAboveMinimumUsableFileCountNeverTriggersARetry() throws {
    let runner = FakeProcessRunner()
    let packageDirectory = URL(fileURLWithPath: "/project")
    runner.stub(
        executable: "swift",
        arguments: ["build", "-v"],
        result: ProcessResult(exitCode: 0, standardOutput: manyFilesCompileLog(), standardError: "")
    )
    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: packageDirectory, processRunning: runner)
    _ = try provider.compilerArguments(forFile: "/project/Sources/Demo/Widget.swift")
    #expect(runner.invocations.contains { $0.executable == "swift" && $0.arguments == ["package", "clean"] } == false)
}

@Test
func aCleanFailureIsFailSoftAndTheRetryBuildStillRuns() throws {
    let runner = FakeProcessRunner()
    let packageDirectory = URL(fileURLWithPath: "/project")
    // "swift package clean" left entirely unstubbed -- FakeProcessRunner throws for it, exercising
    // the real fail-soft `try?` around that call.
    var callCount = 0
    runner.onRun = { executable, arguments in
        guard executable == "swift", arguments == ["build", "-v"] else { return nil }
        callCount += 1
        if callCount == 1 {
            return ProcessResult(exitCode: 0, standardOutput: "Build complete!", standardError: "")
        }
        return ProcessResult(exitCode: 0, standardOutput: manyFilesCompileLog(), standardError: "")
    }
    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: packageDirectory, processRunning: runner)
    let args = try provider.compilerArguments(forFile: "/project/Sources/Demo/Widget.swift")
    #expect(args.contains("-target"))
    #expect(callCount == 2)
}

// MARK: - retryThreshold() scales with expectedFileCount, a fixed floor alone is the wrong tool

@Test
func aGenuinelyTinyPackageWithExpectedFileCountNeverRetries() throws {
    // Exactly what Tests/Fixtures/simple-actor really is: one real file, a complete build only
    // ever produces one real compile line -- the real, reproduced regression this design fixes
    // (a fixed floor of 10 would have retried unconditionally here).
    let runner = FakeProcessRunner()
    let packageDirectory = URL(fileURLWithPath: "/project")
    runner.stub(
        executable: "swift",
        arguments: ["build", "-v"],
        result: ProcessResult(
            exitCode: 0,
            standardOutput: "/usr/bin/swift-frontend -frontend -c -primary-file /project/Sources/Demo/Widget.swift -target arm64-apple-macosx13.0 -sdk /SDK -module-name Demo",
            standardError: ""
        )
    )
    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: packageDirectory, processRunning: runner, expectedFileCount: 1)
    _ = try provider.compilerArguments(forFile: "/project/Sources/Demo/Widget.swift")
    #expect(runner.invocations.contains { $0.executable == "swift" && $0.arguments == ["package", "clean"] } == false)
}

@Test
func aLargePackageRetriesEvenWellAboveTheFixedFallbackFloor() throws {
    // The real, motivating self-analysis shape (issue #142): a 178-real-file package, an
    // incomplete incremental parse of 32 lines -- well above the fixed fallback floor (10), which
    // alone would have missed this exact corpus, but well below a real quarter of 178 (44 here).
    let runner = FakeProcessRunner()
    let packageDirectory = URL(fileURLWithPath: "/project")
    var callCount = 0
    runner.onRun = { executable, arguments in
        guard executable == "swift", arguments == ["build", "-v"] else { return nil }
        callCount += 1
        if callCount == 1 {
            let lines = (0..<32).map {
                "/usr/bin/swift-frontend -frontend -c -primary-file /project/Sources/Demo/Partial\($0).swift -target arm64-apple-macosx13.0 -sdk /SDK -module-name Demo"
            }
            return ProcessResult(exitCode: 0, standardOutput: lines.joined(separator: "\n"), standardError: "")
        }
        let lines = (0..<178).map {
            "/usr/bin/swift-frontend -frontend -c -primary-file /project/Sources/Demo/Full\($0).swift -target arm64-apple-macosx13.0 -sdk /SDK -module-name Demo"
        }
        return ProcessResult(exitCode: 0, standardOutput: lines.joined(separator: "\n"), standardError: "")
    }
    runner.stub(executable: "swift", arguments: ["package", "clean"], result: ProcessResult(exitCode: 0, standardOutput: "", standardError: ""))
    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: packageDirectory, processRunning: runner, expectedFileCount: 178)
    _ = try provider.compilerArguments(forFile: "/project/Sources/Demo/Full0.swift")
    #expect(callCount == 2, "the 32-line partial parse must trigger a retry despite being above the fixed fallback floor of 10")
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

    // This fixture has exactly one real Swift file -- `expectedFileCount: 1` matches this
    // project's own real `makeCompilerArgumentsProvider` call site (`sourceFiles.count`) and keeps
    // `retryThreshold()` from unconditionally firing an extra clean-rebuild for a genuinely tiny
    // package (issue #142's own retry-threshold fix: a fixed absolute floor alone regressed this
    // exact fixture, racing this test's own build against another concurrently-running test's
    // build of the identical shared fixture directory -- see that fix's own doc comment).
    let provider = LiveSwiftPMCompilerArgumentsProvider(packageDirectory: fixtureDirectory, expectedFileCount: 1)
    let args = try provider.compilerArguments(forFile: mainFile)
    #expect(args.contains("-target"))
    #expect(args.contains("-sdk"))
    #expect(args.contains(mainFile))
}
