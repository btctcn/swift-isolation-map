import Foundation
import IsolationCore
import ProjectResolution

/// Bulk-resolves isolation for every public symbol in a whole SDK module at once, via
/// `swift symbolgraph-extract -module-name <X> -sdk ... -target ...` -- the same real compiler
/// data source `SymbolGraphIsolationParser` already parses per-symbol from `cursorinfo`
/// (`SymbolGraphGen`, shared by both paths), just retrieved for an entire module in one process
/// invocation instead of one `sourcekitd` round trip per external declaration. Empirically
/// confirmed: extracting all of UIKit (~26MB JSON, thousands of symbols, including `UIViewController`
/// correctly carrying `@MainActor` in its `declarationFragments`) takes a few seconds on the real
/// toolchain -- versus the hundreds of individual live `cursorinfo` queries a large real project
/// needed before this existed (see docs/priority-3-compiled-dependency-isolation.md for the
/// `~/ios` before/after timing).
///
/// This is a *performance* cache, not a new source of truth: every value still comes from the real
/// compiler, keyed by real USR (`identifier.precise`, module-qualified and unambiguous by
/// construction -- never a bare name). A module not covered here (a custom XCFramework, a
/// third-party binary SwiftPM dependency, or any SDK module simply not in `moduleNames`) is absent
/// from the returned dictionary, and callers fall back to the existing live per-declaration
/// `cursorinfo` oracle, unaffected and unchanged.
public enum BulkSymbolGraphExtractor {
    /// Well-known SDK modules worth eagerly bulk-extracting -- covers the overwhelming majority of
    /// external superclasses/protocols/call targets real iOS/macOS projects reference. Deliberately
    /// *not* a source-of-truth list -- it only controls which modules get this fast path; a project
    /// referencing something outside this list still resolves correctly, just via the slower
    /// live-query path this list exists to avoid for the common case.
    ///
    /// `Foundation`/`ObjectiveC`/`CoreGraphics`/`Dispatch` were added after real-world validation
    /// against `~/ios` showed the original three-module list (`UIKit`/`AppKit`/`SwiftUI`) alone left
    /// a large residual live-query volume -- these SDK modules aren't discoverable the way
    /// third-party CocoaPods/XCFrameworks are (`FrameworkModuleDiscovery`, not separate
    /// `-F`-searchable directories, implicitly available via `-sdk` alone the same way UIKit is),
    /// so they must be requested explicitly. Confirmed empirically each extracts in well under 5
    /// seconds (`Foundation` itself, the largest of that batch, ~4.7s) -- cheap enough to always
    /// attempt. `Swift`/`CoreFoundation` were added after the same diagnostic identified real,
    /// uncovered residual misses shaped like bare stdlib symbols (`Array`'s literal initializer,
    /// `Bool`'s `!` operator, `CGFloat` literal inits) -- despite `Swift` being, per real-world
    /// research, plausibly "the largest module there is," measured empirically at ~1.2s/51MB here
    /// (`CoreFoundation`: ~0.5s/5MB) -- not assumed cheap just because every other module was.
    public static let defaultModules = ["UIKit", "AppKit", "SwiftUI", "Foundation", "ObjectiveC", "CoreGraphics", "Dispatch", "Swift", "CoreFoundation"]

    /// A hung or pathologically slow module (a large/misconfigured third-party framework) must
    /// not be able to stall the whole bulk phase indefinitely -- bounded, but generous. The
    /// original 60s (4x the ~14s `AppKit` extraction measured on an 8-core dev machine) was proven
    /// too tight this session: a real `macos-latest` CI run's weaker hardware reproducibly (3 of 3
    /// consecutive runs) hit this exact timeout extracting `AppKit`, silently returning an empty
    /// result (`extract()`'s own documented fail-soft behavior on a non-zero exit) and failing
    /// `BulkSymbolGraphExtractorTests`'s live-toolchain assertion -- not a hang, just genuinely
    /// slower hardware needing more than 60s for the same real work. Raised with a much larger
    /// margin so a slower CI runner (or a heavier module than AppKit) doesn't hit this again.
    static let perModuleTimeout: TimeInterval = 300

