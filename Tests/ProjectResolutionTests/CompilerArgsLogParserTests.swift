import Foundation
import Testing
@testable import ProjectResolution

/// Real line captured from `swift build -v` against this project's own repo (Xcode 26.4.0 / Swift
/// 6.3, arm64 macOS), for `Sources/IsolationCore/CallGraphEdge.swift` -- not hand-assembled, so the
/// parser is proven against the actual shape SwiftPM emits, not a guess at it (per this project's
/// standing "empirical, not assumed" discipline -- see docs/priority-2-phase-0-spike.md's own
/// framing of the same principle for a different subprocess).
private let realIsolationCorePrimaryFileLine = """
/Applications/Xcode-26.4.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c -primary-file /Users/ab/swift-isolation-map/Sources/IsolationCore/CallGraphEdge.swift /Users/ab/swift-isolation-map/Sources/IsolationCore/DeclarationInfo.swift /Users/ab/swift-isolation-map/Sources/IsolationCore/IsolationAttribute.swift -emit-dependencies-path /Users/ab/swift-isolation-map/.build/arm64-apple-macosx/debug/IsolationCore.build/CallGraphEdge.d -target arm64-apple-macosx13.0 -sdk /Applications/Xcode-26.4.0.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.4.sdk -I /Users/ab/swift-isolation-map/.build/arm64-apple-macosx/debug/Modules -swift-version 6 -module-name IsolationCore -o /Users/ab/swift-isolation-map/.build/arm64-apple-macosx/debug/IsolationCore.build/CallGraphEdge.swift.o
"""

@Test
func parsesRealPrimaryFileLineIntoFullArgumentList() throws {
    let result = CompilerArgsLogParser.parse(buildLog: realIsolationCorePrimaryFileLine)
    let key = "/Users/ab/swift-isolation-map/Sources/IsolationCore/CallGraphEdge.swift"
    let args = try #require(result[key])
    #expect(args.contains("-target"))
    #expect(args.contains("arm64-apple-macosx13.0"))
    #expect(args.contains("-sdk"))
    #expect(args.contains("-module-name"))
    #expect(args.contains("IsolationCore"))
    // The primary file's own path, plus every sibling source file in the same module, must both
    // be present -- cross-file symbol resolution within the module depends on the sibling list.
    #expect(args.contains(key))
    #expect(args.contains("/Users/ab/swift-isolation-map/Sources/IsolationCore/DeclarationInfo.swift"))
}

@Test
func doesNotMapSiblingFilesToTheWrongPrimaryFilesLine() {
    let result = CompilerArgsLogParser.parse(buildLog: realIsolationCorePrimaryFileLine)
    // DeclarationInfo.swift is a *sibling* on this line, not its own primary-file -- it must not
    // get an entry from this single line (it earns one only from its own -primary-file line,
    // which real multi-file builds emit separately, one per source file).
    #expect(result["/Users/ab/swift-isolation-map/Sources/IsolationCore/DeclarationInfo.swift"] == nil)
}

/// Real bug found this session: a lower-core-count CI runner's Swift driver batched three fixture
/// files into one `swift-frontend` invocation, each marked with its own `-primary-file` flag --
/// `CompilerArgsLogParser.parse` only ever recorded the *first* one, silently dropping the other
/// two (`argumentsNotFound` for genuinely-compiled files, only on that weaker-core machine; an
/// 8-core dev machine's driver never batched more than one file per line, so this was invisible
/// locally). Shape (multiple `-primary-file <file>` flags in one line, non-primary siblings
/// interspersed with no flag) confirmed against real Swift driver batch-mode output.
@Test
func handlesBatchModeLinesWithMultiplePrimaryFilesOnOneLine() throws {
    let batchLine = """
    /usr/bin/swift-frontend -frontend -c -primary-file /project/Sources/A.swift /project/Sources/B.swift -primary-file /project/Sources/C.swift -target arm64-apple-macosx13.0 -module-name Demo -o /tmp/A.o -o /tmp/C.o
    """
    let result = CompilerArgsLogParser.parse(buildLog: batchLine)
    let argsA = try #require(result["/project/Sources/A.swift"])
    let argsC = try #require(result["/project/Sources/C.swift"])
    #expect(argsA == argsC)
    #expect(argsA.contains("/project/Sources/B.swift"))
    // B.swift is a non-primary sibling on this line, same as the single-primary case above -- it
    // must not get its own entry just for appearing as a plain positional argument.
    #expect(result["/project/Sources/B.swift"] == nil)
}

@Test
func handlesWholeModuleOptimizationLinesWithNoPrimaryFile() throws {
    let wmoLine = """
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend -frontend -c /project/Sources/A.swift /project/Sources/B.swift -wmo -target arm64-apple-macosx13.0 -module-name Demo -o /tmp/out.o
    """
    let result = CompilerArgsLogParser.parse(buildLog: wmoLine)
    let argsA = try #require(result["/project/Sources/A.swift"])
    let argsB = try #require(result["/project/Sources/B.swift"])
    #expect(argsA == argsB)
    #expect(argsA.contains("-wmo"))
}

@Test
func tokenizeHonorsSingleQuotedArgumentsContainingSpacesAndHashes() {
    // Real gotcha found against this project's own plugin build lines: `#`-joined values are
    // single-quoted by `-v`'s own output, and a naive whitespace split would break them in two.
    let line = "/usr/bin/swift-frontend -external-plugin-path '/A path/plugins#/A path/swift-plugin-server' -frontend"
    let tokens = CompilerArgsLogParser.tokenize(line)
    #expect(tokens == [
        "/usr/bin/swift-frontend",
        "-external-plugin-path",
        "/A path/plugins#/A path/swift-plugin-server",
        "-frontend"
    ])
}

@Test
func ignoresNonFrontendLines() {
    let log = """
    Building for debugging...
    [1/2] Write sources
    Build complete! (1.23s)
    """
    #expect(CompilerArgsLogParser.parse(buildLog: log).isEmpty)
}

@Test
func fileAbsentFromTheLogProducesNoEntry() {
    let result = CompilerArgsLogParser.parse(buildLog: realIsolationCorePrimaryFileLine)
    #expect(result["/never/compiled/File.swift"] == nil)
}
