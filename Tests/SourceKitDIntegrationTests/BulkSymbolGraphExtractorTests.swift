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
        #expect(resolved.isolationByUSR.isEmpty)
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
        #expect(resolved.isolationByUSR["c:objc(cs)NSView"] == .globalActor(name: "MainActor"))
        #expect(resolved.isolationByUSR["c:objc(cs)NSSomethingPlain"] == .nonisolated)
    }

    @Test("extract() inherits a globalActor container's isolation for a member with no attribute of its own -- real shape confirmed against UIKit's own symbolgraph-extract output for UINavigationController.pushViewController(_:animated:) (docs/task-closure-isolation-attribution.md's sibling investigation)")
    func inheritsGlobalActorContainerIsolationForUnmarkedMember() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        // `pushViewController(_:animated:)` is genuinely `@MainActor`, inherited from
        // `@MainActor class UINavigationController` -- confirmed by direct compilation and by a
        // live `cursorinfo` query at a real call site, whose own symbol-graph response *does*
        // include the attribute. The bulk `symbolgraph-extract` shape captured here is real, not
        // hand-assembled: the method's own `declarationFragments` carry no attribute at all,
        // because inherited class-level isolation is never restated per member.
        let json = """
        {
          "symbols":[
            {"identifier":{"precise":"c:objc(cs)UINavigationController"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"},{"kind":"keyword","spelling":"class"}]},
            {"identifier":{"precise":"c:objc(cs)UINavigationController(im)pushViewController:animated:"},"declarationFragments":[{"kind":"keyword","spelling":"func"}]},
            {"identifier":{"precise":"c:objc(cs)NSSomethingPlain"},"declarationFragments":[{"kind":"keyword","spelling":"class"}]}
          ],
          "relationships":[
            {"kind":"memberOf","source":"c:objc(cs)UINavigationController(im)pushViewController:animated:","target":"c:objc(cs)UINavigationController"}
          ]
        }
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            let primaryFile = outputDir.appendingPathComponent("UIKit.symbols.json")
            try? fileSystem.write(data: Data(json.utf8), to: primaryFile)
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "UIKit", sdkPath: "/fake/sdk", target: "arm64-apple-ios17.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved.isolationByUSR["c:objc(cs)UINavigationController"] == .globalActor(name: "MainActor"))
        #expect(resolved.isolationByUSR["c:objc(cs)UINavigationController(im)pushViewController:animated:"] == .globalActor(name: "MainActor"), "SE-0316: a member with no isolation of its own inherits its container's confirmed globalActor isolation -- the only way it wouldn't is an explicit nonisolated on the member itself, which is a hasConfirmedIsolationSignal match handled before this fallback ever runs")
        #expect(resolved.isolationByUSR["c:objc(cs)NSSomethingPlain"] == .nonisolated, "a non-member's own \"no attribute\" fragments have no containing type to have inherited from, so they stay a trustworthy, cached .nonisolated fact")
    }

    @Test("extract() trusts a member's own \"no attribute\" fragments when its container itself resolves to .nonisolated -- the real Int.+= regression this check's first, over-broad version introduced")
    func trustsMemberOfANonisolatedContainer() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        // `+=` is a real static member of `Int` (a plain, nonisolated struct -- no attribute of
        // its own either). Treating *every* member with no attribute as ambiguous (this check's
        // first version) wrongly omitted this and every other stdlib operator/member with the
        // same shape, turning a confirmed `.nonisolated` fact into `unspecified` project-wide --
        // caught by `CapstoneCLITests`'s own real fixture.
        let json = """
        {
          "symbols":[
            {"identifier":{"precise":"s:Si"},"declarationFragments":[{"kind":"keyword","spelling":"struct"}]},
            {"identifier":{"precise":"s:Si2peoiyySiz_SitFZ"},"declarationFragments":[{"kind":"keyword","spelling":"static"}]}
          ],
          "relationships":[
            {"kind":"memberOf","source":"s:Si2peoiyySiz_SitFZ","target":"s:Si"}
          ]
        }
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            let primaryFile = outputDir.appendingPathComponent("Swift.symbols.json")
            try? fileSystem.write(data: Data(json.utf8), to: primaryFile)
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "Swift", sdkPath: "/fake/sdk", target: "arm64-apple-ios17.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved.isolationByUSR["s:Si2peoiyySiz_SitFZ"] == .nonisolated)
    }

    @Test("extract() walks a superclass chain (inheritsFrom) to find a confirmed container isolation, not just the immediate container's own fragments")
    func walksSuperclassChainForContainerIsolation() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        // `GrandchildView` doesn't restate `@MainActor` (nothing does, per member -- that's the
        // whole bug), and neither does its immediate superclass `MiddleView`; only the root
        // `BaseView` states it explicitly. A member of `GrandchildView` must still resolve to the
        // *root's* isolation, not `.nonisolated`, by walking the full chain -- a shallow, one-level
        // container check would have missed this and wrongly trusted the member as `.nonisolated`.
        let json = """
        {
          "symbols":[
            {"identifier":{"precise":"c:objc(cs)BaseView"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"},{"kind":"keyword","spelling":"class"}]},
            {"identifier":{"precise":"c:objc(cs)MiddleView"},"declarationFragments":[{"kind":"keyword","spelling":"class"}]},
            {"identifier":{"precise":"c:objc(cs)GrandchildView"},"declarationFragments":[{"kind":"keyword","spelling":"class"}]},
            {"identifier":{"precise":"c:objc(cs)GrandchildView(im)someMethod"},"declarationFragments":[{"kind":"keyword","spelling":"func"}]}
          ],
          "relationships":[
            {"kind":"inheritsFrom","source":"c:objc(cs)MiddleView","target":"c:objc(cs)BaseView"},
            {"kind":"inheritsFrom","source":"c:objc(cs)GrandchildView","target":"c:objc(cs)MiddleView"},
            {"kind":"memberOf","source":"c:objc(cs)GrandchildView(im)someMethod","target":"c:objc(cs)GrandchildView"}
          ]
        }
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            let primaryFile = outputDir.appendingPathComponent("UIKit.symbols.json")
            try? fileSystem.write(data: Data(json.utf8), to: primaryFile)
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "UIKit", sdkPath: "/fake/sdk", target: "arm64-apple-ios17.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved.isolationByUSR["c:objc(cs)GrandchildView(im)someMethod"] == .globalActor(name: "MainActor"), "GrandchildView's own isolation comes from two inheritsFrom hops away -- must still be found and inherited, not missed")
    }

    @Test("extract() trusts a member's own explicit nonisolated over its globalActor container -- confirmed real, not hypothetical: 184 real members carry this in a live UIKit extraction")
    func trustsExplicitNonisolatedMemberOverGlobalActorContainer() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        let json = """
        {
          "symbols":[
            {"identifier":{"precise":"c:objc(cs)SomeMainActorClass"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"},{"kind":"keyword","spelling":"class"}]},
            {"identifier":{"precise":"c:objc(cs)SomeMainActorClass(im)someNonisolatedMember"},"declarationFragments":[{"kind":"attribute","spelling":"nonisolated"},{"kind":"keyword","spelling":"func"}]}
          ],
          "relationships":[
            {"kind":"memberOf","source":"c:objc(cs)SomeMainActorClass(im)someNonisolatedMember","target":"c:objc(cs)SomeMainActorClass"}
          ]
        }
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            try? fileSystem.write(data: Data(json.utf8), to: outputDir.appendingPathComponent("SomeModule.symbols.json"))
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "SomeModule", sdkPath: "/fake/sdk", target: "arm64-apple-ios17.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved.isolationByUSR["c:objc(cs)SomeMainActorClass(im)someNonisolatedMember"] == .nonisolated, "the member's own nonisolated fragment is a hasConfirmedIsolationSignal match, resolved before the container-inheritance fallback ever runs -- must never be overridden by the container's MainActor isolation")
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
        #expect(resolved.isolationByUSR["s:4ModA9BaseThingC0A1BE2kfSivp"] == .globalActor(name: "MainActor"))
    }

    @Test("extract() reports a symbol as a protocol only when its own kind.identifier is \"swift.protocol\" -- a class with the identical isolation is not, real shape confirmed live against UIView (class) vs UITableViewDelegate (protocol) in this machine's own UIKit symbolgraph-extract output")
    func distinguishesProtocolKindFromClassKind() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        let json = """
        {"symbols":[
            {"identifier":{"precise":"c:objc(cs)UIView"},"kind":{"identifier":"swift.class"},"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"},{"kind":"keyword","spelling":"class"}]},
            {"identifier":{"precise":"c:objc(pl)UITableViewDelegate"},"kind":{"identifier":"swift.protocol"},"declarationFragments":[{"kind":"keyword","spelling":"protocol"}]},
            {"identifier":{"precise":"c:objc(cs)NoKindHere"},"declarationFragments":[{"kind":"keyword","spelling":"class"}]}
        ]}
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            try? fileSystem.write(data: Data(json.utf8), to: outputDir.appendingPathComponent("UIKit.symbols.json"))
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "UIKit", sdkPath: "/fake/sdk", target: "arm64-apple-ios17.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved.protocolUSRs == ["c:objc(pl)UITableViewDelegate"])
        #expect(!resolved.protocolUSRs.contains("c:objc(cs)UIView"), "UIView is a real, globally-actor-isolated class, not a protocol -- it must never be reported as one")
        #expect(!resolved.protocolUSRs.contains("c:objc(cs)NoKindHere"), "a symbol with no kind field at all (an older/malformed document) must decode without crashing and stay absent from protocolUSRs, never guessed")
    }

    @Test("Issue #40: extract() discovers a type's own literal @globalActor attribute as a real global-actor name")
    func discoversRealGlobalActorNameFromOwnDeclaration() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        // Real shape confirmed via a live `swift symbolgraph-extract` run against a hand-built
        // `@globalActor public actor ThirdPartyActor { ... }` module: the type's own
        // declarationFragments carry a single, literal `{"kind":"attribute","spelling":
        // "@globalActor"}` fragment -- unlike a *use* of that type as an isolation attribute
        // elsewhere (a two-fragment "@" + name-with-preciseIdentifier shape), this is unambiguous
        // and needs no name-matching heuristic at all.
        let json = """
        {"symbols":[
            {"identifier":{"precise":"s:18ThirdPartyActorKit0abC0C"},"pathComponents":["ThirdPartyActor"],"declarationFragments":[{"kind":"attribute","spelling":"@globalActor"},{"kind":"keyword","spelling":"actor"}]},
            {"identifier":{"precise":"c:objc(cs)NotAGlobalActor"},"pathComponents":["NotAGlobalActor"],"declarationFragments":[{"kind":"keyword","spelling":"class"}]}
        ]}
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            try? fileSystem.write(data: Data(json.utf8), to: outputDir.appendingPathComponent("ThirdPartyActorKit.symbols.json"))
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "ThirdPartyActorKit", sdkPath: "/fake/sdk", target: "arm64-apple-macosx13.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved.discoveredGlobalActorNames == ["ThirdPartyActor"])
    }

    @Test("Issue #40: extract() resolves a same-module declaration attributed with a discovered custom global actor's name, not just MainActor")
    func resolvesSameModuleDeclarationAttributedWithDiscoveredGlobalActor() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        // Real shape confirmed live: `@ThirdPartyActor public func thirdPartyIsolatedWork() {}`'s
        // own declaration fragments carry a two-fragment "@" + name-with-preciseIdentifier shape
        // naming `ThirdPartyActor` -- the same shape a `@StateObject`/`@Router`/... property-wrapper
        // fragment has (`GlobalActorNameValidation`'s own doc comment). Before this fix,
        // `bulkKnownGlobalActorNames` was unconditionally empty, so this fragment could never pass
        // validation and this symbol was permanently bulk-cached as `.nonisolated`, short-
        // circuiting the live-oracle path before it ever ran (confirmed against a real, compiling
        // minimal repro -- Issue #40's own comment thread).
        let json = """
        {"symbols":[
            {"identifier":{"precise":"s:18ThirdPartyActorKit0abC0C"},"pathComponents":["ThirdPartyActor"],"declarationFragments":[{"kind":"attribute","spelling":"@globalActor"},{"kind":"keyword","spelling":"actor"}]},
            {"identifier":{"precise":"s:18ThirdPartyActorKit05thirdB12IsolatedWorkyyF"},"pathComponents":["thirdPartyIsolatedWork()"],"declarationFragments":[{"kind":"attribute","spelling":"@"},{"kind":"attribute","spelling":"ThirdPartyActor","preciseIdentifier":"s:18ThirdPartyActorKit0abC0C"},{"kind":"keyword","spelling":"func"}]}
        ]}
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            try? fileSystem.write(data: Data(json.utf8), to: outputDir.appendingPathComponent("ThirdPartyActorKit.symbols.json"))
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "ThirdPartyActorKit", sdkPath: "/fake/sdk", target: "arm64-apple-macosx13.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved.isolationByUSR["s:18ThirdPartyActorKit05thirdB12IsolatedWorkyyF"] == .globalActor(name: "ThirdPartyActor"))
    }

    @Test("Issue #40: extract() does NOT mistake a property wrapper's own class declaration for a global actor -- StateObject counterexample, GlobalActorNameValidation's own real motivating case")
    func doesNotMistakePropertyWrapperDeclarationForGlobalActor() {
        let processRunning = FakeProcessRunning()
        let fileSystem = FakeFileSystemQuerying()

        // `StateObject` is a real SwiftUI property wrapper `struct`, never `@globalActor`-declared
        // -- its own declaration fragments carry no such attribute at all. Guards the discovery
        // logic itself against the exact confusion `GlobalActorNameValidation` exists to prevent.
        let json = """
        {"symbols":[
            {"identifier":{"precise":"s:7SwiftUI11StateObjectV"},"pathComponents":["StateObject"],"declarationFragments":[{"kind":"keyword","spelling":"struct"}]}
        ]}
        """
        processRunning.onRun = { arguments in
            guard let outputDirIndex = arguments.firstIndex(of: "-output-dir") else { return }
            let outputDir = URL(fileURLWithPath: arguments[arguments.index(after: outputDirIndex)])
            try? fileSystem.write(data: Data(json.utf8), to: outputDir.appendingPathComponent("SwiftUI.symbols.json"))
        }

        let resolved = BulkSymbolGraphExtractor.extract(
            moduleName: "SwiftUI", sdkPath: "/fake/sdk", target: "arm64-apple-macosx13.0",
            processRunning: processRunning, fileSystem: fileSystem
        )
        #expect(resolved.discoveredGlobalActorNames.isEmpty)
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
        #expect(resolved.isolationByUSR["c:objc(cs)NSView"] == .globalActor(name: "MainActor"))
    }
}
