import Testing
@testable import SourceKitDIntegration

/// Real frontend-line shape captured from `swift build -v` (`ProjectResolution.CompilerArgsLogParser`'s
/// own output) -- confirmed empirically to make every `sourcekitd` cursor-info query fail with
/// `"unknown argument: '-frontend'"` and a dozen further frontend-only flags before this
/// sanitizer existed (docs/priority-3-phase-e-fixtures.md).

@Test("Strips -frontend and the -c compile-action marker")
func stripsFrontendMarkers() {
    let sanitized = CompilerArgumentsSanitizing.sanitized(["-frontend", "-c", "-sdk", "/SDK"])
    #expect(!sanitized.contains("-frontend"))
    #expect(sanitized.contains("-sdk"))
}

@Test("Drops -primary-file but keeps its value as a bare positional, alongside sibling files")
func keepsPrimaryFileValueAsPositional() {
    let sanitized = CompilerArgumentsSanitizing.sanitized([
        "-frontend", "-c", "-primary-file", "/proj/A.swift", "/proj/B.swift", "-sdk", "/SDK"
    ])
    #expect(!sanitized.contains("-primary-file"))
    #expect(sanitized.contains("/proj/A.swift"))
    #expect(sanitized.contains("/proj/B.swift"))
}

@Test("Drops every empirically-confirmed frontend-only flag, including value-taking ones and their values")
func dropsAllKnownFrontendOnlyFlags() {
    let sanitized = CompilerArgumentsSanitizing.sanitized([
        "-frontend", "-c", "-primary-file", "/proj/A.swift",
        "-emit-dependencies-path", "/out/A.d",
        "-emit-reference-dependencies-path", "/out/A.swiftdeps",
        "-enable-objc-interop",
        "-new-driver-path", "/usr/bin/swift-driver",
        "-empty-abi-descriptor",
        "-enable-anonymous-context-mangled-names",
        "-disable-clang-spi",
        "-target-sdk-version", "26.4",
        "-target-sdk-name", "macosx26.4",
        "-index-system-modules",
        "-serialize-diagnostics-path", "/out/A.dia",
        "-sdk", "/SDK",
        "-target", "arm64-apple-macosx13.0",
        "-module-name", "Demo"
    ])
    // "-c" is deliberately *not* stripped -- it's a valid flag in both the driver and frontend
    // argument grammars (compile-only, no linking), unlike the flags this sanitizer targets.
    #expect(sanitized == ["-c", "/proj/A.swift", "-sdk", "/SDK", "-target", "arm64-apple-macosx13.0", "-module-name", "Demo"])
}

@Test("Ordinary driver-safe arguments pass through unchanged")
func passesThroughSafeArguments() {
    let arguments = ["-sdk", "/SDK", "-target", "arm64-apple-macosx13.0", "-I", "/deps", "-swift-version", "6", "/proj/A.swift"]
    #expect(CompilerArgumentsSanitizing.sanitized(arguments) == arguments)
}
