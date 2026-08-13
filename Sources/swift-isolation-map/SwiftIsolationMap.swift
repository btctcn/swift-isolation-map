import ArgumentParser
import Foundation
import IndexStoreIntegration
import IsolationCore
import OutputFormat
import ProjectResolution
import SourceKitDIntegration
import SyntaxAnalysis

/// Every status/prompt message in this target goes through here, to stderr -- `--output json`
/// (or any format) needs to be safely pipeable, and a "Building project..." or interactive
/// prompt line interleaved into stdout would corrupt that. Only `writeOutput`'s final
/// `print(text)` (the actual analysis result) writes to stdout.
func eprint(_ message: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((message + terminator).utf8))
}

enum OutputFormatOption: String, ExpressibleByArgument, CaseIterable {
    case mermaid
    case dot
    case json
}

/// `--severity`'s value type is `OutputFormat.RiskLevel` itself (not a parallel CLI-only enum) so
/// there's exactly one definition of what "high/medium/low" mean, shared between the edges the
/// engine actually classifies and the threshold a user filters by. `ExpressibleByArgument` has a
/// free default implementation for any `String`-raw-value `RawRepresentable` type, so this is the
/// entire retroactive conformance; `CaseIterable` is added the same way, only so `--help` can list
/// the valid values.
extension RiskLevel: ExpressibleByArgument {}
extension RiskLevel: CaseIterable {
    public static var allCases: [RiskLevel] { [.low, .medium, .high] }
}

enum SwiftIsolationMapError: Error, CustomStringConvertible {
    case unrecognizedPath(String)
    case indexStoreMissingAfterRebuild
    case schemeResolvedToUnexpectedType

    var description: String {
        switch self {
        case .unrecognizedPath(let path):
            return "'\(path)' is not a .xcodeproj, .xcworkspace, or Package.swift path."
        case .indexStoreMissingAfterRebuild:
            return "Rebuilt the project, but still couldn't locate an index store afterward."
        case .schemeResolvedToUnexpectedType:
            return "Internal error: a resolved scheme had an unexpected type for its container."
        }
    }
}

struct ProcessFailure: Error, CustomStringConvertible {
    let command: String
    let exitCode: Int32
    let standardError: String

    var description: String {
        "\(command) failed (exit \(exitCode)): \(standardError)"
    }
}

/// Carries a value out of the `Task` spawned by `runAsyncBridge` -- `@unchecked Sendable` is safe
/// here specifically because access is serialized by the semaphore itself: the write inside the
/// `Task` always happens-before the `semaphore.signal()` that unblocks the read after
/// `semaphore.wait()` returns, so there is no actual concurrent access to `value`.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

