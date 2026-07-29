import Foundation
import Testing
@testable import ProjectResolution

/// Real line captured from `xcodebuild -verbose ... build` against a real, independent Xcode
/// project (`~/SQLumen`, Xcode 26.4.0 / Swift 6.3) -- not hand-authored, per
/// docs/priority-3-phase-a-compiler-args.md's decision record: Xcode's new build system logs one
/// driver-level `swiftc` invocation per target, source file list behind an `@`-referenced
/// response file, not one line per source file the way SwiftPM's `-v` output does. Real gotcha
/// captured verbatim too: `=` is backslash-escaped even outside quotes
/// (`-default-isolation\=MainActor`, `-fmodule-map-file\=...`).
private let realSQLumenCompileLine = """
    builtin-Swift-Compilation -- /Applications/Xcode-26.4.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -module-name SQLumen -Onone @/Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Intermediates.noindex/SQLumen.build/Debug/SQLumen.build/Objects-normal/arm64/SQLumen.SwiftFileList -DDEBUG -Xcc -fmodule-map-file\\=/Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Intermediates.noindex/GeneratedModuleMaps/TreeSitterSQL.modulemap -default-isolation\\=MainActor -enable-bare-slash-regex -sdk /Applications/Xcode-26.4.0.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.4.sdk -target arm64-apple-macos26.4 -swift-version 5 -I /Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Products/Debug -c -j8 -enable-batch-mode -incremental -working-directory /Users/dev/SQLumen -experimental-emit-module-separately -disable-cmo
    ExecuteExternalTool /Applications/Xcode-26.4.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc --version
    builtin-Swift-Compilation-Requirements -- /Applications/Xcode-26.4.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc -module-name SQLumen -Onone -DDEBUG -incremental
    """

private let sampleFileListContents = """
/Users/dev/SQLumen/SQLumen/App/ContentView.swift
/Users/dev/SQLumen/SQLumen/Core/DDLService.swift
"""

/// Real line shape captured this session from a real `SwiftFileList` produced by a real Xcode
/// build against a project with a genuinely space-containing directory name
/// (`UI/News List/NewsController.swift`) -- confirmed via real-world validation that a plain
/// per-line split alone (no unescaping) leaves the literal backslash in the resulting path,
/// which then never matches the real filesystem entry: every single live `cursorinfo` query
/// against that project separately failed to `stat` ~130 sibling files each time as a direct
/// result, not merely cosmetic stderr noise as first assumed.
private let sampleFileListContentsWithEscapedSpace = "/Users/dev/Project/UI/News\\ List/NewsController.swift\n"

@Test("unescaped(_:) drops a backslash escape character, keeping whatever it precedes literally")
func unescapedDropsBackslashKeepsEscapedCharacter() {
    #expect(LiveXcodeCompilerArgumentsProvider.unescaped("News\\ List") == "News List")
    #expect(LiveXcodeCompilerArgumentsProvider.unescaped("NoEscapesHere") == "NoEscapesHere")
    #expect(LiveXcodeCompilerArgumentsProvider.unescaped("a\\=b") == "a=b")
}

@Test("liveXcodeProvider unescapes a backslash-escaped space in a real SwiftFileList entry before returning it as a file path")
func liveXcodeProviderUnescapesSpaceInFileListPath() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    let fileListURL = URL(fileURLWithPath: "/DerivedData/SQLumen.SwiftFileList")
    fileSystem.addFile(at: fileListURL, contents: sampleFileListContentsWithEscapedSpace)
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "build"],
        result: ProcessResult(
            exitCode: 0,
            standardOutput: realSQLumenCompileLine.replacingOccurrences(
                of: "/Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Intermediates.noindex/SQLumen.build/Debug/SQLumen.build/Objects-normal/arm64/SQLumen.SwiftFileList",
                with: "/DerivedData/SQLumen.SwiftFileList"
            ),
            standardError: ""
        )
    )
    let provider = LiveXcodeCompilerArgumentsProvider(
        container: .xcodeproj(URL(fileURLWithPath: "/SQLumen/SQLumen.xcodeproj")),
        scheme: "SQLumen",
        processRunning: runner,
        fileSystem: fileSystem
    )

    // The real, unescaped path (a genuine space, no backslash) must be the lookup key -- if
    // unescaping didn't happen, this would throw `argumentsNotFound` instead.
    let args = try provider.compilerArguments(forFile: "/Users/dev/Project/UI/News List/NewsController.swift")
    #expect(args.contains("/Users/dev/Project/UI/News List/NewsController.swift"))
    #expect(!args.contains(where: { $0.contains("\\") }))
}

