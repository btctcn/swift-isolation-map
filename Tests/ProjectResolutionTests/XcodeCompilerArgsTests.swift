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

// Padded to clear `LiveXcodeCompilerArgumentsProvider.minimumUsableFileCount` (10) -- otherwise
// every test below using this fixture would trip the same low-file-count clean-rebuild retry the
// real `docs/task-sourcekitd-cooperative-pool-starvation.md` bug fix added, which none of these
// tests stub for (they're testing unrelated behavior). The padding files are never referenced by
// name in any assertion; the two originally-named files stay first for readability.
private let sampleFileListContents = """
/Users/dev/SQLumen/SQLumen/App/ContentView.swift
/Users/dev/SQLumen/SQLumen/Core/DDLService.swift
/Users/dev/SQLumen/SQLumen/Core/Padding1.swift
/Users/dev/SQLumen/SQLumen/Core/Padding2.swift
/Users/dev/SQLumen/SQLumen/Core/Padding3.swift
/Users/dev/SQLumen/SQLumen/Core/Padding4.swift
/Users/dev/SQLumen/SQLumen/Core/Padding5.swift
/Users/dev/SQLumen/SQLumen/Core/Padding6.swift
/Users/dev/SQLumen/SQLumen/Core/Padding7.swift
/Users/dev/SQLumen/SQLumen/Core/Padding8.swift
"""

/// Real line shape captured this session from a real `SwiftFileList` produced by a real Xcode
/// build against a project with a genuinely space-containing directory name
/// (`UI/News List/NewsController.swift`) -- confirmed via real-world validation that a plain
/// per-line split alone (no unescaping) leaves the literal backslash in the resulting path,
/// which then never matches the real filesystem entry: every single live `cursorinfo` query
/// against that project separately failed to `stat` ~130 sibling files each time as a direct
/// result, not merely cosmetic stderr noise as first assumed. Padded with plain (non-escaped)
/// entries for the same `minimumUsableFileCount` reason as `sampleFileListContents` above.
private let sampleFileListContentsWithEscapedSpace = """
/Users/dev/Project/UI/News\\ List/NewsController.swift
/Users/dev/Project/UI/Padding1.swift
/Users/dev/Project/UI/Padding2.swift
/Users/dev/Project/UI/Padding3.swift
/Users/dev/Project/UI/Padding4.swift
/Users/dev/Project/UI/Padding5.swift
/Users/dev/Project/UI/Padding6.swift
/Users/dev/Project/UI/Padding7.swift
/Users/dev/Project/UI/Padding8.swift
/Users/dev/Project/UI/Padding9.swift
"""

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
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
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
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
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

@Test("realModuleNames() extracts the real -module-name value from this run's own build, for RawIndexStoreClient's allowedModuleNames filter (docs/task-index-store-module-scoping.md)")
func realModuleNamesExtractsModuleNameFromRealBuildLine() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    let fileListURL = URL(fileURLWithPath: "/DerivedData/SQLumen.SwiftFileList")
    fileSystem.addFile(at: fileListURL, contents: sampleFileListContents)
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
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

    #expect(provider.realModuleNames() == ["SQLumen"])
}

@Test("realModuleNames() returns nil when the build failed outright and nothing was parsed -- never a guess, matching compilerArguments(forFile:)'s own failure mode")
func realModuleNamesReturnsNilWhenBuildFailedOutright() {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
        result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "** BUILD FAILED ** (nothing compiled at all)")
    )
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "clean", "build"],
        result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "** BUILD FAILED ** (nothing compiled at all)")
    )
    let provider = LiveXcodeCompilerArgumentsProvider(
        container: .xcodeproj(URL(fileURLWithPath: "/SQLumen/SQLumen.xcodeproj")),
        scheme: "SQLumen",
        processRunning: runner,
        fileSystem: fileSystem
    )

    #expect(provider.realModuleNames() == nil)
}

