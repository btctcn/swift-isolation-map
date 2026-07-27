import Foundation
import Testing
import IsolationCore
import ProjectResolution
@testable import SourceKitDIntegration

/// Fake `ProcessRunning`/`FileSystemQuerying` doubles mirroring the shape already used elsewhere
/// in this project's test suite (`ExternalIsolationBackfillTests.swift`'s own fakes) -- kept local
/// since `SourceKitDIntegrationTests` has no existing shared `TestDoubles.swift`.
private final class FakeProcessRunning: ProcessRunning, @unchecked Sendable {
    var result: ProcessResult = ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    /// `extract()` generates a fresh, randomly-named `-output-dir` on every call (not injectable
    /// ahead of time) -- this closure lets the test write its canned symbol-graph JSON to whatever
    /// real path the extractor actually asked for, discovered from the real arguments at call time.
    var onRun: ((_ arguments: [String]) -> Void)?
    private(set) var lastArguments: [String]?

    func run(executable: String, arguments: [String], workingDirectory: URL?, timeout: TimeInterval?) throws -> ProcessResult {
        lastArguments = arguments
        onRun?(arguments)
        return result
    }
}

private final class FakeFileSystemQuerying: FileSystemQuerying, @unchecked Sendable {
    var files: [String: Data] = [:]

    func fileExists(at url: URL) -> Bool { files[url.path] != nil }
    func directoryExists(at url: URL) -> Bool { true }
    func contentsOfDirectory(at url: URL) throws -> [URL] {
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return files.keys
            .filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .map { URL(fileURLWithPath: $0) }
    }
    func readData(at url: URL) throws -> Data {
        guard let data = files[url.path] else {
            throw NSError(domain: "FakeFileSystemQuerying", code: 1)
        }
        return data
    }
    func write(data: Data, to url: URL) throws { files[url.path] = data }
}

@Suite("BulkSymbolGraphExtractor")
struct BulkSymbolGraphExtractorTests {
    @Test("extract() returns an empty dictionary, not a crash, when the process exits non-zero (module absent from this SDK)")
    func nonZeroExitYieldsEmptyDictionary() {
        let processRunning = FakeProcessRunning()
        processRunning.result = ProcessResult(exitCode: 1, standardOutput: "", standardError: "error: module 'AppKit' not found")
        let fileSystem = FakeFileSystemQuerying()

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "AppKit", sdkPath: "/fake/sdk", target: "arm64-apple-ios17.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved.isEmpty)
    }

    @Test("extract() parses declarationFragments from every symbol in the module's primary symbol-graph file, keyed by USR")
    func parsesMultipleSymbolsFromOneModuleFile() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        // The real symbol-graph shape confirmed against a live `swift symbolgraph-extract -module-name
        // AppKit` run on this machine's SDK: `NSView` genuinely carries `@MainActor`, a plain
        // no-attribute symbol is a real, positive `.nonisolated` fact (not "unknown").
        let json = """
        {"symbols":[
            {"identifier":{"precise":"c:objc(cs)NSView"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"},{"kind":"keyword","spelling":"class"}]},
            {"identifier":{"precise":"c:objc(cs)NSSomethingPlain"},"declarationFragments":[{"kind":"keyword","spelling":"class"}]}
        ]}
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            let primaryFile = outputDir.appendingPathComponent("AppKit.symbols.json")
            try? fileSystem.write(data: Data(json.utf8), to: primaryFile)
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "AppKit", sdkPath: "/fake/sdk", target: "arm64-apple-macosx13.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved["c:objc(cs)NSView"] == .globalActor(name: "MainActor"))
        #expect(resolved["c:objc(cs)NSSomethingPlain"] == .nonisolated)
    }

    @Test("extract() merges symbols from every *.symbols.json sibling file, not just the module's own primary file")
    func mergesSymbolsFromSiblingExtensionFiles() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        // Mirrors the real, empirically-verified shape: a `@MainActor` extension member Kingfisher
        // adds to a UIKit type is serialized only into `Kingfisher@UIKit.symbols.json`, never into
        // `Kingfisher.symbols.json` (which is legitimately empty for that symbol).
        let primaryJSON = #"{"symbols":[]}"#
        let extensionJSON = """
        {"symbols":[
            {"identifier":{"precise":"s:4ModA9BaseThingC0A1BE2kfSivp"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"},{"kind":"keyword","spelling":"var"}]}
        ]}
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            try? fileSystem.write(data: Data(primaryJSON.utf8), to: outputDir.appendingPathComponent("Kingfisher.symbols.json"))
            try? fileSystem.write(data: Data(extensionJSON.utf8), to: outputDir.appendingPathComponent("Kingfisher@UIKit.symbols.json"))
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "Kingfisher", sdkPath: "/fake/sdk", target: "arm64-apple-ios17.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved["s:4ModA9BaseThingC0A1BE2kfSivp"] == .globalActor(name: "MainActor"))
    }

    @Test("Live toolchain: bulk-extracting real AppKit from the macOS SDK resolves NSView to @MainActor")
    func liveExtractionResolvesRealAppKitMainActorClass() throws {
        let sdkResult = try LiveProcessRunner().run(executable: "xcrun", arguments: ["--sdk", "macosx", "--show-sdk-path"], workingDirectory: nil)
        let sdkPath = sdkResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(sdkResult.exitCode == 0)

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "AppKit", sdkPath: sdkPath, target: "arm64-apple-macosx13.0",
            processRunning: LiveProcessRunner(), fileSystem: LiveFileSystem()
        )
        // NSView is a real, stable, long-standing @MainActor AppKit type -- confirmed directly
        // against this machine's real SDK before writing this assertion (not assumed).
        #expect(resolved["c:objc(cs)NSView"] == .globalActor(name: "MainActor"))
    }
}
