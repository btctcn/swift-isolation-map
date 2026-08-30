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

extension EdgeSortOption: ExpressibleByArgument {}
extension EdgeSortOption: CaseIterable {
    public static var allCases: [EdgeSortOption] { [.file, .severity] }
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
    /// `xcodebuild`'s own real diagnostics (e.g. `xcodebuild: error: Could not resolve package
    /// dependencies: ...`, `** BUILD FAILED **`) are printed to *stdout*, not stderr -- confirmed
    /// directly (a real invocation against a read-only `-derivedDataPath`: the actual permission-
    /// denied reason appeared only in `standardOutput`, `standardError` carried nothing useful for
    /// it). `standardError`-only reporting silently dropped the one thing a user actually needs to
    /// fix a real build failure. Only the *tail* is kept -- a full build log can be many thousands
    /// of lines; the failure reason is reliably near the end, right before the process exits.
    let standardOutput: String

    private static let tailCharacterLimit = 4000

    var description: String {
        let trimmedOutput = standardOutput.suffix(Self.tailCharacterLimit)
        var message = "\(command) failed (exit \(exitCode))"
        if !trimmedOutput.isEmpty {
            message += ":\n\(trimmedOutput)"
        }
        let trimmedError = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedError.isEmpty {
            message += "\nstderr: \(trimmedError)"
        }
        return message
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
    static let toolVersion = "0.2.1"

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

    @Flag(help: "If the index store is missing or stale, build the project without an interactive prompt.")
    var autoBuild: Bool = false

    @Flag(help: "Forces a rebuild, ignoring any existing (even fresh) index store.")
    var forceReindex: Bool = false

    // Off by default (docs/task-private-derived-data-hypothesis.md): for Xcode projects, this tool
    // always builds into its own private, composite-keyed `-derivedDataPath` (never shared with
    // Xcode GUI/CI/anything else) instead of Xcode's own shared DerivedData -- a real-corpus spike
    // on Project Iris confirmed that store has *zero* cross-scheme pollution by construction, so
    // scoping the raw index-store scan by module name/`is_system_unit` is no longer needed there.
    // Removing the former `--index-store-path` escape hatch (a caller pointing this tool at some
    // other, shared/foreign store) closed the one remaining scenario this flag existed for, and
    // removed a real correctness risk of its own: that override only ever redirected *where this
    // run reads its index data from*, never where the *separate* compiler-argument-resolution
    // build (always private now, unconditionally) writes its own build products -- the two could
    // silently diverge (different code state, different real modules) if pointed at different
    // places. Kept, still off by default, purely as a defensive escape hatch for a degenerate case
    // this design doesn't fully rule out (e.g. Xcode's own "Custom Derived Data Location"
    // preference happening to be pointed at the identical private path). Not experimental -- this
    // is a deliberate, permanent fallback, not something still being evaluated.
    @Flag(help: "Re-enable index-store module-name/is_system_unit scoping (allowedModuleNames) of the raw index-store scan. Off by default -- this tool's own private, per-(project, scheme, destination) index store never accumulates unrelated targets' units in the first place. A defensive fallback for a narrow, unlikely scenario -- see this flag's own doc comment.")
    var indexStoreModuleFilter: Bool = false


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

    @Option(help: "Sort edges in the output: file (by location.file, then line) | severity (high first). Default: whatever order the analysis produced them in.")
    var sort: EdgeSortOption?

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

        // Bootstrap-only private path, computed before anything else: every real `xcodebuild`
        // invocation this run makes must stay contained to this tool's own private DerivedData,
        // never Xcode's shared one (docs/task-private-derived-data-hypothesis.md) -- but the real,
        // *final* composite-keyed path (below) isn't known until `resolveDeterministicSimulator
        // Destination` itself returns, and that call is itself an `xcodebuild` invocation. `nil`
        // destination still resolves to a real, private, never-shared location (a fixed "unknown-
        // destination" path segment), just not the final one -- used for every `xcodebuild` call
        // this early, including `resolveLanguageMode`'s own (confirmed the hard way as a real,
        // missed leak: `SwiftVersionDetection.xcodeLanguageMode` is the very *first* `xcodebuild`
        // call in the whole pipeline, and kept writing into
        // `~/Library/Developer/Xcode/DerivedData` on a real second corpus even after every other
        // call site was fixed first).
        let bootstrapDerivedDataPath: URL? = {
            switch container {
            case .xcodeproj, .xcworkspace: return PrivateDerivedData.path(for: container, scheme: scheme, destination: nil)
            case .swiftPackage: return nil
            }
        }()

        eprint("Resolving project and Swift version...")
        let languageMode = try resolveLanguageMode(
            container: container, fileSystem: fileSystem, processRunning: processRunning, derivedDataPath: bootstrapDerivedDataPath
        )
        let compilerVersion = try SwiftVersionDetection.compilerVersion(processRunning: processRunning)
        let effectiveVersion = SwiftVersionDetection.effectiveVersion(languageMode: languageMode, compilerVersion: compilerVersion)
        logVerbose("Language mode: \(languageMode); compiler: \(compilerVersion); effective: \(effectiveVersion)")

        // Private DerivedData (docs/task-private-derived-data-hypothesis.md, the sole, default
        // behavior for Xcode projects): computed unconditionally for Xcode containers -- every real
        // `xcodebuild` invocation this run makes
        // (both the compiler-argument-resolution build `LiveXcodeCompilerArgumentsProvider` needs
        // for `SyntaxAnalysis`/live-fallback/the external-isolation oracle, and the index-store-
        // populating build below if one turns out to be needed) always targets this same private,
        // composite-keyed location, never Xcode's own shared DerivedData -- a real-corpus spike on
        // Project Iris confirmed that store has zero cross-scheme pollution by construction.
        // `nil` only for SwiftPM, which already has its own private, non-shared index store
        // (`IndexStoreLocator.explicitIndexStorePath`, `.build/swift-isolation-map-index-store`) and
        // never touches `-derivedDataPath` (an Xcode-only flag) at all.
        var privateDerivedDataPath: URL?
        switch container {
        case .xcodeproj, .xcworkspace:
            let destination = resolveDeterministicSimulatorDestination(
                container: container, scheme: scheme, processRunning: processRunning, derivedDataPath: bootstrapDerivedDataPath
            )
            privateDerivedDataPath = PrivateDerivedData.path(for: container, scheme: scheme, destination: destination)
            logVerbose("Using private DerivedData at \(privateDerivedDataPath!.path)")
        case .swiftPackage:
            break
        }

        // A single read per source file drives both the staleness content-hash and the syntactic
        // extraction -- see StalenessOrchestration.swiftFiles's own doc comment for why this list
        // is reused for both purposes, and FileAnalyzer's for why one read yields both facts.
        // Computed before rule-set resolution too: SE-0466 default-isolation detection below needs
        // at least one real project file to query real compiler args for.
        let sourceFiles = StalenessOrchestration.swiftFiles(under: projectRoot, fileSystem: fileSystem)
        logVerbose("Found \(sourceFiles.count) Swift source file(s) under \(projectRoot.path)")

        let compilerArguments = makeCompilerArgumentsProvider(
            container: container, processRunning: processRunning, fileSystem: fileSystem, derivedDataPath: privateDerivedDataPath
        )
        let defaultIsolation = detectConfiguredDefaultIsolation(compilerArguments: compilerArguments, sourceFiles: sourceFiles)
        logVerbose("Configured default isolation: \(defaultIsolation)")
        let targetPlatform = detectTargetPlatform(compilerArguments: compilerArguments, sourceFiles: sourceFiles)
        logVerbose("Target platform: \(targetPlatform)")

        let ruleSet = try resolveRuleSet(forSwiftVersion: effectiveVersion, defaultIsolation: defaultIsolation)
        logVerbose("Rule set: \(type(of: ruleSet))")
        let analyzer = FileAnalyzer(fileSystem: fileSystem)
        var currentHashes: [String: String] = [:]
        var extractionResults: [ExtractionResult] = []
        eprint("Parsing \(sourceFiles.count) Swift source file(s)...")
        for file in sourceFiles {
            // Issue #121: this file's own real, active `#if <name>` custom-condition set, parsed
            // from its own real compiler arguments -- `nil` (permissive, matching `.unknown`
            // platform's own fail-safe direction) when this file's arguments can't be resolved at
            // all (excluded from the analyzed target, a different scheme, etc.), never an empty set
            // masquerading as "confirmed nothing is set."
            let activeCustomConditions = (try? compilerArguments.compilerArguments(forFile: file.path))
                .map { ActiveCustomConditionParsing.parse(fromCompilerArguments: $0) }
            let result = try analyzer.analyze(fileAt: file, platform: targetPlatform, activeCustomConditions: activeCustomConditions)
            currentHashes[file.path] = result.contentHash
            extractionResults.append(ExtractionResult(
                declarations: result.declarations, protocolGlobalActorNames: result.protocolGlobalActorNames,
                protocolRequirementGlobalActorNames: result.protocolRequirementGlobalActorNames,
                protocolInheritedProtocolNames: result.protocolInheritedProtocolNames,
                globalActorNames: result.globalActorNames, closureLiteralRecords: result.closureLiteralRecords,
                awaitedRanges: result.awaitedRanges, preconcurrencyImportedModules: result.preconcurrencyImportedModules
            ))
        }

        // Manifest scoping (docs/task-private-derived-data-hypothesis.md Step 4): a private-
        // DerivedData run's own manifest lives *inside* that same composite-key directory --
        // "what does this specific cache currently vouch for," not project-wide -- rather than the
        // pre-existing single sibling-of-the-project-file manifest, which would otherwise get
        // confused about which (scheme, destination) variant it's actually vouching for the moment
        // more than one is ever analyzed against the same project.
        let manifestURL = privateDerivedDataPath.map { $0.appendingPathComponent(StalenessOrchestration.manifestFileName) }
            ?? StalenessOrchestration.manifestURL(for: container)
        let manifest = StalenessOrchestration.loadManifest(at: manifestURL, fileSystem: fileSystem)
        let staleness = stalenessStatus(currentHashes: currentHashes, manifest: manifest)

        eprint("Locating index store...")
        let locator = IndexStoreLocator(fileSystem: fileSystem)
        let initialDiscovery: IndexStoreDiscoveryResult
        if let privateDerivedDataPath {
            // Known by construction, not searched for -- a private root's own layout is this
            // tool's own choice (`PrivateDerivedData.path`), unlike Xcode's own opaque, hashed
            // shared-DerivedData folder naming that `IndexStoreLocator.locate(for:)` has to search
            // for instead.
            let dataStoreURL = privateDerivedDataPath.appendingPathComponent("Index.noindex/DataStore")
            initialDiscovery = fileSystem.directoryExists(at: dataStoreURL) ? .found(dataStoreURL) : .missing
        } else {
            initialDiscovery = locator.locate(for: container)
        }

        let indexStoreURL = try resolveIndexStoreURL(
            container: container,
            initialDiscovery: initialDiscovery,
            staleness: staleness,
            locator: locator,
            processRunning: processRunning,
            derivedDataPath: privateDerivedDataPath,
            fileSystem: fileSystem
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
        // Scopes the raw scan to exactly the modules this run's own scheme-driven build actually
        // compiled (docs/task-index-store-module-scoping.md) -- `Index.noindex/DataStore` is a
        // single directory shared and accumulated across *every* build Xcode has ever run against
        // *shared* DerivedData, real, confirmed on Project Iris: an unrelated build (Xcode GUI, CI,
        // a different tool invocation) that once compiled the `lsboutiqueTests` (XCTest) target left
        // real, indexed records behind, even though the analyzed scheme's own `.xcscheme` declares
        // an empty `<Testables>` list and never compiles that target itself.
        //
        // Off by default (`--index-store-module-filter`, docs/task-private-derived-data-
        // hypothesis.md): the private, composite-keyed DerivedData computed above already has
        // zero cross-scheme pollution *by construction* -- nothing but this exact (project,
        // scheme, destination) run's own build ever writes into it -- so a real-corpus spike
        // (Project Iris) confirmed this filtering is no longer needed there (unfiltered vs.
        // filtered results landed within edge-level noise of each other, both matching the
        // historical known-good baseline). Kept available, opt-in, only as a defensive fallback --
        // see this flag's own declaration for the (narrow, unlikely) remaining scenario it still
        // guards against.
        let allowedModuleNames = indexStoreModuleFilter ? compilerArguments.realModuleNames() : nil
        if let allowedModuleNames {
            logVerbose("Scoping index store to \(allowedModuleNames.count) real module(s) from this run's own build: \(allowedModuleNames.sorted().joined(separator: ", "))")
        }

        eprint("Linking declarations against the index store...")
        let indexStoreClient = try RawIndexStoreClient(storePath: indexStoreURL.path, allowedModuleNames: allowedModuleNames)
        if indexStoreClient.skippedUnitCount > 0 {
            logVerbose("Skipped \(indexStoreClient.skippedUnitCount) index store unit(s) outside the analyzed scheme's own real module set")
        }
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

        // Issue #40: a real `@globalActor` type declared in a *compiled* dependency is invisible
        // to `FileWideNameCollector`'s syntactic scan by construction (it never parses that
        // dependency's source) -- `ClosureIsolationExtractor.classify` (Rule A) and
        // `GlobalActorNameValidation`'s live-oracle checks both only ever trusted that scan's own
        // accept-list, so such a name silently fell through to `.nonisolated` on both sides of a
        // real cross-isolation call, confirmed by a real, compiling minimal repro (not merely
        // theorized -- see the issue's own comment thread). Bulk symbol-graph extraction
        // (`BulkSymbolGraphExtractor`) already runs, unconditionally, once per analysis to prime
        // `ExternalIsolationBackfill`'s isolation cache; it now *also* reports which real types it
        // found declared with a literal `@globalActor` attribute on their own declaration -- an
        // unambiguous compiler signal, not a name-matching guess (see `BulkSymbolGraphResolution
        // .discoveredGlobalActorNames`'s own doc comment). Computed here, before `linker.link(...)`,
        // specifically so `classify()`'s accept-list -- built *inside* `link()` -- benefits too, not
        // just the external-declaration oracle path `resolveExternalIsolation` already covers below;
        // the same `BulkSymbolGraphResolution` is threaded through to `resolveExternalIsolation`
        // afterward so this one-time bulk pass never runs twice.
        let bulkEnvironmentProvider = makeBulkExtractionEnvironmentProvider(
            container: container, scheme: scheme, processRunning: processRunning, fileSystem: fileSystem, derivedDataPath: privateDerivedDataPath
        )
        let bulkResolution = bulkSymbolGraphResolution(environmentProvider: bulkEnvironmentProvider, processRunning: processRunning, fileSystem: fileSystem)
        if !bulkResolution.discoveredGlobalActorNames.isEmpty {
            logVerbose("Discovered \(bulkResolution.discoveredGlobalActorNames.count) real @globalActor name(s) in compiled dependencies: \(bulkResolution.discoveredGlobalActorNames.sorted().joined(separator: ", "))")
        }

        let linked = linker.link(
            extractionResults, usrRewriteMapOverrides: localFallbackOverrides,
            additionalGlobalActorNames: bulkResolution.discoveredGlobalActorNames
        )
        logVerbose("Linked \(linked.declarations.count) declaration(s), \(linked.callGraph.count) call-graph edge(s)")

        eprint("Resolving external isolation (compiled dependencies)...")
        let derivedDataPathForExternalIsolation = privateDerivedDataPath
        let externalResolution = runAsyncBridge {
            await resolveExternalIsolation(
                linked: linked, container: container, compilerArguments: compilerArguments, processRunning: processRunning, fileSystem: fileSystem,
                oracleWorkers: oracleWorkers, derivedDataPath: derivedDataPathForExternalIsolation,
                precomputedBulkResolution: bulkResolution
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
            awaitedRangesByFile: linked.awaitedRangesByFile,
            preconcurrencyImportedModulesByFile: linked.preconcurrencyImportedModulesByFile
        )

        warnIfUncertaintyRateIsAnomalouslyHigh(report)

        try StalenessOrchestration.writeManifest(StalenessManifest(contentHashesByFilePath: currentHashes), to: manifestURL, fileSystem: fileSystem)
        // The exit-code decision below is based on `report` itself, not the filtered/sorted view --
        // `--severity`/`--sort` are presentation choices for this invocation's output, never a way
        // to change whether the analysis considers the project to have a real high-risk boundary.
        let filteredReport = AnalysisReportBuilder.filtered(report, minimumSeverity: severity)
        try writeOutput(AnalysisReportBuilder.sorted(filteredReport, by: sort))

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
    private func resolveLanguageMode(
        container: ProjectContainer, fileSystem: FileSystemQuerying, processRunning: ProcessRunning, derivedDataPath: URL?
    ) throws -> String {
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
            return try SwiftVersionDetection.xcodeLanguageMode(
                container: container, schemeName: scheme, processRunning: processRunning, derivedDataPath: derivedDataPath
            )
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
        container: ProjectContainer, processRunning: ProcessRunning, fileSystem: FileSystemQuerying, derivedDataPath: URL?
    ) -> CompilerArgumentsProviding {
        switch container {
        case .swiftPackage(let packageURL):
            return LiveSwiftPMCompilerArgumentsProvider(
                packageDirectory: packageURL.deletingLastPathComponent(), processRunning: processRunning
            )
        case .xcodeproj, .xcworkspace:
            // The main path since docs/task-swift-build-prepare-for-indexing-spike.md's Steps 1-26:
            // a direct call into `swift-build`'s own open-source `SWBBuildService` API, bypassing
            // `xcodebuild -verbose`/clean-rebuild entirely. Real-corpus validated twice -- byte-for-
            // byte edge parity on a real ~2200-file corpus at Step 10, and again end-to-end on
            // WordPress-iOS (Steps 13-26): after Step 25 fixed the one real bug `xcodebuild -verbose`
            // parsing had (no home-directory target preference for a file shared across sibling
            // targets), the two paths' honest-vs-flagged divergence dropped from 834 to 14 edges
            // (98.3%), and the residual 14 are a separately-confirmed, non-bug shape (Step 26). Also
            // ~35% faster. `derivedDataPath` is unconditionally non-nil for Xcode containers
            // (computed just above this call, see `privateDerivedDataPath`'s own assignment) --
            // the old `xcodebuild -verbose`-based provider this superseded (`LiveXcodeCompilerArgumentsProvider`,
            // kept for a while afterward as an unreachable-from-any-CLI-flag fallback for a
            // `derivedDataPath == nil` state this project's own invariants already said couldn't
            // happen) has since been removed from the tree entirely, not just made unreachable.
            return SwiftBuildCompilerArgumentsProvider(container: container, scheme: scheme, derivedDataPath: derivedDataPath!)
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

    /// The single platform every `SyntaxAnalysis` extractor evaluates `#if os(...)`/`#if
    /// canImport(...)` against (docs/task-bulk-extraction-wrong-platform.md §5) -- reuses whatever
    /// `-target <triple>` the *already-resolved* `compilerArguments` carries (memoized by
    /// `detectConfiguredDefaultIsolation`'s own call just above; this never triggers a second real
    /// build) rather than a fresh lookup. `.unknown` (never filtering any `#if` branch, this
    /// project's pre-existing platform-blind behavior) for anything this can't parse -- a SwiftPM
    /// package's own `-target <triple>` shape, a compiler-arguments failure, or a triple this
    /// parser doesn't recognize -- matching `detectConfiguredDefaultIsolation`'s own fail-soft
    /// precedent immediately above.
    private func detectTargetPlatform(
        compilerArguments: CompilerArgumentsProviding, sourceFiles: [URL]
    ) -> TargetPlatform {
        for file in sourceFiles where file.lastPathComponent != "Package.swift" {
            guard let args = try? compilerArguments.compilerArguments(forFile: file.path) else { continue }
            guard let flagIndex = args.firstIndex(of: "-target"), args.indices.contains(flagIndex + 1) else {
                return .unknown
            }
            return Self.platform(fromTargetTriple: args[flagIndex + 1])
        }
        return .unknown
    }

    /// A real target triple's OS component sits right after `-apple-`, immediately followed by a
    /// version number (`arm64-apple-ios15.6-simulator`, `arm64-apple-macosx13.0`,
    /// confirmed against this project's own real captured build logs this session) -- matching the
    /// leading run of letters after that marker is enough, no need for a full triple grammar.
    static func platform(fromTargetTriple triple: String) -> TargetPlatform {
        guard let appleRange = triple.range(of: "-apple-") else { return .unknown }
        let osComponent = triple[appleRange.upperBound...].prefix { $0.isLetter }
        switch osComponent {
        case "ios": return .iOS
        case "macosx", "macos": return .macOS
        case "tvos": return .tvOS
        case "watchos": return .watchOS
        default: return .unknown
        }
    }

    // MARK: - Index store resolution (locate / prompt / build / stop)

    private func resolveIndexStoreURL(
        container: ProjectContainer,
        initialDiscovery: IndexStoreDiscoveryResult,
        staleness: StalenessStatus,
        locator: IndexStoreLocator,
        processRunning: ProcessRunning,
        derivedDataPath: URL?,
        fileSystem: FileSystemQuerying
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
            return try build(container: container, locator: locator, processRunning: processRunning, derivedDataPath: derivedDataPath, fileSystem: fileSystem)

        case .promptUser:
            return try promptForIndexStore(
                discovery: initialDiscovery, container: container, locator: locator, processRunning: processRunning,
                derivedDataPath: derivedDataPath, fileSystem: fileSystem
            )
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
        processRunning: ProcessRunning,
        derivedDataPath: URL?,
        fileSystem: FileSystemQuerying
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
                // A manually-provided path is trusted outright -- auto-detection, and the staleness
                // comparison that only applies to a store this tool itself vouches for, are both
                // skipped -- there's no manifest for a path the user is pointing at for the first
                // time, entered interactively right here, not a silent CLI-flag override.
                return URL(fileURLWithPath: providedPath)
            }
        case "2":
            return try build(container: container, locator: locator, processRunning: processRunning, derivedDataPath: derivedDataPath, fileSystem: fileSystem)
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
    private func build(
        container: ProjectContainer, locator: IndexStoreLocator, processRunning: ProcessRunning, derivedDataPath: URL?,
        fileSystem: FileSystemQuerying
    ) throws -> URL {
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
                throw ProcessFailure(command: "swift build", exitCode: result.exitCode, standardError: result.standardError, standardOutput: result.standardOutput)
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
            if let destination = resolveDeterministicSimulatorDestination(
                container: container, scheme: scheme, processRunning: processRunning, derivedDataPath: derivedDataPath
            ) {
                arguments += ["-destination", destination]
            }
            // Private DerivedData (docs/task-private-derived-data-hypothesis.md) --
            // always non-`nil` here in practice (every `.xcodeproj`/`.xcworkspace` caller of this
            // function passes the unconditionally-computed private path); the `if let` stays a
            // plain optional unwrap rather than a forced one only for this function's own
            // testability (a caller could construct one without it).
            if let derivedDataPath {
                arguments += ["-derivedDataPath", derivedDataPath.path]
            }
            arguments += xcodeIndexingBuildSettings + ["build"]
            let result = try processRunning.run(executable: "xcodebuild", arguments: arguments, workingDirectory: nil)
            guard result.exitCode == 0 else {
                throw ProcessFailure(command: "xcodebuild", exitCode: result.exitCode, standardError: result.standardError, standardOutput: result.standardOutput)
            }
            // A private root's own store location is known by construction (unlike Xcode's own
            // opaque, hashed shared-DerivedData folder naming, which `locator.locate(for:)` has to
            // search for) -- checked directly rather than re-searching.
            if let derivedDataPath {
                let dataStoreURL = derivedDataPath.appendingPathComponent("Index.noindex/DataStore")
                guard fileSystem.directoryExists(at: dataStoreURL) else {
                    throw SwiftIsolationMapError.indexStoreMissingAfterRebuild
                }
                return dataStoreURL
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

    /// Shared by the early, `link()`-preceding bulk pass (Issue #40's `discoveredGlobalActorNames`
    /// need) and `resolveExternalIsolation` below -- both need the exact same environment provider
    /// construction, previously only inlined in the latter.
    private func makeBulkExtractionEnvironmentProvider(
        container: ProjectContainer, scheme: String, processRunning: ProcessRunning, fileSystem: FileSystemQuerying, derivedDataPath: URL?
    ) -> BulkExtractionEnvironmentProviding {
        switch container {
        case .swiftPackage(let packageURL):
            let packageDirectory = packageURL.deletingLastPathComponent()
            return SwiftPMBulkExtractionEnvironmentProvider(
                packageDirectory: packageDirectory, processRunning: processRunning, fileSystem: fileSystem
            )
        case .xcodeproj, .xcworkspace:
            return LiveXcodeBulkExtractionEnvironmentProvider(
                container: container, scheme: scheme, processRunning: processRunning, fileSystem: fileSystem,
                derivedDataPath: derivedDataPath
            )
        }
    }

    /// Mirrors `ExternalIsolationBackfill`'s own private `bulkSymbolGraphCache` helper exactly
    /// (fail-soft: an unobtainable environment -- e.g. no real build settings available yet --
    /// yields an empty resolution, never a thrown error) -- duplicated rather than shared because
    /// that one stays `private` to keep `ExternalIsolationBackfill`'s own surface area minimal,
    /// and this call site needs to run *before* `linker.link(...)`, structurally earlier than
    /// anywhere inside that type's own `resolve()` entry point.
    private func bulkSymbolGraphResolution(
        environmentProvider: BulkExtractionEnvironmentProviding, processRunning: ProcessRunning, fileSystem: FileSystemQuerying
    ) -> BulkSymbolGraphResolution {
        guard let environment = try? environmentProvider.environment() else {
            return BulkSymbolGraphResolution(isolationByUSR: [:], protocolUSRs: [])
        }
        return BulkSymbolGraphExtractor.extractAll(
            discoveredModules: environment.discoveredModules,
            sdkPath: environment.sdkPath, target: environment.target,
            processRunning: processRunning, fileSystem: fileSystem
        )
    }

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
        oracleWorkers: Int,
        derivedDataPath: URL?,
        precomputedBulkResolution: BulkSymbolGraphResolution
    ) async -> ExternalIsolationResolution {
        let empty = ExternalIsolationResolution(backfilledDeclarations: [:], updatedDeclarations: [:], unknownUSRs: [])

        // The caller already ran this run's one bulk symbol-graph pass, before `linker.link(...)`
        // (Issue #40's own `discoveredGlobalActorNames` need) -- an `environmentProvider` is still
        // constructed and passed to `ExternalIsolationBackfill.resolve` below (it's a required
        // parameter of that function's own, separately-testable contract), but
        // `precomputedBulkResolution` means it's never actually invoked a second time.
        let environmentProvider = makeBulkExtractionEnvironmentProvider(
            container: container, scheme: scheme, processRunning: processRunning, fileSystem: fileSystem, derivedDataPath: derivedDataPath
        )

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
            oracleWorkerExecutablePath: oracleWorkers > 1 ? URL(fileURLWithPath: CommandLine.arguments[0]).path : nil,
            precomputedBulkResolution: precomputedBulkResolution
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

    /// A silent, near-total external-isolation resolution failure (confirmed against a real,
    /// ~40-dependency workspace: 97% of edges carrying `isUnknown`/`unspecified` after a stale-build
    /// retry, with zero indication anywhere in the output) looks identical in the JSON to a small,
    /// genuinely expected number of unresolved compiled-dependency calls -- nothing about the report
    /// itself distinguishes "the oracle mostly failed this run" from "this project really does have
    /// this many ambiguous boundaries." A threshold-based warning tells the two apart, even before a
    /// real root-cause fix (retrying a failed representative query against another call site,
    /// resolving more members via the bulk cache, ...) exists for any specific failure shape.
    private func warnIfUncertaintyRateIsAnomalouslyHigh(_ report: AnalysisReport) {
        guard !report.edges.isEmpty else { return }
        let uncertainCount = report.edges.filter {
            $0.isUnknown || $0.callerIsolation == "unspecified" || $0.calleeIsolation == "unspecified"
        }.count
        let fraction = Double(uncertainCount) / Double(report.edges.count)
        guard fraction > 0.2 else { return }
        eprint(
            "Warning: \(uncertainCount)/\(report.edges.count) cross-isolation edges "
                + "(\(Int((fraction * 100).rounded()))%) have unresolved isolation on at least one side. "
                + "This usually means the external-isolation oracle didn't get real compiler arguments "
                + "for most of the project this run (a stale-build retry, a build failure, or similar) -- "
                + "not that this many boundaries are genuinely ambiguous. Re-run with --verbose for more detail."
        )
    }

    private func logVerbose(_ message: String) {
        guard verbose else { return }
        eprint("[verbose] " + message)
    }

}