@Test("skipMacroValidation: true passes -skipMacroValidation to the internal xcodebuild invocation; false (the default) never does")
func skipMacroValidationFlagIsPassedOnlyWhenRequested() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    let fileListURL = URL(fileURLWithPath: "/DerivedData/SQLumen.SwiftFileList")
    fileSystem.addFile(at: fileListURL, contents: sampleFileListContents)
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-skipMacroValidation", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
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
        fileSystem: fileSystem,
        skipMacroValidation: true
    )

    // Real shape confirmed against an independent project using SPM macro plugins (`Swiftfin`,
    // `swift-case-paths`/`StatefulMacros`): without `-skipMacroValidation`, every internal
    // `xcodebuild` invocation this provider makes fails outright with "Macro ... must be enabled
    // before it can be used" -- if the flag weren't included here, `FakeProcessRunner` would throw
    // "No stubbed response" instead of returning the stubbed result below.
    let args = try provider.compilerArguments(forFile: "/Users/dev/SQLumen/SQLumen/App/ContentView.swift")
    #expect(args.contains("-target"))
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
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
        result: ProcessResult(exitCode: 0, standardOutput: "** BUILD SUCCEEDED **\n", standardError: "")
    )
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "clean", "build"],
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
    // 1 `-showdestinations` probe (unstubbed here, so it fails and is swallowed -- no destination
    // override applies) + 2 build attempts (plain, then `clean`).
    #expect(runner.invocations.count == 3)
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
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
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
    // 1 `-showdestinations` probe (unstubbed, swallowed) + 1 build attempt.
    #expect(runner.invocations.count == 2)
}

@Test("A non-zero xcodebuild exit code with nothing at all parseable is still a hard failure")
func liveXcodeProviderThrowsWhenBuildFailsAndNothingWasParsed() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
        result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "** BUILD FAILED ** (nothing compiled at all)")
    )
    // The "empty means up-to-date, retry with clean" fallback also gets a chance, and also fails
    // to produce anything usable.
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "clean", "build"],
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

@Test("A build failure is memoized like a success -- a second lookup after the first throw does not re-invoke xcodebuild")
func liveXcodeProviderCachesAFailureAndDoesNotRetryOnASubsequentLookup() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    // A build that fails outright (non-zero exit, nothing parseable) throws straight out of the
    // *first* `runVerboseBuild(extraActions: [])` call -- the `clean` retry is reached only when
    // the first attempt returns an empty-but-successful result, never when it throws -- so exactly
    // one `xcodebuild` invocation happens per call to `compilerArguments(forFile:)` here.
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
        result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "** BUILD FAILED ** (nothing compiled at all)")
    )

    let provider = LiveXcodeCompilerArgumentsProvider(
        container: .xcodeproj(URL(fileURLWithPath: "/SQLumen/SQLumen.xcodeproj")),
        scheme: "SQLumen",
        processRunning: runner,
        fileSystem: fileSystem
    )

    // Real shape: `detectConfiguredDefaultIsolation` walks every source file in a loop, calling
    // `compilerArguments(forFile:)` again for each one via `try?` after the previous file's
    // lookup threw -- confirmed as a real, reproduced problem against a genuinely unbuildable
    // real project (424 source files, dozens of independent `xcodebuild` invocations fired every
    // few seconds) before this caching fix: without it, every one of those files would repeat the
    // full, expensive `xcodebuild` invocation from scratch.
    #expect(throws: CompilerArgumentsError.self) {
        try provider.compilerArguments(forFile: "/Users/dev/SQLumen/SQLumen/App/ContentView.swift")
    }
    #expect(throws: CompilerArgumentsError.self) {
        try provider.compilerArguments(forFile: "/Users/dev/SQLumen/SQLumen/Core/DDLService.swift")
    }
    // Only the first call's invocations ever happened -- the second call's failure came straight
    // from the cache (a second, unstubbed invocation would have thrown a *different*, "no stubbed
    // response" error instead). 1 `-showdestinations` probe (unstubbed, swallowed) + 1 build
    // attempt, and both are cached just like `cachedArguments`/`cachedError` -- neither repeats on
    // the second `compilerArguments(forFile:)` call.
    #expect(runner.invocations.count == 2)
}

@Test
func liveXcodeProviderThrowsForAFileNotInAnyTargetsFileList() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    let fileListURL = URL(fileURLWithPath: "/DerivedData/SQLumen.SwiftFileList")
    fileSystem.addFile(at: fileListURL, contents: sampleFileListContents)
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj", "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
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

