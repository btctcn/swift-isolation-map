import ArgumentParser
import Foundation
import IndexStoreIntegration
import IsolationCore
import OutputFormat
import ProjectResolution
import SyntaxAnalysis

enum OutputFormatOption: String, ExpressibleByArgument, CaseIterable {
    case mermaid
    case dot
    case json
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

@main
struct SwiftIsolationMap: ParsableCommand {
    static let toolVersion = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "swift-isolation-map",
        abstract: "Static actor isolation and data-race analysis for Swift projects."
    )

    @Argument(help: "Path to a .xcodeproj, .xcworkspace, or Package.swift")
    var path: String

    @Option(help: "Build scheme (Xcode) or product/target (SPM). Required.")
    var scheme: String

    @Option(help: "Explicit path to the index store. If provided, auto-detection is skipped.")
    var indexStorePath: String?

    @Flag(help: "If the index store is missing or stale, build the project without an interactive prompt.")
    var autoBuild: Bool = false

    @Flag(help: "Forces a rebuild, ignoring any existing (even fresh) index store.")
    var forceReindex: Bool = false

    @Option(help: "Output format: mermaid | dot | json")
    var output: OutputFormatOption = .mermaid

    @Option(help: "Where to write the result (default: stdout)")
    var outFile: String?

    @Flag(help: "Verbose logging: what was searched, where the index store was found, how many types were processed.")
    var verbose: Bool = false

    func run() throws {
        let fileSystem = LiveFileSystem()
        let processRunning = LiveProcessRunner()

        let container = try resolveContainer(fromPath: path)
        let projectRoot = StalenessOrchestration.projectRoot(for: container)

        let languageMode = try resolveLanguageMode(container: container, fileSystem: fileSystem, processRunning: processRunning)
        let compilerVersion = try SwiftVersionDetection.compilerVersion(processRunning: processRunning)
        let effectiveVersion = SwiftVersionDetection.effectiveVersion(languageMode: languageMode, compilerVersion: compilerVersion)
        logVerbose("Language mode: \(languageMode); compiler: \(compilerVersion); effective: \(effectiveVersion)")

        let ruleSet = try resolveRuleSet(forSwiftVersion: effectiveVersion)
        logVerbose("Rule set: \(type(of: ruleSet))")

        // A single read per source file drives both the staleness content-hash and the syntactic
        // extraction -- see StalenessOrchestration.swiftFiles's own doc comment for why this list
        // is reused for both purposes, and FileAnalyzer's for why one read yields both facts.
        let sourceFiles = StalenessOrchestration.swiftFiles(under: projectRoot, fileSystem: fileSystem)
        logVerbose("Found \(sourceFiles.count) Swift source file(s) under \(projectRoot.path)")
        let analyzer = FileAnalyzer(fileSystem: fileSystem)
        var currentHashes: [String: String] = [:]
        var extractionResults: [ExtractionResult] = []
        for file in sourceFiles {
            let result = try analyzer.analyze(fileAt: file)
            currentHashes[file.path] = result.contentHash
            extractionResults.append(ExtractionResult(declarations: result.declarations, protocolGlobalActorNames: result.protocolGlobalActorNames))
        }

        let manifestURL = StalenessOrchestration.manifestURL(for: container)
        let manifest = StalenessOrchestration.loadManifest(at: manifestURL, fileSystem: fileSystem)
        let staleness = stalenessStatus(currentHashes: currentHashes, manifest: manifest)

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

        let indexStoreClient = try IndexStoreClient(
            storePath: indexStoreURL.path,
            databasePath: projectRoot.appendingPathComponent(".swift-isolation-map-index-db").path
        )
        let linker = DeclarationLinker(indexStore: indexStoreClient)
        let linked = linker.link(extractionResults)
        logVerbose("Linked \(linked.declarations.count) declaration(s), \(linked.callGraph.count) call-graph edge(s)")

        let engine = IsolationInferenceEngine(declarations: linked.declarations, callGraph: linked.callGraph, ruleSet: ruleSet)
        let report = AnalysisReportBuilder.build(
            engine: engine,
            swiftVersion: effectiveVersion,
            ruleSetUsed: String(describing: type(of: ruleSet)),
            toolVersion: Self.toolVersion
        )

        try StalenessOrchestration.writeManifest(StalenessManifest(contentHashesByFilePath: currentHashes), to: manifestURL, fileSystem: fileSystem)
        try writeOutput(report)

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
        FileHandle.standardError.write(Data((schemeMismatchMessage(requested: requested, available: available) + "\n").utf8))
    }

    private func resolveRuleSet(forSwiftVersion version: String) throws -> IsolationRuleSet {
        do {
            return try IsolationRuleSetRegistry.ruleSet(forSwiftVersion: version)
        } catch let error as UnsupportedSwiftVersionError {
            var message = "swift-isolation-map doesn't support Swift \(error.version) yet."
            if let highest = error.highestSupportedUpperBound {
                message += " Highest supported version: \(highest)."
            }
            FileHandle.standardError.write(Data((message + "\n").utf8))
            throw ExitCode(2)
        }
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
            FileHandle.standardError.write(Data((message + "\n").utf8))
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
            var arguments = ["-scheme", scheme, "-indexStoreEnable", "YES", "build"]
            switch container {
            case .xcodeproj(let url): arguments += ["-project", url.path]
            case .xcworkspace(let url): arguments += ["-workspace", url.path]
            case .swiftPackage: break
            }
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

    /// Every status/prompt message in this file goes through here, to stderr -- `--output json`
    /// (or any format) needs to be safely pipeable, and a "Building project..." or interactive
    /// prompt line interleaved into stdout would corrupt that. Only `writeOutput`'s final
    /// `print(text)` (the actual analysis result) writes to stdout.
    private func eprint(_ message: String, terminator: String = "\n") {
        FileHandle.standardError.write(Data((message + terminator).utf8))
    }
}
