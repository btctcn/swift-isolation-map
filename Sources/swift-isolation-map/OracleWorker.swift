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
    /// The root process's own `linked.globalActorNames` -- a worker has no project files or
    /// syntax analysis of its own (see this type's own doc comment), so it can't compute this
    /// itself; handed down the same way `compilerArgsByFile` already is. See
    /// `GlobalActorNameValidation`'s own doc comment for what this is used to validate against.
    let knownGlobalActorNames: Set<String>
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
                compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem, bulkCache: [:],
                knownGlobalActorNames: input.knownGlobalActorNames
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
        processRunning: ProcessRunning,
        knownGlobalActorNames: Set<String>
    ) async -> [String: ExternalIsolationBackfill.QueryOutcome] {
        guard workerCount > 1, items.count >= workerCount else {
            return await sequentialFallback(items: items, compilerArguments: compilerArguments, knownGlobalActorNames: knownGlobalActorNames)
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
                        compilerArguments: compilerArguments, workerExecutablePath: workerExecutablePath, processRunning: processRunning,
                        knownGlobalActorNames: knownGlobalActorNames
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
                    // `runWorker` itself already `eprint`ed a specific reason (launch failure, exit
                    // code + real stderr, unreadable/undecodable output) -- nothing generic to add
                    // here, just apply the same "fail soft to unknown" fallback for every item.
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

    /// A worker's own `stderr` is real diagnostic data (a launch failure's reason, a non-zero exit's
    /// own error output, or -- opt-in via `SWIFT_ISOLATION_MAP_WORKER_STDERR` -- ordinary `eprint`
    /// output the worker subprocess itself produced, e.g. `--verbose`-style logging or temporary debug
    /// instrumentation added to `ExternalIsolationBackfill.query(...)`, which this codebase's own live
    /// oracle path runs identically whether or not `--oracle-workers > 1` is in play). Confirmed a
    /// real, previously-silent gap while auditing a real corpus's residual `isUnknown` edges
    /// (docs/task-extern-constant-swift-name-usr-mismatch.md's §6): `LiveProcessRunner` captures a
    /// child process's `stderr` into a `Pipe`, fully in memory, never connected to this process's own
    /// `stderr` file descriptor -- silence here was previously not "probably lost," it was
    /// *provably* discarded by the caller never reading `result.standardError` at all. Failure
    /// messages below follow this project's own established convention for every other subprocess
    /// call site (`SwiftVersionDetectionError`, `PrerequisiteChecking`, `BulkExtractionEnvironmentProviding`,
    /// ...): always surface `standardError` in the failure message itself, trimmed, never silently
    /// swallowed.
    private static func runWorker(
        chunk: [(targetUSR: String, file: String, line: Int, column: Int)],
        index: Int,
        tempDirectory: URL,
        compilerArguments: CompilerArgumentsProviding,
        workerExecutablePath: String,
        processRunning: ProcessRunning,
        knownGlobalActorNames: Set<String>
    ) async -> OracleWorkerOutput? {
        var compilerArgsByFile: [String: [String]] = [:]
        for file in Set(chunk.map(\.file)) {
            if let args = try? compilerArguments.compilerArguments(forFile: file) {
                compilerArgsByFile[file] = args
            }
        }

        let input = OracleWorkerInput(
            items: chunk.map { OracleWorkItemWire(targetUSR: $0.targetUSR, file: $0.file, line: $0.line, column: $0.column) },
            compilerArgsByFile: compilerArgsByFile,
            knownGlobalActorNames: knownGlobalActorNames
        )
        let inputPath = tempDirectory.appendingPathComponent("worker-\(index)-input.json").path
        let outputPath = tempDirectory.appendingPathComponent("worker-\(index)-output.json").path

        guard let inputData = try? JSONEncoder().encode(input) else {
            eprint("Warning: oracle worker \(index) failed -- could not encode its own \(chunk.count)-item input; falling back to unknown.")
            return nil
        }
        guard (try? inputData.write(to: URL(fileURLWithPath: inputPath))) != nil else {
            eprint("Warning: oracle worker \(index) failed -- could not write its own input file at \(inputPath); falling back to unknown.")
            return nil
        }

        let result: ProcessResult
        do {
            result = try processRunning.run(
                executable: workerExecutablePath,
                arguments: ["--oracle-worker-input", inputPath, "--oracle-worker-output", outputPath],
                workingDirectory: nil
            )
        } catch {
            eprint("Warning: oracle worker \(index) failed to launch (\(error)); its \(chunk.count) item(s) fall back to unknown.")
            return nil
        }

        let trimmedStderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0 else {
            eprint("Warning: oracle worker \(index) exited \(result.exitCode); its \(chunk.count) item(s) fall back to unknown.\(trimmedStderr.isEmpty ? "" : " stderr: \(trimmedStderr)")")
            return nil
        }
        if !trimmedStderr.isEmpty, ProcessInfo.processInfo.environment["SWIFT_ISOLATION_MAP_WORKER_STDERR"] != nil {
            eprint("[worker \(index) stderr] \(trimmedStderr)")
        }

        guard let outputData = try? Data(contentsOf: URL(fileURLWithPath: outputPath)) else {
            eprint("Warning: oracle worker \(index) exited 0 but its output file at \(outputPath) could not be read; its \(chunk.count) item(s) fall back to unknown.")
            return nil
        }
        guard let output = try? JSONDecoder().decode(OracleWorkerOutput.self, from: outputData) else {
            eprint("Warning: oracle worker \(index) exited 0 but its output could not be decoded; its \(chunk.count) item(s) fall back to unknown.")
            return nil
        }
        return output
    }

    private static func sequentialFallback(
        items: [(targetUSR: String, file: String, line: Int, column: Int)],
        compilerArguments: CompilerArgumentsProviding,
        knownGlobalActorNames: Set<String>
    ) async -> [String: ExternalIsolationBackfill.QueryOutcome] {
        let fileSystem = LiveFileSystem()
        guard let sourceKitD = try? SourceKitDClient() else {
            return Dictionary(uniqueKeysWithValues: items.map { ($0.targetUSR, .unknown) })
        }
        var results: [String: ExternalIsolationBackfill.QueryOutcome] = [:]
        for item in items {
            results[item.targetUSR] = await ExternalIsolationBackfill.query(
                targetUSR: item.targetUSR, file: item.file, line: item.line, utf8Column: item.column,
                compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem, bulkCache: [:],
                knownGlobalActorNames: knownGlobalActorNames
            )
        }
        return results
    }
}
