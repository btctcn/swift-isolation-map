import Foundation
import SwiftBuild

/// EXPERIMENTAL (`--experimental-swift-build-compiler-args`), may be removed without notice.
///
/// Real per-file `swiftc` compiler arguments obtained by talking to `SWBBuildService` directly via
/// the open-source `SwiftBuild` Swift API (`swiftlang/swift-build`), bypassing `xcodebuild`'s CLI
/// entirely. Exists because `xcodebuild -showBuildSettingsForIndex` was proven
/// (docs/task-xcodebuild-show-build-settings-for-index-spike.md Step 6a) to silently discard
/// `-destination`/`-sdk` and default to device for at least one real project, while the
/// open-source engine underneath it is destination-faithful when driven directly -- confirmed end
/// -to-end against a real ~2200-file corpus, byte-for-byte edge parity with the honest clean-
/// rebuild path, ~35% faster (docs/task-swift-build-prepare-for-indexing-spike.md Step 10).
///
/// Queries **every** target in the workspace, not just the scheme's own primary target, and merges
/// their file maps -- scoping to the primary target alone silently missed every file exclusive to
/// a dependency target (this project's own extensions, confirmed the hard way, same doc's Step 10
/// v1/v2). Mirrors what `-showBuildSettingsForIndex` already does structurally (its own JSON is
/// keyed by every target in the workspace).
public final class SwiftBuildCompilerArgumentsProvider: CompilerArgumentsProviding, @unchecked Sendable {
    private let container: ProjectContainer
    private let scheme: String
    private let derivedDataPath: URL
    private let locator: SWBBuildServiceLocating

    private let lock = NSLock()
    private var cachedArguments: [String: [String]]?
    private var cachedModuleNames: Set<String> = []
    private var cachedError: Error?

    public init(
        container: ProjectContainer,
        scheme: String,
        derivedDataPath: URL,
        locator: SWBBuildServiceLocating = LiveSWBBuildServiceLocator()
    ) {
        self.container = container
        self.scheme = scheme
        self.derivedDataPath = derivedDataPath
        self.locator = locator
    }

    public func compilerArguments(forFile path: String) throws -> [String] {
        let map = try loadIfNeeded()
        guard let arguments = map[path] else {
            throw CompilerArgumentsError.argumentsNotFound(file: path)
        }
        return arguments
    }

    public func realModuleNames() -> Set<String>? {
        _ = try? loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedModuleNames.isEmpty ? nil : cachedModuleNames
    }

