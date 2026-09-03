import Foundation

public enum BulkExtractionEnvironmentError: Error, Equatable {
    case settingsUnavailable(reason: String)
}

/// The SDK path, target triple, and real, extractable third-party modules a bulk
/// `swift symbolgraph-extract` pass needs -- deliberately *not* per-file, unlike
/// `CompilerArgumentsProviding`. Kept as its own narrow seam rather than folded into
/// `CompilerArgumentsProviding` because that protocol's real Xcode implementation needs a full
/// `-verbose build` (with its confirmed `clean build` fallback cost for an already-up-to-date
/// project) -- reusing it here would drag that cost into the bulk phase, defeating the entire
/// point of this type existing. A `BulkExtractionEnvironmentProviding` implementation must be
/// obtainable without ever running a real build.
///
/// `discoveredModules` is *additive* to the existing hardcoded well-known SDK-module list
/// (`BulkSymbolGraphExtractor.defaultModules`) -- Apple's own SDK frameworks (UIKit/AppKit/SwiftUI)
/// aren't discoverable this way (not separate directories, implicitly available via `-sdk` alone),
/// so both sources feed the same merged bulk cache.
public struct BulkExtractionEnvironment: Equatable, Sendable {
    public let sdkPath: String
    public let target: String
    public let discoveredModules: [DiscoveredModule]

    public init(sdkPath: String, target: String, discoveredModules: [DiscoveredModule]) {
        self.sdkPath = sdkPath
        self.target = target
        self.discoveredModules = discoveredModules
    }
}

public protocol BulkExtractionEnvironmentProviding: Sendable {
    func environment() throws -> BulkExtractionEnvironment
}

/// Real, fast, read-only `xcodebuild -showBuildSettings` -- confirmed empirically to complete in
/// seconds against a real, large project (`Project Iris`) regardless of build freshness, unlike
/// `-verbose build`. Single-invocation-then-cache shape.
public final class LiveXcodeBulkExtractionEnvironmentProvider: BulkExtractionEnvironmentProviding, @unchecked Sendable {
    private let container: ProjectContainer
    private let scheme: String
    private let processRunning: ProcessRunning
    private let fileSystem: FileSystemQuerying
    /// Threaded through, never recomputed -- the same private-DerivedData invariant every other
    /// real `xcodebuild` invocation in this project already honors (`PrivateDerivedDataLocator`'s
    /// own computation, shared with `SwiftIsolationMap.build`).
    /// Confirmed missing here the hard way: without it, this provider's own `-showBuildSettings`
    /// call silently used Xcode's *shared* DerivedData location instead
    /// (`~/Library/Developer/Xcode/DerivedData/<Project>-<hash>`), recreating that shared folder on
    /// every single analysis run against an Xcode project -- exactly the cross-run/cross-tool
    /// pollution risk `docs/task-private-derived-data-hypothesis.md` exists to rule out everywhere
    /// else, missed for this one provider.
    private let derivedDataPath: URL?
    /// Threaded through to `resolveDeterministicSimulatorDestination` below, same `--platform` flag
    /// (issue #140) every other real destination-resolution call site in this project now honors --
    /// kept consistent deliberately: a bulk symbol-graph pass extracted against a *different*
    /// platform's SDK/target than the rest of this run would silently produce wrong isolation facts
    /// for platform-conditional dependencies, not just an inconsistent destination choice.
    private let preferredPlatform: String?
    private let lock = NSLock()
    private var cached: BulkExtractionEnvironment?

    public init(
        container: ProjectContainer,
        scheme: String,
        processRunning: ProcessRunning = LiveProcessRunner(),
        fileSystem: FileSystemQuerying = LiveFileSystem(),
        derivedDataPath: URL? = nil,
        preferredPlatform: String? = nil
    ) {
        self.container = container
        self.scheme = scheme
        self.processRunning = processRunning
        self.fileSystem = fileSystem
        self.derivedDataPath = derivedDataPath
        self.preferredPlatform = preferredPlatform
    }