    /// Extracts and merges every module in `moduleNames` (well-known SDK modules, `-sdk`/`-target`
    /// only) plus every `discoveredModules` entry (real third-party modules found in the project's
    /// own build configuration, each with its own `extractionFlags`, e.g. `-F <path>`), silently
    /// skipping (not failing) any module absent from the current SDK or otherwise unresolvable --
    /// e.g. requesting `AppKit` against an iOS SDK, which `symbolgraph-extract` itself rejects with
    /// a non-zero exit, or a module that times out. Fail-soft end to end, matching the rest of the
    /// external-isolation oracle's contract: a module this can't cover just means its symbols fall
    /// through to the live query path, never a crash or a wrong answer.
    ///
    /// Runs every module's extraction concurrently via `DispatchQueue.concurrentPerform` -- real OS
    /// threads, not Swift's cooperative pool (this is a plain synchronous function with no actor
    /// isolation to preserve, and the rest of this codebase already avoids blocking the cooperative
    /// pool with synchronous subprocess waits the same way, via `runAsyncBridge`'s hand-rolled
    /// semaphore). Each iteration writes to its own preallocated array slot (never a shared
    /// dictionary mutated from parallel closures), then results are merged back in the original,
    /// deterministic module order afterward, regardless of completion order.
    public static func extractAll(
        moduleNames: [String] = defaultModules,
        discoveredModules: [DiscoveredModule] = [],
        sdkPath: String,
        target: String,
        processRunning: ProcessRunning,
        fileSystem: FileSystemQuerying
    ) -> [String: IsolationKind] {
        let jobs: [(name: String, extractionFlags: [String])] =
            moduleNames.map { (name: $0, extractionFlags: []) }
            + discoveredModules.map { (name: $0.name, extractionFlags: $0.extractionFlags) }
        guard !jobs.isEmpty else { return [:] }

        let resultBuffer = ResultBuffer(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            let job = jobs[index]
            let extracted = extract(
                moduleName: job.name, sdkPath: sdkPath, target: target, additionalArguments: job.extractionFlags,
                processRunning: processRunning, fileSystem: fileSystem
            )
            resultBuffer.set(extracted, at: index)
        }

        var merged: [String: IsolationKind] = [:]
        for result in resultBuffer.results {
            for (usr, isolation) in result {
                merged[usr] = isolation
            }
        }
        return merged
    }

    static func extract(
        moduleName: String,
        sdkPath: String,
        target: String,
        additionalArguments: [String] = [],
        processRunning: ProcessRunning,
        fileSystem: FileSystemQuerying
    ) -> [String: IsolationKind] {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-isolation-map-symbolgraph-\(moduleName)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let result = try processRunning.run(
                executable: "xcrun",
                arguments: [
                    "swift", "symbolgraph-extract",
                    "-module-name", moduleName,
                    "-sdk", sdkPath,
                    "-target", target,
                    "-output-dir", outputDirectory.path,
                    "-minimum-access-level", "public"
                ] + additionalArguments,
                workingDirectory: nil,
                timeout: perModuleTimeout
            )
            guard result.exitCode == 0 else { return [:] }

            // Every `*.symbols.json` file, not just the module's own primary `<Module>.symbols.json`
            // -- confirmed empirically (a real two-module build: a `@MainActor` property added to
            // one module's type via `extension` from another module) that a symbol declared in an
            // extension of a type from a *different* module is serialized only into the sibling
            // `<Module>@<ExtendedModule>.symbols.json` file, never into the primary one, which is
            // left empty for that symbol. This is exactly the shape of the original motivating bug
            // (a Kingfisher extension member on `UITableViewCell`) -- reading only the primary file
            // would silently miss it. USR keys are globally unique regardless of which file they
            // came from, so merging needs no precedence logic.
            let symbolFiles = try fileSystem.contentsOfDirectory(at: outputDirectory)
                .filter { $0.lastPathComponent.hasSuffix(".symbols.json") }
            var resolved: [String: IsolationKind] = [:]
            for file in symbolFiles {
                guard let data = try? fileSystem.readData(at: file),
                      let document = try? JSONDecoder().decode(BulkSymbolGraphDocument.self, from: data) else { continue }
                for symbol in document.symbols {
                    resolved[symbol.identifier.precise] = SymbolGraphIsolationParser.isolation(fromFragments: symbol.declarationFragments ?? [])
                }
            }
            return resolved
        } catch {
            return [:]
        }
    }
}

/// Each `DispatchQueue.concurrentPerform` iteration writes exactly one distinct index, so despite
/// the Swift concurrency checker's conservative refusal to reason about indexed writes into a
/// captured `inout`/value-type buffer, this class-based indexed store is genuinely race-free: no
/// two concurrent iterations ever touch the same slot. Mirrors this project's existing
/// `ResultBox<T>: @unchecked Sendable` precedent (`SwiftIsolationMap.swift`) for the same reason --
/// a hand-verified safety argument the compiler can't itself express.
private final class ResultBuffer: @unchecked Sendable {
    private(set) var results: [[String: IsolationKind]]

    init(count: Int) {
        results = Array(repeating: [:], count: count)
    }

    func set(_ value: [String: IsolationKind], at index: Int) {
        results[index] = value
    }
}

struct BulkSymbolGraphDocument: Decodable {
    let symbols: [Symbol]

    struct Symbol: Decodable {
        let identifier: Identifier
        let declarationFragments: [SymbolGraphDocument.Symbol.Fragment]?

        struct Identifier: Decodable {
            let precise: String
        }
    }
}
