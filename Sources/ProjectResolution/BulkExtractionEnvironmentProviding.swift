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
/// `-verbose build`. Single-invocation-then-cache shape, mirroring
/// `LiveXcodeCompilerArgumentsProvider`'s existing pattern.
public final class LiveXcodeBulkExtractionEnvironmentProvider: BulkExtractionEnvironmentProviding, @unchecked Sendable {
    private let container: ProjectContainer
    private let scheme: String
    private let processRunning: ProcessRunning
    private let fileSystem: FileSystemQuerying
    private let lock = NSLock()
    private var cached: BulkExtractionEnvironment?

    public init(
        container: ProjectContainer,
        scheme: String,
        processRunning: ProcessRunning = LiveProcessRunner(),
        fileSystem: FileSystemQuerying = LiveFileSystem()
    ) {
        self.container = container
        self.scheme = scheme
        self.processRunning = processRunning
        self.fileSystem = fileSystem
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
        // documents for `LiveXcodeCompilerArgumentsProvider` (a physical device paired to the
        // machine in the past, not currently connected, sorting ahead of every Simulator
        // destination in `-showdestinations`): without an explicit `-destination`, this provider's
        // own `-showBuildSettings` call resolved `PLATFORM_NAME=iphoneos` (confirmed directly
        // against a real corpus this session) even though every real build on this machine only
        // ever produces `Debug-iphonesimulator` -- every `FRAMEWORK_SEARCH_PATHS` entry this
        // resolves then points at a `Debug-iphoneos` directory that was never built, silently
        // disabling bulk pre-resolution for every discovered third-party module (confirmed via
        // direct `symbolgraph-extract` reproduction: `Couldn't load module 'X'` for every one of
        // them). See docs/task-bulk-extraction-wrong-platform.md §2.
        if let destination = resolveDeterministicSimulatorDestination(container: container, scheme: scheme, processRunning: processRunning) {
            arguments += ["-destination", destination]
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
        // .build/<triple>/{debug,release}/ -- the triple is the bin directory's own parent.
        let target = binPath.deletingLastPathComponent().lastPathComponent

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