@Test
func parsesRealXcodeCompileLineExtractingFlagsAndFileListPathSeparately() throws {
    let invocations = CompilerArgsLogParser.parseXcodeSwiftCompileInvocations(buildLog: realSQLumenCompileLine)
    let invocation = try #require(invocations.first)
    #expect(invocations.count == 1)
    #expect(invocation.sourceFileListPath == "/Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Intermediates.noindex/SQLumen.build/Debug/SQLumen.build/Objects-normal/arm64/SQLumen.SwiftFileList")
    #expect(invocation.arguments.contains("-target"))
    #expect(invocation.arguments.contains("arm64-apple-macos26.4"))
    #expect(invocation.arguments.contains("-swift-version"))
    // The escaped `=` must come through unescaped, not as a literal backslash.
    #expect(invocation.arguments.contains("-default-isolation=MainActor"))
    #expect(invocation.arguments.contains("-fmodule-map-file=/Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Intermediates.noindex/GeneratedModuleMaps/TreeSitterSQL.modulemap"))
    // The `@filelist` token itself must not leak into the flag list.
    #expect(!invocation.arguments.contains(where: { $0.hasPrefix("@") }))
}

@Test
func doesNotMatchTheRequirementsOrVersionCheckLines() {
    let invocations = CompilerArgsLogParser.parseXcodeSwiftCompileInvocations(buildLog: realSQLumenCompileLine)
    // Only the one real `-c`/`-incremental` compile line counts -- not the `-Requirements` line
    // (dependency scanning only) or the bare `--version` sanity check, both present in every real
    // build log alongside the real compile line.
    #expect(invocations.count == 1)
}

@Test
func liveXcodeProviderExpandsFileListAndMapsEveryFileToTheSameArguments() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    let fileListURL = URL(fileURLWithPath: "/DerivedData/SQLumen.SwiftFileList")
    fileSystem.addFile(at: fileListURL, contents: sampleFileListContents)
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "build"],
        result: ProcessResult(
            exitCode: 0,
            standardOutput: realSQLumenCompileLine.replacingOccurrences(
                of: "/Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Intermediates.noindex/SQLumen.build/Debug/SQLumen.build/Objects-normal/arm64/SQLumen.SwiftFileList",
                with: "/DerivedData/SQLumen.SwiftFileList"
            ),
            standardError: ""
        )
    )

    let provider = LiveXcodeCompilerArgumentsProvider(
        container: .xcodeproj(URL(fileURLWithPath: "/SQLumen/SQLumen.xcodeproj")),
        scheme: "SQLumen",
        processRunning: runner,
        fileSystem: fileSystem
    )

    let argsA = try provider.compilerArguments(forFile: "/Users/dev/SQLumen/SQLumen/App/ContentView.swift")
    let argsB = try provider.compilerArguments(forFile: "/Users/dev/SQLumen/SQLumen/Core/DDLService.swift")
    #expect(argsA == argsB)
    #expect(argsA.contains("-target"))
    // The expanded file list itself must be present as trailing positional arguments, matching
    // SwiftPM's shape (every sibling file present, for cross-file symbol resolution).
    #expect(argsA.contains("/Users/dev/SQLumen/SQLumen/App/ContentView.swift"))
    #expect(argsA.contains("/Users/dev/SQLumen/SQLumen/Core/DDLService.swift"))
}

@Test("An already-up-to-date target (zero compile invocations from a plain verbose build) retries once with `clean build`, and succeeds from that retry's real output")
func liveXcodeProviderFallsBackToCleanBuildWhenTheFirstAttemptYieldsNoInvocations() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    let fileListURL = URL(fileURLWithPath: "/DerivedData/SQLumen.SwiftFileList")
    fileSystem.addFile(at: fileListURL, contents: sampleFileListContents)

    // Confirmed empirically against a real, already-fully-built `Project Iris` (docs/priority-3-compiled-
    // dependency-isolation.md): Xcode's incremental build system prints zero
    // `builtin-Swift-Compilation --` lines when nothing needs rebuilding -- `exitCode == 0`, just an
    // empty/irrelevant log, not a failure.
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "build"],
        result: ProcessResult(exitCode: 0, standardOutput: "** BUILD SUCCEEDED **\n", standardError: "")
    )
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "clean", "build"],
        result: ProcessResult(
            exitCode: 0,
            standardOutput: realSQLumenCompileLine.replacingOccurrences(
                of: "/Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Intermediates.noindex/SQLumen.build/Debug/SQLumen.build/Objects-normal/arm64/SQLumen.SwiftFileList",
                with: "/DerivedData/SQLumen.SwiftFileList"
            ),
            standardError: ""
        )
    )

    let provider = LiveXcodeCompilerArgumentsProvider(
        container: .xcodeproj(URL(fileURLWithPath: "/SQLumen/SQLumen.xcodeproj")),
        scheme: "SQLumen",
        processRunning: runner,
        fileSystem: fileSystem
    )

    let args = try provider.compilerArguments(forFile: "/Users/dev/SQLumen/SQLumen/App/ContentView.swift")
    #expect(args.contains("-target"))
    #expect(runner.invocations.count == 2)
}

