import Foundation
import IsolationCore
import ProjectResolution
import SourceKitDIntegration

/// Process-level parallelism for `ExternalIsolationBackfill`'s live-query phase
/// (docs/task-process-tree-optimization.md): two real spikes confirmed this phase is 97.6% of real
/// oracle wall-clock on a real project, and that separate OS processes -- each with their own
/// `sourcekitd` instance, hence their own independent `ASTBuildQueue` -- achieve real, near-linear
/// parallelism (within ~5-8% of solo time) with byte-identical results to a sequential run.
/// Opt-in only (`--oracle-workers`, default 1 -- today's exact sequential behavior): this is new,
/// subprocess-spawning machinery, not something existing invocations should be silently exposed to.

/// One live-query work item, serializable across the process boundary.
struct OracleWorkItemWire: Codable {
    let targetUSR: String
    let file: String
    let line: Int
    let column: Int
}

/// A worker's assignment: its slice of work items, plus only the compiler arguments its own files
/// need -- resolved once, in the root process, and handed down, so a worker never has to trigger
/// its own real `xcodebuild`/`swift build` invocation (see the real, documented cost of that in
/// docs/task-process-tree-optimization.md's operational note).
struct OracleWorkerInput: Codable {
    let items: [OracleWorkItemWire]
    let compilerArgsByFile: [String: [String]]
}

/// `ExternalIsolationBackfill.QueryOutcome`, serializable -- kept as its own wire type rather than
/// making the internal enum itself `Codable` so the two can evolve independently.
struct OracleQueryOutcomeWire: Codable {
    let isolationKind: IsolationKind?

    init(_ outcome: ExternalIsolationBackfill.QueryOutcome) {
        switch outcome {
        case .resolved(let kind): self.isolationKind = kind
        case .unknown: self.isolationKind = nil
        }
    }

    var outcome: ExternalIsolationBackfill.QueryOutcome {
        isolationKind.map { .resolved($0) } ?? .unknown
    }
}

struct OracleWorkerOutput: Codable {
    let outcomesByTargetUSR: [String: OracleQueryOutcomeWire]
}

/// Looks up compiler arguments from a pre-resolved, static cache instead of ever invoking a real
/// build -- the whole point of resolving them once in the root and handing them to workers.
struct StaticCompilerArgumentsProviding: CompilerArgumentsProviding {
    let cache: [String: [String]]

    func compilerArguments(forFile path: String) throws -> [String] {
        guard let arguments = cache[path] else {
            throw CompilerArgumentsError.argumentsNotFound(file: path)
        }
        return arguments
    }
}

enum OracleWorker {
    /// Entry point for `--oracle-worker-input`/`--oracle-worker-output`: reads its assignment,
    /// resolves every item against a real, fresh `SourceKitDClient` (its own process, its own
    /// `sourcekitd`), writes outcomes back out. No project resolution, no index store, no syntax
    /// analysis -- a worker only ever does live queries.
    static func run(inputPath: String, outputPath: String) async throws {
        let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let input = try JSONDecoder().decode(OracleWorkerInput.self, from: inputData)
        let compilerArguments = StaticCompilerArgumentsProviding(cache: input.compilerArgsByFile)
        let fileSystem = LiveFileSystem()
        let sourceKitD = try SourceKitDClient()

        var outcomesByTargetUSR: [String: OracleQueryOutcomeWire] = [:]
        for item in input.items {
            let outcome = await ExternalIsolationBackfill.query(
                targetUSR: item.targetUSR, file: item.file, line: item.line, utf8Column: item.column,
                compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem, bulkCache: [:]
            )
            outcomesByTargetUSR[item.targetUSR] = OracleQueryOutcomeWire(outcome)
        }

        let output = OracleWorkerOutput(outcomesByTargetUSR: outcomesByTargetUSR)
        try JSONEncoder().encode(output).write(to: URL(fileURLWithPath: outputPath))
    }