    public func environment() throws -> BulkExtractionEnvironment {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        var arguments = ["-showBuildSettings", "-scheme", scheme]
        switch container {
        case .xcodeproj(let url):
            arguments += ["-project", url.path]
        case .xcworkspace(let url):
            arguments += ["-workspace", url.path]
        case .swiftPackage:
            preconditionFailure("LiveXcodeBulkExtractionEnvironmentProvider is only valid for .xcodeproj/.xcworkspace containers")
        }
        // Same real failure `resolveDeterministicSimulatorDestination`'s own doc comment already
        // documents (a physical device paired to the machine in the past, not currently connected,
        // sorting ahead of every Simulator destination in `-showdestinations`): without an
        // explicit `-destination`, this provider's
        // own `-showBuildSettings` call resolved `PLATFORM_NAME=iphoneos` (confirmed directly
        // against a real corpus this session) even though every real build on this machine only
        // ever produces `Debug-iphonesimulator` -- every `FRAMEWORK_SEARCH_PATHS` entry this
        // resolves then points at a `Debug-iphoneos` directory that was never built, silently
        // disabling bulk pre-resolution for every discovered third-party module (confirmed via
        // direct `symbolgraph-extract` reproduction: `Couldn't load module 'X'` for every one of
        // them). See docs/task-bulk-extraction-wrong-platform.md §2.
        if let destination = try resolveDeterministicSimulatorDestination(
            container: container, scheme: scheme, processRunning: processRunning, derivedDataPath: derivedDataPath,
            preferredPlatform: preferredPlatform
        ) {
            arguments += ["-destination", destination]
        }
        if let derivedDataPath {
            arguments += ["-derivedDataPath", derivedDataPath.path]
        }

        let result = try processRunning.run(executable: "xcodebuild", arguments: arguments, workingDirectory: nil)
        guard result.exitCode == 0 else {
            throw BulkExtractionEnvironmentError.settingsUnavailable(
                reason: "xcodebuild -showBuildSettings exited \(result.exitCode): \(result.standardError)"
            )
        }

        let settings = XcodeBuildSettingsParser.parse(output: result.standardOutput)
        guard let sdkPath = settings["SDKROOT"],
              let archsRaw = settings["ARCHS"],
              let architecture = archsRaw.split(separator: " ").first.map(String.init),
              let platformName = settings["PLATFORM_NAME"],
              let deploymentTargetSettingName = settings["DEPLOYMENT_TARGET_SETTING_NAME"],
              let deploymentTarget = settings[deploymentTargetSettingName],
              let target = XcodeBuildSettingsParser.targetTriple(
                architecture: architecture, platformName: platformName, deploymentTarget: deploymentTarget
              ) else {
            throw BulkExtractionEnvironmentError.settingsUnavailable(reason: "required build settings missing or unrecognized platform")
        }

        let frameworkSearchPaths = settings["FRAMEWORK_SEARCH_PATHS"].map(CompilerArgsLogParser.tokenize) ?? []
        let discoveredModules = FrameworkModuleDiscovery.discoverFrameworks(inSearchPaths: frameworkSearchPaths, fileSystem: fileSystem)

        let environment = BulkExtractionEnvironment(sdkPath: sdkPath, target: target, discoveredModules: discoveredModules)
        cached = environment
        return environment
    }
}

/// SwiftPM has no `-showBuildSettings` equivalent, but also none of the Xcode "already-built target
/// prints no compile lines" problem this whole seam exists to route around -- `swift build
/// --show-bin-path` is itself already fast and triggers no compilation, and its own output path
/// encodes the real resolved target triple (`.build/<triple>/{debug,release}`). Dependency modules
/// live locally under that same `Modules` directory as plain `.swiftmodule` files (no `.framework`
/// bundling, no directory-basename-vs-real-name mismatch the way CocoaPods frameworks have).
public final class SwiftPMBulkExtractionEnvironmentProvider: BulkExtractionEnvironmentProviding, @unchecked Sendable {
    private let packageDirectory: URL
    private let processRunning: ProcessRunning
    private let fileSystem: FileSystemQuerying
    private let lock = NSLock()
    private var cached: BulkExtractionEnvironment?