    private func loadIfNeeded() throws -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedArguments { return cachedArguments }
        if let cachedError { throw cachedError }
        do {
            let map = try run()
            cachedArguments = map
            return map
        } catch {
            cachedError = error
            throw error
        }
    }

    /// Bridges `CompilerArgumentsProviding`'s synchronous contract (every other conformer in this
    /// project is sync too, and `SwiftIsolationMap`'s own call sites are not `async`) onto the
    /// `SwiftBuild` API's real `async` surface. `ResultBox` carries the value out safely: the
    /// `Task`'s own write always happens-before the `semaphore.signal()` that unblocks the read
    /// after `semaphore.wait()` returns, so there is no actual concurrent access to `value`.
    private final class ResultBox: @unchecked Sendable {
        var value: Result<[String: [String]], Error>?
    }

    private func run() throws -> [String: [String]] {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task {
            do {
                box.value = .success(try await self.runAsync())
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.value!.get()
    }

    private func runAsync() async throws -> [String: [String]] {
        let bundleURL = try locator.serviceBundleURL()
        let service = try await SWBBuildService(serviceBundleURL: bundleURL)
        defer { Task { await service.close() } }

        let (sessionResult, _) = await service.createSession(name: "swift-isolation-map", cachePath: nil, inferiorProductsPath: nil, environment: nil)
        let session = try sessionResult.get()

        let containerPath: String
        switch container {
        case .xcodeproj(let url): containerPath = url.path
        case .xcworkspace(let url): containerPath = url.path
        case .swiftPackage:
            preconditionFailure("SwiftBuildCompilerArgumentsProvider is only valid for .xcodeproj/.xcworkspace containers")
        }
        try await session.loadWorkspace(containerPath: containerPath)

        let workspaceInfo = try await session.workspaceInfo()
        guard workspaceInfo.targetInfos.contains(where: { $0.targetName.lowercased() == scheme.lowercased() }) else {
            throw CompilerArgumentsError.buildLogParseFailed(
                reason: "no target named '\(scheme)' (case-insensitive) in workspace; available: \(workspaceInfo.targetInfos.map(\.targetName))"
            )
        }

        let sdkVersion = try Self.simulatorSDKVersion()
        var params = SWBBuildParameters()
        params.action = "build"
        params.configurationName = "Debug"
        params.activeRunDestination = SWBRunDestinationInfo(
            platform: "iphonesimulator",
            sdk: "iphonesimulator\(sdkVersion)",
            sdkVariant: "iphonesimulator",
            targetArchitecture: "arm64",
            supportedArchitectures: ["arm64", "x86_64"],
            disableOnlyActiveArch: false
        )
        params.arenaInfo = Self.arenaInfo(derivedDataPath: derivedDataPath)

        let delegate = SwiftBuildIndexingDelegate()
        var map: [String: [String]] = [:]
        var moduleNames: Set<String> = []
        var succeededTargetCount = 0
        for targetInfo in workspaceInfo.targetInfos {
            var request = SWBBuildRequest()
            request.parameters = params
            request.configuredTargets = [SWBConfiguredTarget(guid: targetInfo.guid, parameters: params)]
            request.useImplicitDependencies = true
            request.useParallelTargets = true

            let settings: SWBIndexingFileSettings
            do {
                settings = try await session.generateIndexingFileSettings(
                    for: request, targetID: targetInfo.guid, filePath: nil, outputPathOnly: false, delegate: delegate
                )
            } catch {
                // Not every target in a real workspace is necessarily buildable under an iOS
                // Simulator destination (a macOS-only helper tool, a target with no real sources
                // at all) -- skip those rather than aborting every other target's real, resolvable
                // files. Confirmed real and expected, not a silent-failure risk worth surfacing per
                // target: docs/task-swift-build-prepare-for-indexing-spike.md Step 10's 303-target
                // real-corpus run hit this for a meaningful fraction of targets and still reproduced
                // the honest build exactly.
                continue
            }
            succeededTargetCount += 1
            let (targetMap, targetModuleNames) = Self.parseIndexingFileSettings(settings.sourceFileBuildInfos)
            for (path, args) in targetMap where map[path] == nil {
                map[path] = args
            }
            moduleNames.formUnion(targetModuleNames)
        }
        try await session.close()

        writeStderr(
            "SwiftBuild direct: resolved compiler arguments for \(map.count) file(s) across "
                + "\(succeededTargetCount)/\(workspaceInfo.targetInfos.count) target(s)"
        )
        cachedModuleNames = moduleNames
        return map
    }

    /// Pure: extracts `[file: arguments]` and every real `-module-name` seen from one target's raw
    /// `generateIndexingFileSettings` response. Kept free of any `SwiftBuild` API call so it's
    /// directly unit-testable against hand-constructed `SWBPropertyListItem` fixtures (no live
    /// `SWBBuildService` session needed) -- `SWBIndexingFileSettings` itself has no public
    /// initializer, so tests build the raw `[[String: SWBPropertyListItem]]` shape this function
    /// actually consumes instead.
    static func parseIndexingFileSettings(_ sourceFileBuildInfos: [[String: SWBPropertyListItem]]) -> (map: [String: [String]], moduleNames: Set<String>) {
        var map: [String: [String]] = [:]
        var moduleNames: Set<String> = []
        for info in sourceFileBuildInfos {
            guard case .plString(let sourceFilePath)? = info["sourceFilePath"],
                  case .plArray(let argItems)? = info["swiftASTCommandArguments"] else { continue }
            let args = argItems.compactMap { item -> String? in
                if case .plString(let s) = item { return s }
                return nil
            }
            map[sourceFilePath] = args
            if case .plString(let moduleName)? = info["swiftASTModuleName"] {
                moduleNames.insert(moduleName)
            }
        }
        return (map, moduleNames)
    }

    /// Pure: builds the arena's own paths as subpaths of `derivedDataPath` -- deliberately takes
    /// that path as a parameter rather than computing it, so this can never independently diverge
    /// from `PrivateDerivedDataLocator`'s own computation, the exact same value already threaded to
    /// `LiveXcodeCompilerArgumentsProvider`/`SwiftIsolationMap.build`. Mirrors the real on-disk
    /// layout a `-derivedDataPath`-driven `xcodebuild` build already produces
    /// (`Build/Products`/`Build/Intermediates.noindex`/`Index.noindex/DataStore`).
    static func arenaInfo(derivedDataPath: URL) -> SWBArenaInfo {
        let root = derivedDataPath.path
        return SWBArenaInfo(
            derivedDataPath: root,
            buildProductsPath: root + "/Build/Products",
            buildIntermediatesPath: root + "/Build/Intermediates.noindex",
            pchPath: root + "/Build/Intermediates.noindex/PrecompiledHeaders",
            indexRegularBuildProductsPath: nil,
            indexRegularBuildIntermediatesPath: nil,
            indexPCHPath: root + "/Build/Intermediates.noindex/PrecompiledHeaders",
            indexDataStoreFolderPath: root + "/Index.noindex/DataStore",
            indexEnableDataStore: true
        )
    }

    private static func simulatorSDKVersion() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "iphonesimulator", "--show-sdk-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty else {
            throw CompilerArgumentsError.buildLogParseFailed(reason: "could not determine iphonesimulator SDK version")
        }
        return version
    }
}

private struct SwiftBuildIndexingDelegate: SWBIndexingDelegate {
    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs {
        SWBProvisioningTaskInputs()
    }

    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String: String]) async throws -> SWBExternalToolResult {
        .deferred
    }
}