    /// Root-side dispatch: splits `items` (already file-sorted by the caller, per hypothesis 0)
    /// into `workerCount` contiguous chunks -- preserving each chunk's own internal file-adjacency,
    /// the whole reason hypothesis 0's ordering matters -- resolves only the compiler arguments each
    /// chunk's own files need, spawns one real subprocess per chunk, and merges their outcomes back.
    /// A worker that fails (non-zero exit, missing/unparseable output) has every one of its items
    /// fail soft to `.unknown` -- matching this project's "never let one optional-enrichment
    /// component abort the whole run" precedent -- rather than losing the whole run over one bad
    /// worker.
    static func resolveInParallel(
        items: [(targetUSR: String, file: String, line: Int, column: Int)],
        workerCount: Int,
        compilerArguments: CompilerArgumentsProviding,
        workerExecutablePath: String,
        processRunning: ProcessRunning
    ) async -> [String: ExternalIsolationBackfill.QueryOutcome] {
        guard workerCount > 1, items.count >= workerCount else {
            return await sequentialFallback(items: items, compilerArguments: compilerArguments)
        }

        let chunks = balancedChunks(items: items, workerCount: workerCount)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-isolation-map-oracle-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var results: [String: ExternalIsolationBackfill.QueryOutcome] = [:]
        await withTaskGroup(of: (chunk: [(targetUSR: String, file: String, line: Int, column: Int)], output: OracleWorkerOutput?).self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    let output = await Self.runWorker(
                        chunk: chunk, index: index, tempDirectory: tempDirectory,
                        compilerArguments: compilerArguments, workerExecutablePath: workerExecutablePath, processRunning: processRunning
                    )
                    return (chunk, output)
                }
            }
            for await (chunk, output) in group {
                if let output {
                    for (usr, wire) in output.outcomesByTargetUSR {
                        results[usr] = wire.outcome
                    }
                } else {
                    eprint("Warning: an oracle worker process failed -- its \(chunk.count) item(s) fall back to unknown.")
                    for item in chunk { results[item.targetUSR] = .unknown }
                }
            }
        }
        return results
    }

    /// Balances chunks by *distinct file count*, not item count (issue #35 -- confirmed via a
    /// real simulation against Project Iris's own merged plan: equal-item-count chunking produced
    /// a 5.08x spread in distinct-file count across 8 chunks (77 to 391), which is what actually
    /// drives real cost -- a chunk touching many distinct files gets far fewer AST-cache hits than
    /// one touching few, per hypothesis 0's own logic, regardless of item count. Balancing by
    /// distinct file count instead reduced that spread to 1.02x (226 to 230) on the same data.
    /// `items` is assumed already file-sorted (hypothesis 0's own invariant, preserved here since
    /// this only ever cuts a new chunk at a file boundary, never mid-file) -- walks the list once,
    /// closing the current chunk whenever adding the next item's file would push its distinct-file
    /// count over an equal `N`-way share, capped at `workerCount - 1` cuts so the final chunk
    /// absorbs whatever remains (avoids ever producing more than `workerCount` chunks from
    /// rounding).
    static func balancedChunks(
        items: [(targetUSR: String, file: String, line: Int, column: Int)], workerCount: Int
    ) -> [[(targetUSR: String, file: String, line: Int, column: Int)]] {
        let totalDistinctFiles = Set(items.map(\.file)).count
        let targetFilesPerChunk = Double(totalDistinctFiles) / Double(workerCount)

        var chunks: [[(targetUSR: String, file: String, line: Int, column: Int)]] = []
        var currentChunk: [(targetUSR: String, file: String, line: Int, column: Int)] = []
        var seenFiles: Set<String> = []

        for item in items {
            if !currentChunk.isEmpty, !seenFiles.contains(item.file),
               Double(seenFiles.count + 1) > targetFilesPerChunk, chunks.count < workerCount - 1 {
                chunks.append(currentChunk)
                currentChunk = []
                seenFiles = []
            }
            currentChunk.append(item)
            seenFiles.insert(item.file)
        }
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }
        return chunks
    }

    private static func runWorker(
        chunk: [(targetUSR: String, file: String, line: Int, column: Int)],
        index: Int,
        tempDirectory: URL,
        compilerArguments: CompilerArgumentsProviding,
        workerExecutablePath: String,
        processRunning: ProcessRunning
    ) async -> OracleWorkerOutput? {
        var compilerArgsByFile: [String: [String]] = [:]
        for file in Set(chunk.map(\.file)) {
            if let args = try? compilerArguments.compilerArguments(forFile: file) {
                compilerArgsByFile[file] = args
            }
        }

        let input = OracleWorkerInput(
            items: chunk.map { OracleWorkItemWire(targetUSR: $0.targetUSR, file: $0.file, line: $0.line, column: $0.column) },
            compilerArgsByFile: compilerArgsByFile
        )
        let inputPath = tempDirectory.appendingPathComponent("worker-\(index)-input.json").path
        let outputPath = tempDirectory.appendingPathComponent("worker-\(index)-output.json").path

        guard let inputData = try? JSONEncoder().encode(input) else { return nil }
        guard (try? inputData.write(to: URL(fileURLWithPath: inputPath))) != nil else { return nil }

        guard let result = try? processRunning.run(
            executable: workerExecutablePath,
            arguments: ["--oracle-worker-input", inputPath, "--oracle-worker-output", outputPath],
            workingDirectory: nil
        ), result.exitCode == 0 else {
            return nil
        }

        guard let outputData = try? Data(contentsOf: URL(fileURLWithPath: outputPath)) else { return nil }
        return try? JSONDecoder().decode(OracleWorkerOutput.self, from: outputData)
    }

    private static func sequentialFallback(
        items: [(targetUSR: String, file: String, line: Int, column: Int)],
        compilerArguments: CompilerArgumentsProviding
    ) async -> [String: ExternalIsolationBackfill.QueryOutcome] {
        let fileSystem = LiveFileSystem()
        guard let sourceKitD = try? SourceKitDClient() else {
            return Dictionary(uniqueKeysWithValues: items.map { ($0.targetUSR, .unknown) })
        }
        var results: [String: ExternalIsolationBackfill.QueryOutcome] = [:]
        for item in items {
            results[item.targetUSR] = await ExternalIsolationBackfill.query(
                targetUSR: item.targetUSR, file: item.file, line: item.line, utf8Column: item.column,
                compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem, bulkCache: [:]
            )
        }
        return results
    }
}