/// Real `-showdestinations` output shape captured against `Swiftfin` -- a physical device paired
/// to the host machine in the past but not currently connected sorts *ahead of* every Simulator
/// destination. Real root cause of the regression this guards against: with no `-destination`
/// passed, `xcodebuild` silently picked that unconnected device and built for `Debug-iphoneos`
/// instead of `Debug-iphonesimulator`, compiling successfully but producing compiler arguments
/// sourcekitd could not construct a working `ASTInvocation` from -- collapsing live-fallback
/// resolution from ~1300 real declarations to zero.
private let realSwiftfinShowDestinationsOutput = """
	Available destinations for the "Swiftfin" scheme:
		{ platform:iOS, id:6268785b905ba913ec773f578958320875aad293, name:ab iphone x, error:ab iphone x is not connected Xcode will continue when ab iphone x is connected and unlocked. }
		{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
		{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
		{ platform:iOS Simulator, arch:arm64, id:8BC60344-4CDF-44A1-814D-68EFF6BED4A4, OS:26.4, name:iPhone 17 Pro }
	"""

@Test("resolveDeterministicSimulatorDestination picks the first Simulator platform, ignoring an unconnected physical device sorted ahead of it (Swiftfin shape)")
func resolveDeterministicSimulatorDestinationPicksSimulatorOverAnUnconnectedDevice() {
    let runner = FakeProcessRunner()
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-showdestinations", "-scheme", "Swiftfin", "-project", "/Swiftfin/Swiftfin.xcodeproj"],
        result: ProcessResult(exitCode: 0, standardOutput: realSwiftfinShowDestinationsOutput, standardError: "")
    )
    let destination = resolveDeterministicSimulatorDestination(
        container: .xcodeproj(URL(fileURLWithPath: "/Swiftfin/Swiftfin.xcodeproj")), scheme: "Swiftfin", processRunning: runner
    )
    #expect(destination == "generic/platform=iOS Simulator")
}

@Test("resolveDeterministicSimulatorDestination returns nil for a scheme with no Simulator-capable platform at all (a pure macOS/host scheme)")
func resolveDeterministicSimulatorDestinationReturnsNilWhenNoSimulatorPlatformExists() {
    let runner = FakeProcessRunner()
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-showdestinations", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj"],
        result: ProcessResult(
            exitCode: 0,
            standardOutput: """
            	Available destinations for the "SQLumen" scheme:
            		{ platform:macOS, arch:arm64, id:00006020-0000000000000000, name:Any Mac }
            	""",
            standardError: ""
        )
    )
    let destination = resolveDeterministicSimulatorDestination(
        container: .xcodeproj(URL(fileURLWithPath: "/SQLumen/SQLumen.xcodeproj")), scheme: "SQLumen", processRunning: runner
    )
    #expect(destination == nil)
}

@Test("A resolved Simulator destination is threaded into the real xcodebuild -verbose build invocation, not just computed and discarded")
func liveXcodeProviderThreadsTheResolvedDestinationIntoTheBuildInvocation() throws {
    let runner = FakeProcessRunner()
    let fileSystem = FakeFileSystem()
    let fileListURL = URL(fileURLWithPath: "/DerivedData/SQLumen.SwiftFileList")
    fileSystem.addFile(at: fileListURL, contents: sampleFileListContents)
    runner.stub(
        executable: "xcodebuild",
        arguments: ["-showdestinations", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj"],
        result: ProcessResult(exitCode: 0, standardOutput: realSwiftfinShowDestinationsOutput, standardError: "")
    )
    runner.stub(
        executable: "xcodebuild",
        arguments: [
            "-verbose", "-scheme", "SQLumen", "-project", "/SQLumen/SQLumen.xcodeproj",
            "-destination", "generic/platform=iOS Simulator",
            "COMPILER_INDEX_STORE_ENABLE=YES", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build",
        ],
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

    // If `-destination` weren't threaded through, this would throw "No stubbed response" instead
    // -- the build stub above only matches with the destination argument present.
    let args = try provider.compilerArguments(forFile: "/Users/dev/SQLumen/SQLumen/App/ContentView.swift")
    #expect(args.contains("-target"))
}