    public init(
        packageDirectory: URL,
        processRunning: ProcessRunning = LiveProcessRunner(),
        fileSystem: FileSystemQuerying = LiveFileSystem()
    ) {
        self.packageDirectory = packageDirectory
        self.processRunning = processRunning
        self.fileSystem = fileSystem
    }

    public func environment() throws -> BulkExtractionEnvironment {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let binPathResult = try processRunning.run(
            executable: "swift", arguments: ["build", "--show-bin-path"], workingDirectory: packageDirectory
        )
        guard binPathResult.exitCode == 0 else {
            throw BulkExtractionEnvironmentError.settingsUnavailable(
                reason: "swift build --show-bin-path exited \(binPathResult.exitCode): \(binPathResult.standardError)"
            )
        }
        let binPath = URL(fileURLWithPath: binPathResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        // .build/<triple>/{debug,release}/ -- the triple is the bin directory's own parent, but
        // SwiftPM's own build-directory naming deliberately omits the OS version component
        // (confirmed directly: a real `arm64-apple-macosx` folder name, never
        // `arm64-apple-macosx13.0`) -- using it bare as `-target` leaves the *compiler's own*
        // default apply instead, which is not "whatever this machine's SDK actually supports," but
        // a fixed, ancient baseline (confirmed directly: `swift symbolgraph-extract -target
        // arm64-apple-macosx ...` against a real `.macOS(.v13)`-declared dependency's own
        // `.swiftmodule` fails outright with "compiling for macOS 10.4, but module 'X' has a
        // minimum deployment target of macOS 13.0" -- silently discarding that module's isolation
        // data via this function's own existing fail-soft contract, for every SwiftPM dependency
        // with any realistic platform minimum, found chasing Issue #40's own real-corpus
        // verification). The real SDK's own current version is always a safe, valid target here
        // (symbolgraph-extract only reads declarations, never checks runtime availability against
        // it) -- appended directly, since the triple's own arch-vendor-os prefix is otherwise
        // already correct.
        let sdkVersionResult = try processRunning.run(executable: "xcrun", arguments: ["--sdk", "macosx", "--show-sdk-version"], workingDirectory: nil)
        guard sdkVersionResult.exitCode == 0 else {
            throw BulkExtractionEnvironmentError.settingsUnavailable(
                reason: "xcrun --sdk macosx --show-sdk-version exited \(sdkVersionResult.exitCode): \(sdkVersionResult.standardError)"
            )
        }
        let sdkVersion = sdkVersionResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = binPath.deletingLastPathComponent().lastPathComponent + sdkVersion

        let sdkResult = try processRunning.run(executable: "xcrun", arguments: ["--show-sdk-path"], workingDirectory: nil)
        guard sdkResult.exitCode == 0 else {
            throw BulkExtractionEnvironmentError.settingsUnavailable(
                reason: "xcrun --show-sdk-path exited \(sdkResult.exitCode): \(sdkResult.standardError)"
            )
        }
        let sdkPath = sdkResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        let modulesDirectory = binPath.appendingPathComponent("Modules")
        let discoveredModules = discoverSwiftModules(inDirectory: modulesDirectory)

        let environment = BulkExtractionEnvironment(sdkPath: sdkPath, target: target, discoveredModules: discoveredModules)
        cached = environment
        return environment
    }

    private func discoverSwiftModules(inDirectory modulesDirectory: URL) -> [DiscoveredModule] {
        guard let entries = try? fileSystem.contentsOfDirectory(at: modulesDirectory) else { return [] }
        return entries
            .filter { $0.pathExtension == "swiftmodule" }
            .map { DiscoveredModule(name: $0.deletingPathExtension().lastPathComponent, extractionFlags: ["-I", modulesDirectory.path]) }
    }
}