@main
struct SwiftIsolationMap: ParsableCommand {
    static let toolVersion = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "swift-isolation-map",
        abstract: "Static actor isolation and data-race analysis for Swift projects."
    )

    // Defaulted to "" rather than left required so the hidden `--oracle-worker-*` mode below can
    // be parsed without also having to supply a real path/scheme -- a worker never resolves a
    // project at all, it only ever runs live oracle queries handed to it by the root process.
    // `run()` validates both are non-empty itself, in every path except worker mode.
    @Argument(help: "Path to a .xcodeproj, .xcworkspace, or Package.swift")
    var path: String = ""

    @Option(help: "Build scheme (Xcode) or product/target (SPM). Required.")
    var scheme: String = ""

    @Option(help: "Parallelize the external-oracle live-query phase across N worker processes (docs/task-process-tree-optimization.md). Default 1: today's exact sequential behavior.")
    var oracleWorkers: Int = 1

    @Option(help: ArgumentHelp("Internal: run as an oracle worker, reading its assigned queries from this JSON file.", visibility: .hidden))
    var oracleWorkerInput: String?

    @Option(help: ArgumentHelp("Internal: where an oracle worker writes its resolved outcomes as JSON.", visibility: .hidden))
    var oracleWorkerOutput: String?

    @Option(help: ArgumentHelp("Internal: run as a local-declaration-resolution worker, reading its assigned queries from this JSON file.", visibility: .hidden))
    var localDeclarationWorkerInput: String?

    @Option(help: ArgumentHelp("Internal: where a local-declaration-resolution worker writes its resolved outcomes as JSON.", visibility: .hidden))
    var localDeclarationWorkerOutput: String?

    @Option(help: "Explicit path to the index store. If provided, auto-detection is skipped.")
    var indexStorePath: String?

    @Flag(help: "If the index store is missing or stale, build the project without an interactive prompt.")
    var autoBuild: Bool = false

    @Flag(help: "Forces a rebuild, ignoring any existing (even fresh) index store.")
    var forceReindex: Bool = false

    // Off by default deliberately -- unlike `xcodeIndexingBuildSettings`'s other overrides (which
    // remove artificial obstacles this tool's own internal builds never needed, like code signing),
    // `-skipMacroValidation` disables a real Xcode security gate: it lets a project's SPM macro
    // plugins execute arbitrary code during compilation without the interactive trust prompt.
    // Needed for real projects using macro-plugin packages (confirmed against `Swiftfin`, using
    // `swift-case-paths`/`StatefulMacros`) -- without it, every one of this tool's own internal
    // `xcodebuild` invocations (`LiveXcodeCompilerArgumentsProvider`'s live-fallback/cursor-info
    // compiler-args resolution, `--auto-build`'s rebuild) fails with "Macro ... must be enabled
    // before it can be used", silently starving the live-oracle phase (observed: 0 of 6804
    // live-fallback declarations resolved, 8912 unknown external-oracle results) -- never a crash,
    // just silently degraded data, so this is opt-in rather than a default the user never asked for.
    @Flag(help: "Pass -skipMacroValidation to every internal xcodebuild invocation, needed for projects using SPM macro plugins (e.g. swift-case-paths). This bypasses a real Xcode security gate -- only enable it for a project you trust.")
    var skipMacroValidation: Bool = false

    @Option(help: "Output format: mermaid | dot | json")
    var output: OutputFormatOption = .mermaid

    @Option(help: "Only include edges at or above this risk level in the output: low | medium | high. An edge with unresolved/unknown isolation on either side is always included regardless -- filtering to a stricter severity never hides genuine uncertainty. Default: no filtering, everything is included.")
    var severity: RiskLevel?

    @Option(help: "Where to write the result (default: stdout)")
    var outFile: String?

    @Flag(help: "Verbose logging: what was searched, where the index store was found, how many types were processed.")
    var verbose: Bool = false

    func run() throws {
        if let oracleWorkerInput, let oracleWorkerOutput {
            let succeeded = runAsyncBridge { () -> Bool in
                do {
                    try await OracleWorker.run(inputPath: oracleWorkerInput, outputPath: oracleWorkerOutput)
                    return true
                } catch {
                    eprint("Oracle worker failed: \(error)")
                    return false
                }
            }
            if !succeeded { throw ExitCode(1) }
            return
        }
        if let localDeclarationWorkerInput, let localDeclarationWorkerOutput {
            let succeeded = runAsyncBridge { () -> Bool in
                do {
                    try await LocalDeclarationWorker.run(inputPath: localDeclarationWorkerInput, outputPath: localDeclarationWorkerOutput)
                    return true
                } catch {
                    eprint("Local declaration worker failed: \(error)")
                    return false
                }
            }
            if !succeeded { throw ExitCode(1) }
            return
        }
        guard !path.isEmpty, !scheme.isEmpty else {
            throw ValidationError("<path> and --scheme are required.")
        }

        let fileSystem = LiveFileSystem()
        let processRunning = LiveProcessRunner()

        let container = try resolveContainer(fromPath: path)
        let projectRoot = StalenessOrchestration.projectRoot(for: container)

        eprint("Checking prerequisites...")
        let prerequisiteFailures = PrerequisiteChecking.check(
            container: container, processRunning: processRunning,
            toolchainLocator: LiveToolchainLocator(processRunning: processRunning, fileSystem: fileSystem),
            sourceKitDLocator: LiveSourceKitDLocator(processRunning: processRunning, fileSystem: fileSystem)
        )
        guard prerequisiteFailures.isEmpty else {
            eprint("swift-isolation-map can't run in this environment:")
            for failure in prerequisiteFailures {
                eprint("")
                eprint(failure)
            }
            throw ExitCode(2)
        }

        eprint("Resolving project and Swift version...")
        let languageMode = try resolveLanguageMode(container: container, fileSystem: fileSystem, processRunning: processRunning)
        let compilerVersion = try SwiftVersionDetection.compilerVersion(processRunning: processRunning)
        let effectiveVersion = SwiftVersionDetection.effectiveVersion(languageMode: languageMode, compilerVersion: compilerVersion)
        logVerbose("Language mode: \(languageMode); compiler: \(compilerVersion); effective: \(effectiveVersion)")

        // A single read per source file drives both the staleness content-hash and the syntactic
        // extraction -- see StalenessOrchestration.swiftFiles's own doc comment for why this list
        // is reused for both purposes, and FileAnalyzer's for why one read yields both facts.
        // Computed before rule-set resolution too: SE-0466 default-isolation detection below needs
        // at least one real project file to query real compiler args for.
        let sourceFiles = StalenessOrchestration.swiftFiles(under: projectRoot, fileSystem: fileSystem)
        logVerbose("Found \(sourceFiles.count) Swift source file(s) under \(projectRoot.path)")

        let compilerArguments = makeCompilerArgumentsProvider(container: container, processRunning: processRunning, fileSystem: fileSystem)
        let defaultIsolation = detectConfiguredDefaultIsolation(compilerArguments: compilerArguments, sourceFiles: sourceFiles)
        logVerbose("Configured default isolation: \(defaultIsolation)")

        let ruleSet = try resolveRuleSet(forSwiftVersion: effectiveVersion, defaultIsolation: defaultIsolation)
        logVerbose("Rule set: \(type(of: ruleSet))")
        let analyzer = FileAnalyzer(fileSystem: fileSystem)
        var currentHashes: [String: String] = [:]
        var extractionResults: [ExtractionResult] = []
        eprint("Parsing \(sourceFiles.count) Swift source file(s)...")
        for file in sourceFiles {
            let result = try analyzer.analyze(fileAt: file)
            currentHashes[file.path] = result.contentHash
            extractionResults.append(ExtractionResult(
                declarations: result.declarations, protocolGlobalActorNames: result.protocolGlobalActorNames,
                protocolRequirementGlobalActorNames: result.protocolRequirementGlobalActorNames,
                protocolInheritedProtocolNames: result.protocolInheritedProtocolNames,
                globalActorNames: result.globalActorNames, closureLiteralRecords: result.closureLiteralRecords,
                awaitedRanges: result.awaitedRanges
            ))
        }

        let manifestURL = StalenessOrchestration.manifestURL(for: container)
        let manifest = StalenessOrchestration.loadManifest(at: manifestURL, fileSystem: fileSystem)
        let staleness = stalenessStatus(currentHashes: currentHashes, manifest: manifest)

        eprint("Locating index store...")
        let locator = IndexStoreLocator(fileSystem: fileSystem)
        let initialDiscovery: IndexStoreDiscoveryResult = indexStorePath.map { .found(URL(fileURLWithPath: $0)) } ?? locator.locate(for: container)

        let indexStoreURL = try resolveIndexStoreURL(
            container: container,
            initialDiscovery: initialDiscovery,
            staleness: staleness,
            locator: locator,
            processRunning: processRunning
        )
        logVerbose("Using index store at \(indexStoreURL.path)")

        // Switched from IndexStoreDB (`IndexStoreClient`) to a raw `libIndexStore` C-API-backed
        // client (docs/task-raw-indexstore-spike.md, issue #51): a real, structural gap found in
        // `IndexStoreDB.symbolOccurrences(inFilePath:)` -- for a source file shared across
        // multiple compilation targets (a real, confirmed shape on Project Iris: a Common/ file
        // compiled into the main app plus two notification-extension targets), it silently
        // returns occurrences from only *one* compiled variant, dropping the others entirely
        // (measured: 72 of 216 real declarations, 209 of 627 real call sites, for one such file).
        // `RawIndexStoreClient`'s own one-shot full-store scan processes every distinct on-disk
        // record independently and has no such gap -- confirmed via a controlled, same-process,
        // same-moment diff against `IndexStoreClient`. No `databasePath`/LMDB accelerator needed.
        eprint("Linking declarations against the index store...")
        let indexStoreClient = try RawIndexStoreClient(storePath: indexStoreURL.path)
        let linker = DeclarationLinker(indexStore: indexStoreClient)
        // docs/task-indexstore-declaration-completeness.md: a real fraction of a large project's
        // own declarations (803, measured on Project Iris) never resolve via the bulk index's
        // location-based matching under full-project load, though the identical query against the
        // identical index store succeeds for the same file linked in isolation -- traced to
        // `IndexStoreDB` itself, not this project's own linking logic. Same "bulk first, live
        // per-declaration fallback for what bulk missed" shape `resolveExternalIsolation` already
        // uses for compiled dependencies, applied here to the project's own declarations instead.
        let unresolvedPlaceholders = linker.unresolvedPlaceholders(for: extractionResults)
        logVerbose("\(unresolvedPlaceholders.count) declaration(s) unresolved by bulk index linking; attempting live fallback")
        let localFallbackOverrides = runAsyncBridge {
            await resolveLocalDeclarationFallback(
                unresolved: unresolvedPlaceholders, compilerArguments: compilerArguments, processRunning: processRunning, fileSystem: fileSystem
            )
        }
        logVerbose("Live fallback resolved \(localFallbackOverrides.count) of \(unresolvedPlaceholders.count) unresolved declaration(s)")
        let linked = linker.link(extractionResults, usrRewriteMapOverrides: localFallbackOverrides)
        logVerbose("Linked \(linked.declarations.count) declaration(s), \(linked.callGraph.count) call-graph edge(s)")

        eprint("Resolving external isolation (compiled dependencies)...")
        let externalResolution = runAsyncBridge {
            await resolveExternalIsolation(
                linked: linked, container: container, compilerArguments: compilerArguments, processRunning: processRunning, fileSystem: fileSystem,
                oracleWorkers: oracleWorkers
            )
        }
        logVerbose(
            "External oracle: \(externalResolution.backfilledDeclarations.count) resolved, "
                + "\(externalResolution.updatedDeclarations.count) conformance(s) updated, "
                + "\(externalResolution.unknownUSRs.count) unknown"
        )
        var mergedDeclarations = linked.declarations
        for (usr, info) in externalResolution.updatedDeclarations {
            mergedDeclarations[usr] = info
        }
        // A `mergedDeclarations[usr]` entry with no `location` at all has no primary declaration
        // anywhere among the analyzed files (`DeclarationLinker.merged`'s own documented
        // limitation: only an `extension` of that bare name ever contributed to it) -- a phantom,
        // isolation-less placeholder, not a real answer, so a real externally-backfilled isolation
        // must still win over it. See `ExternalIsolationBackfill.collectDeclarationLevelWorkItems`'s
        // own `isGenuinelyResolvedProjectLocalDeclaration` doc comment for the real, reproduced bug
        // (Swiftfin's own `extension UIViewController` in a helper file) this guards against.
        for (usr, info) in externalResolution.backfilledDeclarations where mergedDeclarations[usr]?.location == nil {
            mergedDeclarations[usr] = info
        }

        eprint("Building report...")
        let engine = IsolationInferenceEngine(declarations: mergedDeclarations, callGraph: linked.callGraph, ruleSet: ruleSet)
        let report = AnalysisReportBuilder.build(
            engine: engine,
            swiftVersion: effectiveVersion,
            ruleSetUsed: String(describing: type(of: ruleSet)),
            toolVersion: Self.toolVersion,
            unknownUSRs: externalResolution.unknownUSRs,
            closuresByFile: linked.closuresByFile,
            awaitedRangesByFile: linked.awaitedRangesByFile
        )

        try StalenessOrchestration.writeManifest(StalenessManifest(contentHashesByFilePath: currentHashes), to: manifestURL, fileSystem: fileSystem)
        // The exit-code decision below is based on `report` itself, not the filtered view --
        // `--severity` is a presentation choice for this invocation's output, never a way to
        // change whether the analysis considers the project to have a real high-risk boundary.
        try writeOutput(AnalysisReportBuilder.filtered(report, minimumSeverity: severity))

        throw ExitCode(report.summary.highRiskBoundaries > 0 ? 1 : 0)
    }

    // MARK: - Container / scheme / version resolution

    private func resolveContainer(fromPath path: String) throws -> ProjectContainer {
        let url = URL(fileURLWithPath: path)
        switch url.pathExtension {
        case "xcodeproj": return .xcodeproj(url)
        case "xcworkspace": return .xcworkspace(url)
        default:
            if url.lastPathComponent == "Package.swift" { return .swiftPackage(url) }
            throw SwiftIsolationMapError.unrecognizedPath(path)
        }
    }

    /// Validates `--scheme` against the real project either way (mandatory, no auto-detect
    /// fallback -- architecture spec section 3) and, for SPM, recovers the language mode from the
    /// same `swift package describe` call used for that validation (`SPMResolvedScheme.toolsVersion`).
    /// Xcode has no equivalent already-resolved field (scheme validation and the `SWIFT_VERSION`
    /// build setting come from two different real commands), so it's queried separately.
    private func resolveLanguageMode(container: ProjectContainer, fileSystem: FileSystemQuerying, processRunning: ProcessRunning) throws -> String {
        switch container {
        case .swiftPackage:
            let resolver = SwiftPMSchemeResolver(processRunning: processRunning)
            do {
                guard let spmScheme = try resolver.resolve(named: scheme, in: container) as? SPMResolvedScheme else {
                    throw SwiftIsolationMapError.schemeResolvedToUnexpectedType
                }
                return spmScheme.toolsVersion
            } catch SwiftPMSchemeResolverError.noMatch(let requested, let available) {
                reportSchemeMismatch(requested: requested, available: available)
                throw ExitCode(2)
            }
        case .xcodeproj, .xcworkspace:
            let resolver = XcodeSchemeResolver(fileSystem: fileSystem)
            do {
                _ = try resolver.resolve(named: scheme, in: container)
            } catch XcodeSchemeResolverError.noMatch(let requested, let available) {
                reportSchemeMismatch(requested: requested, available: available)
                throw ExitCode(2)
            }
            return try SwiftVersionDetection.xcodeLanguageMode(container: container, schemeName: scheme, processRunning: processRunning)
        }
    }

    private func reportSchemeMismatch(requested: String, available: [String]) {
        eprint(schemeMismatchMessage(requested: requested, available: available))
    }

    private func resolveRuleSet(forSwiftVersion version: String, defaultIsolation: IsolationKind) throws -> IsolationRuleSet {
        do {
            return try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: version, defaultIsolation: defaultIsolation)
        } catch let error as UnsupportedSwiftVersionError {
            var message = "swift-isolation-map doesn't support Swift \(error.version) yet."
            if let highest = error.highestSupportedUpperBound {
                message += " Highest supported version: \(highest)."
            }
            eprint(message)
            throw ExitCode(2)
        }
    }

    /// One `CompilerArgumentsProviding`, constructed once and shared by both the SE-0466
    /// default-isolation detection below and `resolveExternalIsolation`'s live oracle fallback --
    /// construction itself is cheap (no build runs yet), and the real `swift build -v`/
    /// `xcodebuild -verbose` invocation it eventually triggers is cached for the provider's
    /// lifetime (see `LiveSwiftPMCompilerArgumentsProvider`'s own doc comment), so sharing one
    /// instance means that real build runs at most once per invocation, not once per consumer.
    private func makeCompilerArgumentsProvider(
        container: ProjectContainer, processRunning: ProcessRunning, fileSystem: FileSystemQuerying
    ) -> CompilerArgumentsProviding {
        switch container {
        case .swiftPackage(let packageURL):
            return LiveSwiftPMCompilerArgumentsProvider(
                packageDirectory: packageURL.deletingLastPathComponent(), processRunning: processRunning
            )
        case .xcodeproj, .xcworkspace:
            return LiveXcodeCompilerArgumentsProvider(
                container: container, scheme: scheme, processRunning: processRunning, fileSystem: fileSystem,
                skipMacroValidation: skipMacroValidation
            )
        }
    }

    /// SE-0466: a module opts into `@MainActor`-by-default only via a real, explicit
    /// `-default-isolation MainActor` compiler flag (confirmed against `swiftc --help-hidden`:
    /// `-default-isolation MainActor|nonisolated`, defaults to `nonisolated`) -- never inferred
    /// just from targeting Swift 6.2+. Reads the flag from the *real* compiler arguments of the
    /// first genuine target-source file `compilerArguments` can resolve (the flag is per-target,
    /// not per-file, so any one resolvable target file reflects the whole target's setting).
    /// `Package.swift` itself is deliberately skipped even though `StalenessOrchestration.swiftFiles`
    /// includes it (it's a real `.swift` file under the project root, syntactically analyzed like
    /// any other) -- confirmed empirically (real `swift build -v` output, first end-to-end run of
    /// this very fix) that SwiftPM compiles the manifest itself as a *separate* `-primary-file`
    /// invocation carrying `-package-description-version`, never `-default-isolation`, which a
    /// naive "first resolvable file" search silently took as authoritative "no flag configured" --
    /// a real, live-caught bug, not a hypothetical: this fix's own first live run against the spike
    /// package printed `nonisolated` instead of the configured `MainActor` for exactly this reason.
    /// Deliberately fail-soft to `.nonisolated` (today's exact prior behavior) if no real target
    /// file resolves or the flag is absent -- matching `resolveExternalIsolation`'s own "don't abort
    /// the whole analysis over one optional enrichment step failing" precedent, since a project
    /// with no `-default-isolation` configured is the common case, not an error.
    private func detectConfiguredDefaultIsolation(
        compilerArguments: CompilerArgumentsProviding, sourceFiles: [URL]
    ) -> IsolationKind {
        for file in sourceFiles where file.lastPathComponent != "Package.swift" {
            guard let args = try? compilerArguments.compilerArguments(forFile: file.path) else { continue }
            guard let flagIndex = args.firstIndex(of: "-default-isolation"), args.indices.contains(flagIndex + 1) else {
                return .nonisolated
            }
            return args[flagIndex + 1] == "MainActor" ? .globalActor(name: "MainActor") : .nonisolated
        }
        return .nonisolated
    }

    // MARK: - Index store resolution (locate / prompt / build / stop)

    private func resolveIndexStoreURL(
        container: ProjectContainer,
        initialDiscovery: IndexStoreDiscoveryResult,
        staleness: StalenessStatus,
        locator: IndexStoreLocator,
        processRunning: ProcessRunning
    ) throws -> URL {
        let decision = decideIndexAction(storeDiscovery: initialDiscovery, stalenessStatus: staleness, autoBuild: autoBuild, forceReindex: forceReindex)
        switch decision {
        case .proceed:
            guard case .found(let url) = initialDiscovery else { throw SwiftIsolationMapError.indexStoreMissingAfterRebuild }
            return url

        case .hardStop(let changedFiles):
            var message = "Index store is stale: \(changedFiles.count) file(s) changed since the last indexing:\n"
            message += changedFiles.map { "    - \($0)" }.joined(separator: "\n")
            message += "\nRe-run with --auto-build or --force-reindex, or rebuild the project yourself."
            eprint(message)
            throw ExitCode(1)

        case .rebuildThenProceed:
            eprint("Building project to generate a fresh index store...")
            return try build(container: container, locator: locator, processRunning: processRunning)

        case .promptUser:
            return try promptForIndexStore(discovery: initialDiscovery, container: container, locator: locator, processRunning: processRunning)
        }
    }

    /// Architecture spec section 2.6's interactive prompt -- reached without `--auto-build`/
    /// `--force-reindex` in two distinct situations `decideIndexAction` deliberately treats the
    /// same way (never an implicit "assume fresh"), but which need different wording since only
    /// one of them is actually missing on disk:
    /// - `.missing`: no index store found at all.
    /// - `.found` + `.noManifest`: a store exists (e.g. built by a plain `swift build` the user
    ///   ran themselves, outside this tool), but this tool never fingerprinted it and can't vouch
    ///   for it being current -- confirmed to actually happen on this project's own first-ever
    ///   real run against itself (`.build/debug/index/store` already existed from an earlier
    ///   manual `swift build`, with no manifest yet), not just a theoretical case.
    /// A stale (previously-vouched-for, now-changed) store is never routed here at all -- that's
    /// always a hard stop, no "continue anyway" choice.
    private func promptForIndexStore(
        discovery: IndexStoreDiscoveryResult,
        container: ProjectContainer,
        locator: IndexStoreLocator,
        processRunning: ProcessRunning
    ) throws -> URL {
        switch discovery {
        case .missing:
            eprint("Index store not found.")
            eprint("[1] Provide a path manually")
        case .found(let existingURL):
            eprint("An index store was found at \(existingURL.path), but swift-isolation-map has no record of it and can't verify it's up to date.")
            eprint("[1] Use it anyway (skip verification)")
        }
        eprint("[2] Build the project now")
        eprint("[q] Cancel")
        eprint("> ", terminator: "")
        guard let choice = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), !choice.isEmpty else {
            throw ExitCode(2)
        }
        switch choice {
        case "1":
            switch discovery {
            case .found(let existingURL):
                return existingURL
            case .missing:
                eprint("Path to index store: ", terminator: "")
                guard let providedPath = readLine()?.trimmingCharacters(in: .whitespaces), !providedPath.isEmpty else {
                    throw ExitCode(2)
                }
                // A manually-provided path is trusted the same way `--index-store-path` is (auto-
                // detection, and the staleness comparison that only applies to a store this tool
                // itself vouches for, are both skipped) -- there's no manifest for a path the user
                // is pointing at for the first time.
                return URL(fileURLWithPath: providedPath)
            }
        case "2":
            return try build(container: container, locator: locator, processRunning: processRunning)
        default:
            throw ExitCode(2)
        }
    }

    /// Real rebuild invocation -- the one branch that mutates external state. SPM's exact flag
    /// form (`-Xswiftc -index-store-path -Xswiftc <path>`, not the architecture doc's originally
    /// assumed `swift build --index-store-path`, which no longer exists) was verified empirically
    /// in the Phase 0 spike; see docs/priority-2-phase-0-spike.md.
    ///
    /// Xcode's form was *also* wrong as originally assumed from the architecture doc: there is no
    /// `-indexStoreEnable` flag (`xcodebuild -indexStoreEnable YES` fails with "invalid option",
    /// confirmed against a real project, Xcode 26.4.0) -- indexing-while-building is controlled
    /// by the build setting `COMPILER_INDEX_STORE_ENABLE` (confirmed present, value `Default`, in
    /// real `xcodebuild -showBuildSettings` output), passed the same way any other build setting
    /// override is: a bare `KEY=VALUE` argument, not a `-flag`.
    private func build(container: ProjectContainer, locator: IndexStoreLocator, processRunning: ProcessRunning) throws -> URL {
        switch container {
        case .swiftPackage(let packageURL):
            let packageDirectory = packageURL.deletingLastPathComponent()
            let storePath = locator.explicitIndexStorePath(for: packageDirectory)
            let result = try processRunning.run(
                executable: "swift",
                arguments: ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", storePath.path],
                workingDirectory: packageDirectory
            )
            guard result.exitCode == 0 else {
                throw ProcessFailure(command: "swift build", exitCode: result.exitCode, standardError: result.standardError)
            }
            return storePath

        case .xcodeproj, .xcworkspace:
            var arguments: [String] = []
            if skipMacroValidation {
                arguments.append("-skipMacroValidation")
            }
            arguments += ["-scheme", scheme]
            switch container {
            case .xcodeproj(let url): arguments += ["-project", url.path]
            case .xcworkspace(let url): arguments += ["-workspace", url.path]
            case .swiftPackage: break
            }
            // Shared with `LiveXcodeCompilerArgumentsProvider.runVerboseBuild` -- see
            // `xcodeIndexingBuildSettings`'s own doc comment for why each setting is here (in
            // particular, why code signing must be disabled), and
            // `resolveDeterministicSimulatorDestination`'s for why the destination itself must
            // also be pinned down explicitly.
            if let destination = resolveDeterministicSimulatorDestination(container: container, scheme: scheme, processRunning: processRunning) {
                arguments += ["-destination", destination]
            }
            arguments += xcodeIndexingBuildSettings + ["build"]
            let result = try processRunning.run(executable: "xcodebuild", arguments: arguments, workingDirectory: nil)
            guard result.exitCode == 0 else {
                throw ProcessFailure(command: "xcodebuild", exitCode: result.exitCode, standardError: result.standardError)
            }
            guard case .found(let url) = locator.locate(for: container) else {
                throw SwiftIsolationMapError.indexStoreMissingAfterRebuild
            }
            return url
        }
    }

    // MARK: - Sync/async bridge
    //
    // `SwiftIsolationMap` stays a plain, synchronous `ParsableCommand` deliberately, not
    // `AsyncParsableCommand` -- switching it (needed to `await` `ExternalIsolationBackfill`,
    // an `actor`-based API) caused the built test bundle to invoke this CLI's own `@main` entry
    // point as part of the *test process itself* (`swift test` failed immediately with this
    // tool's own "Missing expected argument '--scheme'" usage error, before running a single real
    // test) -- a real toolchain interaction between `@main`-on-`AsyncParsableCommand` and a test
    // target linking the same executable target, not something worth taking on for one call site.
    // A one-shot blocking bridge is the standard, safe pattern instead: the spawned `Task` runs on
    // the default global executor's own thread pool, distinct from the thread blocking on the
    // semaphore, so this does not deadlock.
    private func runAsyncBridge<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    // MARK: - Local declaration completeness fallback (docs/task-indexstore-declaration-completeness.md)

    /// One-off `SourceKitDClient`, separate from `resolveExternalIsolation`'s own -- kept simple
    /// and independent rather than threading a shared client through both call sites, since
    /// construction is a local, in-process `dlopen` + connection setup, not a network round trip.
    /// Skips creating a client at all when there's nothing to resolve (the common case for a
    /// small project, or once bulk linking is fully reliable for a given run). Fail-soft, same
    /// precedent as `resolveExternalIsolation`: sourcekitd unavailable, or any individual query
    /// failing, just means those declarations stay unresolved -- never a crash, never a silently
    /// wrong answer.
    private func resolveLocalDeclarationFallback(
        unresolved: [(placeholder: String, location: SymbolLocation)],
        compilerArguments: CompilerArgumentsProviding,
        processRunning: ProcessRunning,
        fileSystem: FileSystemQuerying
    ) async -> [String: String] {
        guard !unresolved.isEmpty else { return [:] }
        let sourceKitD: SourceKitDClient
        do {
            sourceKitD = try SourceKitDClient()
        } catch {
            eprint("Warning: sourcekitd unavailable (\(error)) -- local declaration completeness fallback will not run this run.")
            return [:]
        }
        // Same worker-count knob and executable-relaunch pattern as `resolveExternalIsolation`'s
        // own oracle-worker dispatch below -- 10954 unresolved placeholders measured on a real run
        // against Project Iris made the plain sequential path (confirmed by a real timed run:
        // over 15 minutes and still going) impractical for a tool meant to run on every invocation,
        // not just once.
        return await LocalDeclarationLiveFallback.resolveInParallel(
            unresolved: unresolved, workerCount: oracleWorkers, compilerArguments: compilerArguments,
            workerExecutablePath: oracleWorkers > 1 ? URL(fileURLWithPath: CommandLine.arguments[0]).path : nil,
            processRunning: processRunning, fileSystem: fileSystem, sourceKitD: sourceKitD
        )
    }

    // MARK: - External isolation (compiled-dependency oracle)

    /// Resolves every USR the analyzed project references but doesn't declare itself (external
    /// superclasses/protocols/call targets in compiled dependencies) via `sourcekitd`, per
    /// docs/task-compiled-dependency-isolation.md. Deliberately fail-soft end to end: if the
    /// toolchain has no `sourcekitdInProc` at all, or the compiler-arguments provider itself can't
    /// be constructed, this returns an empty resolution (today's exact prior behavior) rather than
    /// aborting the whole analysis over one optional enrichment step failing.
    private func resolveExternalIsolation(
        linked: LinkedAnalysis,
        container: ProjectContainer,
        compilerArguments: CompilerArgumentsProviding,
        processRunning: ProcessRunning,
        fileSystem: FileSystemQuerying,
        oracleWorkers: Int
    ) async -> ExternalIsolationResolution {
        let empty = ExternalIsolationResolution(backfilledDeclarations: [:], updatedDeclarations: [:], unknownUSRs: [])

        let environmentProvider: BulkExtractionEnvironmentProviding
        switch container {
        case .swiftPackage(let packageURL):
            let packageDirectory = packageURL.deletingLastPathComponent()
            environmentProvider = SwiftPMBulkExtractionEnvironmentProvider(
                packageDirectory: packageDirectory, processRunning: processRunning, fileSystem: fileSystem
            )
        case .xcodeproj, .xcworkspace:
            environmentProvider = LiveXcodeBulkExtractionEnvironmentProvider(
                container: container, scheme: scheme, processRunning: processRunning, fileSystem: fileSystem
            )
        }

        let sourceKitD: SourceKitDClient
        do {
            sourceKitD = try SourceKitDClient()
        } catch {
            eprint("Warning: sourcekitd unavailable (\(error)) -- compiled-dependency isolation will not be resolved this run.")
            return empty
        }

        // Permanent, opt-in diagnostic (docs/hypothesis-0-file-sorted-oracle-queries.md; full
        // decision record in docs/task-oracle-query-concurrency.md's §7) -- originally added for
        // one measurement (deciding whether hypothesis 0's file-sorted ordering was worth
        // implementing at all; it was), but kept: before/after
        // `source.request.statistics` snapshots around the oracle phase remain the cheapest way to
        // directly verify hypothesis 0's own AST-cache-locality acceptance criterion (`num-ast-
        // builds` should track the merged plan's distinct live-query file-group count, not the
        // query count) on any future run, e.g. after a further change to query ordering or
        // dedup. Hooked here, not inside `ExternalIsolationBackfill`, specifically to avoid adding
        // `requestStatistics()` to the `SourceKitDQuerying` protocol (which every fake/test double
        // would then need to implement) for what stays a diagnostic, never load-bearing for a
        // normal run's own output.
        let statsEnabled = ProcessInfo.processInfo.environment["SWIFT_ISOLATION_MAP_ORACLE_STATS"] != nil
        let before = statsEnabled ? try? await sourceKitD.requestStatistics() : nil
        if let before {
            eprint("=== oracle-phase statistics: BEFORE ===")
            for (kind, value) in before.byKind.sorted(by: { $0.key < $1.key }) {
                eprint("\(kind): \(value)")
            }
        }

        let result = await ExternalIsolationBackfill.resolve(
            linked: linked, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem,
            processRunning: processRunning, environmentProvider: environmentProvider,
            oracleWorkerCount: oracleWorkers,
            oracleWorkerExecutablePath: oracleWorkers > 1 ? URL(fileURLWithPath: CommandLine.arguments[0]).path : nil
        )

        if statsEnabled, let before {
            if let after = try? await sourceKitD.requestStatistics() {
                eprint("=== oracle-phase statistics: AFTER ===")
                for (kind, value) in after.byKind.sorted(by: { $0.key < $1.key }) {
                    eprint("\(kind): \(value)")
                }
                eprint("=== oracle-phase statistics: DELTA (after - before) ===")
                for kind in Set(before.byKind.keys).union(after.byKind.keys).sorted() {
                    let delta = (after.byKind[kind] ?? 0) - (before.byKind[kind] ?? 0)
                    eprint("\(kind): \(delta)")
                }
            }
        }

        return result
    }

    // MARK: - Output

    private func writeOutput(_ report: AnalysisReport) throws {
        let text: String
        switch output {
        case .mermaid:
            text = MermaidWriter.write(report)
        case .dot:
            text = DotWriter.write(report)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            text = String(data: try encoder.encode(report), encoding: .utf8) ?? ""
        }
        if let outFile {
            try text.write(toFile: outFile, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }

    private func logVerbose(_ message: String) {
        guard verbose else { return }
        eprint("[verbose] " + message)
    }

}
