import Foundation
import SwiftBuild

func writeStderr(_ message: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((message + terminator).utf8))
}

/// The main `CompilerArgumentsProviding` conformer for Xcode projects (promoted from EXPERIMENTAL
/// once docs/task-swift-build-prepare-for-indexing-spike.md's Steps 13-26 real-corpus-verified it
/// end to end on WordPress-iOS). The `xcodebuild -verbose`-based conformer it superseded
/// (`LiveXcodeCompilerArgumentsProvider`) was kept for a while afterward as an unreachable-from-
/// any-CLI-flag fallback, then removed from the tree entirely.
///
/// Real per-file `swiftc` compiler arguments obtained by talking to `SWBBuildService` directly via
/// the open-source `SwiftBuild` Swift API (`swiftlang/swift-build`), bypassing `xcodebuild`'s CLI
/// entirely. Exists because `xcodebuild -showBuildSettingsForIndex` was proven
/// (docs/task-xcodebuild-show-build-settings-for-index-spike.md Step 6a) to silently discard
/// `-destination`/`-sdk` and default to device for at least one real project, while the
/// open-source engine underneath it is destination-faithful when driven directly -- confirmed end
/// -to-end against a real ~2200-file corpus, byte-for-byte edge parity with the honest clean-
/// rebuild path, ~35% faster (docs/task-swift-build-prepare-for-indexing-spike.md Step 10). A
/// second, independent real-corpus run (WordPress-iOS, Steps 13-26) found and fixed the one real
/// bug in the *honest* path's own compiler-args resolution that this path never had (Step 25); once
/// fixed, the two paths' remaining divergence was 14 edges out of 834, a separately-confirmed non-
/// bug shape (Step 26).
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
    private let processRunning: ProcessRunning

    private let lock = NSLock()
    private var cachedArguments: [String: [String]]?
    private var cachedModuleNames: Set<String> = []
    private var cachedError: Error?

    public init(
        container: ProjectContainer,
        scheme: String,
        derivedDataPath: URL,
        locator: SWBBuildServiceLocating = LiveSWBBuildServiceLocator(),
        processRunning: ProcessRunning = LiveProcessRunner()
    ) {
        self.container = container
        self.scheme = scheme
        self.derivedDataPath = derivedDataPath
        self.locator = locator
        self.processRunning = processRunning
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
            // Every caller of `compilerArguments(forFile:)`/`realModuleNames()` swallows failures
            // per-file via `try?` -- confirmed the hard way (a real Swiftfin run, scheme/target
            // name mismatch, see the guard removed above) that a total provider failure was
            // otherwise completely silent: every file simply came back `argumentsNotFound`, with
            // zero indication *why*, degrading straight to `Target platform: unknown` and 0 live-
            // fallback resolutions with no diagnostic anywhere. Surfaced once here, unconditionally
            // (not gated behind `--verbose`): a plain hang/degraded-silently moment is exactly what
            // erodes trust once results come back thin.
            writeStderr("SwiftBuild direct: compiler-argument resolution failed entirely: \(error)")
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

    /// `session.loadWorkspace(containerPath:)` cannot be used for a real, on-disk `.xcodeproj`/
    /// `.xcworkspace` -- confirmed by reading `swift-build`'s own server-side handler
    /// (`SetSessionWorkspaceContainerPathRequest`'s `PIFProvidingRequest` conformance, `Sources/
    /// SWBBuildService/Messages.swift`): for that container type (as opposed to a `.json`/`.pif`
    /// file), it internally shells out to `xcrun xcodebuild -dumpPIF <tmp> -project/-workspace
    /// <path>` with **no `-derivedDataPath` at all**, hardcoded, with no client-facing parameter to
    /// override it -- confirmed the hard way as the real cause of a persistent
    /// `~/Library/Developer/Xcode/DerivedData` leak (real `SourcePackages`/`Build`/`Logs` content)
    /// that survived fixing every one of *this* project's own 6 `xcodebuild` call sites first, on a
    /// real second, SPM-heavy corpus (Swiftfin) -- the leak is `SWBBuildService`'s own internal
    /// behavior for this one API path, not anything reachable from this provider's own arguments.
    ///
    /// Real workaround, not a guess: run the *exact same* `-dumpPIF` invocation ourselves, with our
    /// own explicit `-scheme`/`-derivedDataPath` (confirmed empirically that `-dumpPIF` requires
    /// `-scheme` whenever `-derivedDataPath` is given -- `xcodebuild` itself rejects the combination
    /// otherwise), then hand the resulting PIF JSON to `session.sendPIF(_:)` directly -- a real,
    /// public, documented alternative to `loadWorkspace(containerPath:)` for exactly this case.
    /// Confirmed directly: packages resolve into *this* private path afterward, zero new shared-
    /// DerivedData content.
    private func loadWorkspace(session: SWBBuildServiceSession, containerPath: String, containerArgument: String) async throws {
        let pifPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-isolation-map-pif-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: pifPath) }

        let result = try processRunning.run(
            executable: "xcodebuild",
            arguments: [
                "-dumpPIF", pifPath.path, containerArgument, containerPath,
                "-scheme", scheme, "-derivedDataPath", derivedDataPath.path
            ],
            workingDirectory: nil
        )
        guard result.exitCode == 0 else {
            throw CompilerArgumentsError.buildLogParseFailed(
                reason: "xcodebuild -dumpPIF exited \(result.exitCode): \(result.standardError)"
            )
        }

        let pifData = try Data(contentsOf: pifPath)
        let jsonObject = try JSONSerialization.jsonObject(with: pifData)
        let pifItem = try SWBPropertyListItem(unsafePropertyList: jsonObject)
        try await session.sendPIF(pifItem)
    }

    private func runAsync() async throws -> [String: [String]] {
        let bundleURL = try locator.serviceBundleURL()
        let service = try await SWBBuildService(serviceBundleURL: bundleURL)
        defer { Task { await service.close() } }

        let (sessionResult, _) = await service.createSession(name: "swift-isolation-map", cachePath: nil, inferiorProductsPath: nil, environment: nil)
        let session = try sessionResult.get()

        let containerPath: String
        let containerArgument: String
        switch container {
        case .xcodeproj(let url):
            containerPath = url.path
            containerArgument = "-project"
        case .xcworkspace(let url):
            containerPath = url.path
            containerArgument = "-workspace"
        case .swiftPackage:
            preconditionFailure("SwiftBuildCompilerArgumentsProvider is only valid for .xcodeproj/.xcworkspace containers")
        }
        try await loadWorkspace(session: session, containerPath: containerPath, containerArgument: containerArgument)

        let workspaceInfo = try await session.workspaceInfo()
        // Deliberately no "does some target's name match the scheme name" guard here -- confirmed
        // wrong the hard way (a real second-corpus run, Swiftfin: scheme `Swiftfin` builds targets
        // named `Swiftfin iOS`/`Swiftfin tvOS`, neither an exact case-insensitive match). A scheme's
        // own name routinely differs from every target name it builds (platform-suffixed variants,
        // umbrella schemes, renamed targets) -- there is no reliable string relationship to check.
        // Harmless to skip: every target in the workspace gets queried below regardless of `scheme`,
        // so this check never gated which targets were actually resolved, only whether the whole
        // provider aborted before trying -- pure false-negative risk, no real safety value.

        let sdkVersion = try Self.simulatorSDKVersion()
        var params = SWBBuildParameters()
        // `"indexbuild"`, not `"build"` -- confirmed the hard way against a real second corpus
        // (Swiftfin): with `action = "build"`, `generateIndexingFileSettings` failed outright for
        // both of that project's own real app targets (`Swiftfin iOS`/`Swiftfin tvOS`) with
        // `unable to get target build graph` -- `TargetBuildGraph` construction itself errored,
        // silently (`SWBBuildService`'s own error response carries no diagnostic detail for this
        // path), while every other, smaller dependency target happened to succeed regardless.
        // `"indexbuild"` is the dedicated action name for exactly this API (confirmed in
        // `swift-build`'s own test suite, `ArenaIndexingInfoTests.swift`'s real fixture setup) --
        // switching to it made both real app targets resolve correctly (707/1182 real files each,
        // `SwiftfinApp.swift` present and correctly per-platform-pathed in both). Project Iris never
        // surfaced this because its own single real app target happened to succeed under `"build"`
        // regardless -- a second, structurally different real corpus is what caught it.
        params.action = "indexbuild"
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
        // Same code-signing bypass `xcodeIndexingBuildSettings` already applies to every real
        // `xcodebuild` invocation this tool makes -- kept here too, defensively, even though
        // `"indexbuild"` alone was sufficient to fix the real Swiftfin failure: a real signed app
        // target with entitlements/capabilities this project's own Project Iris/Swiftfin corpora
        // don't happen to exercise could plausibly still need it.
        var overrides = SWBSettingsTable()
        overrides.set(value: "YES", for: "COMPILER_INDEX_STORE_ENABLE")
        overrides.set(value: "NO", for: "CODE_SIGNING_ALLOWED")
        overrides.set(value: "NO", for: "CODE_SIGNING_REQUIRED")
        params.overrides.commandLine = overrides

        let delegate = SwiftBuildIndexingDelegate()
        // Every target's response for a given file is kept (not just the first one seen) --
        // `preferredArguments` below needs every candidate to pick the file's real home target
        // when more than one target compiles the same file, a real WordPress-iOS shape (see that
        // function's own doc comment).
        var candidatesByPath: [String: [(targetName: String, args: [String])]] = [:]
        var moduleNames: Set<String> = []
        var succeededTargetCount = 0
        // (targetName, error description) for every target `generateIndexingFileSettings` itself
        // rejected -- docs/task-swift-build-prepare-for-indexing-spike.md Step 13: most of these
        // are real and expected (see the `catch` block's own comment), but a *specific* target's
        // failure is exactly the signal needed to confirm or rule out that step's own open
        // hypothesis (a shared file's "home" target failing this query on a given run, silently
        // handing `preferredArguments` a single wrong-target fallback candidate instead of the
        // expected match). Collected, not logged per-target inline, so the summary line below stays
        // one line regardless of how many of the workspace's targets this hits.
        var failedTargets: [(name: String, reason: String)] = []
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
                failedTargets.append((targetInfo.targetName, String(describing: error)))
                continue
            }
            succeededTargetCount += 1
            let (targetMap, targetModuleNames) = Self.parseIndexingFileSettings(settings.sourceFileBuildInfos)
            // `generateIndexingFileSettings` doesn't actually honor `activeRunDestination` for a
            // target whose own `SUPPORTED_PLATFORMS` doesn't include it -- confirmed the hard way
            // against a real second corpus (Swiftfin, which has both an iOS and a tvOS app target):
            // forcing `platform: "iphonesimulator"` on the tvOS target didn't error, it silently
            // returned that target's own real, natively-appropriate `AppleTVSimulator` args instead
            // (`-target x86_64-apple-tvos26.1-simulator`, `-sdk .../AppleTVSimulator26.4.sdk`) --
            // correct for *that* target in isolation, but useless here, since this provider's own
            // private DerivedData only ever has a `Debug-iphonesimulator` build (this tool's own
            // single-platform design, matching `resolveDeterministicSimulatorDestination`), so
            // those args reference `GeneratedModuleMaps-appletvsimulator`/`Debug-appletvsimulator`
            // paths that were never built here at all. Filtering by the args' own real `-sdk` value
            // (not by target/product-type metadata, which would need its own separate query) keeps
            // exactly the files this DerivedData can actually answer for.
            for (path, args) in targetMap where Self.matchesSimulatorPlatform(args) {
                candidatesByPath[path, default: []].append((targetInfo.targetName, args))
            }
            moduleNames.formUnion(targetModuleNames)
        }
        try await session.close()

        var map: [String: [String]] = [:]
        map.reserveCapacity(candidatesByPath.count)
        for (path, candidates) in candidatesByPath {
            map[path] = Self.preferredArguments(candidates: candidates, filePath: path)
        }

        writeStderr(
            "SwiftBuild direct: resolved compiler arguments for \(map.count) file(s) across "
                + "\(succeededTargetCount)/\(workspaceInfo.targetInfos.count) target(s)"
        )
        if !failedTargets.isEmpty {
            writeStderr(
                "SwiftBuild direct: \(failedTargets.count) target(s) failed generateIndexingFileSettings "
                    + "(skipped, likely not buildable under this destination): "
                    + failedTargets.map(\.name).sorted().joined(separator: ", ")
            )
        }
        cachedModuleNames = moduleNames
        return map
    }

    /// Pure: true when `args`' own real `-sdk` value is an iOS Simulator SDK -- see the real call
    /// site's own comment for why this check exists (a platform-incompatible target silently
    /// returns its own native platform's args instead of erroring). Checks the args' own `-sdk`
    /// value, not target/product-type metadata, so it stays correct regardless of *why* a
    /// particular target's response didn't match (a tvOS/macOS/watchOS app target today, some other
    /// platform-specific target shape tomorrow) without needing to enumerate every case.
    static func matchesSimulatorPlatform(_ args: [String]) -> Bool {
        guard let sdkIndex = args.firstIndex(of: "-sdk"), sdkIndex + 1 < args.count else { return false }
        return args[sdkIndex + 1].lowercased().contains("iphonesimulator")
    }

    /// Pure: picks which target's arguments answer for a file that more than one target compiles --
    /// a real WordPress-iOS shape (docs/task-swift-build-prepare-for-indexing-spike.md UPDATE 7):
    /// `WordPressShareExtension` and `WordPressDraftActionExtension` both compile 14 files that
    /// live under `.../WordPress/WordPressShareExtension/Sources/...` (the second extension reuses
    /// the first's sources via target membership, not its own copy). Before this fix, whichever
    /// target's response the merge loop saw first (an arbitrary `workspaceInfo.targetInfos`
    /// enumeration order, not stable across runs or meaningful) silently won -- confirmed the hard
    /// way against a real full-corpus diff against the honest `-verbose`-log baseline: 100% of a
    /// real 834-edge divergence traced to exactly these 14 files getting `WordPressDraftAction
    /// Extension`'s args (which left the file's own type isolation `unspecified`/`isUnknown`)
    /// instead of `WordPressShareExtension`'s (which resolved it correctly). The file's own real
    /// home target is the one whose name is a path component of the file itself -- `-sdk`/`-target`
    /// carry no such signal, but the file's own on-disk location under a target-named directory
    /// does, and Xcode's own convention (a target's default source directory shares its name) makes
    /// this reliable without needing project-model membership data this API doesn't expose per file.
    /// Falls back to whichever candidate came first (this provider's existing, already-validated
    /// behavior for every corpus but this one) when no candidate's name matches, or more than one
    /// does -- both real, harmless cases: a file living outside any target-named directory, or two
    /// same-named targets in different subprojects.
    static func preferredArguments(candidates: [(targetName: String, args: [String])], filePath: String) -> [String] {
        let pathComponents = Set(filePath.split(separator: "/").map(String.init))
        let matches = candidates.filter { pathComponents.contains($0.targetName) }
        if matches.count == 1 {
            return matches[0].args
        }
        return candidates[0].args
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
    /// `SwiftIsolationMap.build`. Mirrors the real on-disk
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