@Test("A non-zero xcodebuild exit code doesn't discard compiler invocations already parsed for targets that DID compile -- only a genuinely empty result is a hard failure")
func liveXcodeProviderUsesPartialResultsWhenBuildFailsButSomeInvocationsWereParsed() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    let fileListURL = URL(fileURLWithPath: "/DerivedData/SQLumen.SwiftFileList")
    fileSystem.addFile(at: fileListURL, contents: sampleFileListContents)

    // Real shape: the main target's own compile line appears in the verbose log (and parses
    // fine), but the overall `xcodebuild` invocation still exits non-zero because a completely
    // unrelated target failed later in the build (confirmed against a real `Project Iris` build with two
    // broken notification-extension targets sharing no dependency with the main app).
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "build"],
        result: ProcessResult(
            exitCode: 1,
            standardOutput: realSQLumenCompileLine.replacingOccurrences(
                of: "/Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Intermediates.noindex/SQLumen.build/Debug/SQLumen.build/Objects-normal/arm64/SQLumen.SwiftFileList",
                with: "/DerivedData/SQLumen.SwiftFileList"
            ),
            standardError: "** BUILD FAILED ** (unrelated target)"
        )
    )

    let provider = LiveXcodeCompilerArgumentsProvider(
        container: .xcodeproj(URL(fileURLWithPath: "/SQLumen/SQLumen.xcodeproj")),
        scheme: "SQLumen",
        processRunning: runner,
        fileSystem: fileSystem
    )

    // Must not throw, and must not re-invoke xcodebuild a second time (no retry needed -- real,
    // non-empty data was already recovered).
    let args = try provider.compilerArguments(forFile: "/Users/dev/SQLumen/SQLumen/App/ContentView.swift")
    #expect(args.contains("-target"))
    #expect(runner.invocations.count == 1)
}

@Test("A non-zero xcodebuild exit code with nothing at all parseable is still a hard failure")
func liveXcodeProviderThrowsWhenBuildFailsAndNothingWasParsed() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "build"],
        result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "** BUILD FAILED ** (nothing compiled at all)")
    )
    // The "empty means up-to-date, retry with clean" fallback also gets a chance, and also fails
    // to produce anything usable.
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "clean", "build"],
        result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "** BUILD FAILED ** (nothing compiled at all)")
    )

    let provider = LiveXcodeCompilerArgumentsProvider(
        container: .xcodeproj(URL(fileURLWithPath: "/SQLumen/SQLumen.xcodeproj")),
        scheme: "SQLumen",
        processRunning: runner,
        fileSystem: fileSystem
    )

    #expect(throws: CompilerArgumentsError.self) {
        try provider.compilerArguments(forFile: "/Users/dev/SQLumen/SQLumen/App/ContentView.swift")
    }
}

@Test
func liveXcodeProviderThrowsForAFileNotInAnyTargetsFileList() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    let fileListURL = URL(fileURLWithPath: "/DerivedData/SQLumen.SwiftFileList")
    fileSystem.addFile(at: fileListURL, contents: sampleFileListContents)
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "build"],
        result: ProcessResult(
            exitCode: 0,
            standardOutput: realSQLumenCompileLine.replacingOccurrences(
                of: "/Users/dev/Library/Developer/Xcode/DerivedData/SQLumen-axiwtafjwewywncnfqkujtirqdpd/Build/Intermediates.noindex/SQLumen.build/Debug/SQLumen.build/Objects-normal/arm64/SQLumen.SwiftFileList",
                with: "/DerivedData/SQLumen.SwiftFileList"
            ),
            standardError: ""
        )
    )
    let provider = LiveXcodeCompilerArgumentsProvider(
        container: .xcodeproj(URL(fileURLWithPath: "/SQLumen/SQLumen.xcodeproj")),
        scheme: "SQLumen",
        processRunning: runner,
        fileSystem: fileSystem
    )
    #expect(throws: CompilerArgumentsError.argumentsNotFound(file: "/never/seen/File.swift")) {
        try provider.compilerArguments(forFile: "/never/seen/File.swift")
    }
}
