import Foundation
import IndexStoreIntegration
import IsolationCore
import ProjectResolution
import SourceKitDIntegration

/// Extends this project's own existing bulk-then-live pattern (`ExternalIsolationBackfill`,
/// already used for compiled-dependency isolation) to a different gap:
/// `docs/task-indexstore-declaration-completeness.md` found that a real fraction of a large
/// project's *own* declarations (803, measured on Project Iris) never resolve via
/// `DeclarationLinker`'s location-based `usrRewriteMap` under full-project load, despite
/// resolving correctly when the same file is linked in isolation against the same, unchanged
/// index store -- traced to `IndexStoreDB` itself returning incomplete data under load, not to
/// anything in this project's own linking logic. A live `sourcekitd` `cursorinfo` query at the
/// declaration's own (file, line, column) is the same authoritative, per-declaration answer the
/// compiled-dependency oracle already trusts -- reusing it here needs no new data source.
///
/// A real run against Project Iris found **10954** unresolved placeholders -- an order of
/// magnitude more than the 803-declaration finding that motivated this, since it also includes
/// every declaration that's legitimately outside the analyzed scheme's own compilation (a
/// different target/scheme, `#if`-excluded code, etc.) and simply has no compiler arguments to
/// query with -- those fail `resolveOne` near-instantly (an `Error` before any real query), so
/// they aren't the actual cost. The genuine `cursorinfo` round trips are: each one can require
/// building the target file's AST from scratch if not already cached, and `sourcekitd`'s own
/// `ASTBuildQueue` serializes that *within one process* (docs/task-oracle-query-concurrency.md's
/// own finding) -- confirmed by a real timed run: purely sequential, this measurably took over 15
/// minutes and counting before being deliberately stopped. `resolveInParallel` reuses the same
/// real fix already proven for `ExternalIsolationBackfill`'s own live-query phase (separate OS
/// processes, each with an independent `sourcekitd`/`ASTBuildQueue`, near-linear real speedup) --
/// same worker-count knob (`--oracle-workers`), same chunk-balancing logic
/// (`OracleWorker.balancedChunks`, unmodified), a parallel wire format instead of a shared one
/// only because the query shape differs (no `targetUSR`-based `USRMatching`/isolation-parsing
/// needed here -- discovering the real USR *is* the point, so the primary cursor-info result's
/// own USR is taken directly).
enum LocalDeclarationLiveFallback {
    /// One `cursorinfo` round trip for a single unresolved placeholder's own location. Every
    /// failure mode (compiler args unavailable, offset conversion failure, the query itself
    /// throwing) returns `nil`, never a crash -- the placeholder simply stays unresolved, exactly
    /// as if this fallback didn't exist, matching `ExternalIsolationBackfill.query`'s own
    /// precedent.
    static func resolveOne(
        file: String, line: Int, column: Int,
        compilerArguments: CompilerArgumentsProviding,
        sourceKitD: SourceKitDQuerying,
        fileSystem: FileSystemQuerying
    ) async -> String? {
        do {
            let rawArguments = try compilerArguments.compilerArguments(forFile: file)
            let arguments = CompilerArgumentsSanitizing.sanitized(rawArguments)
            let offset = try UTF8OffsetLocator.utf8Offset(inFile: file, line: line, utf8Column: column, fileSystem: fileSystem)
            let result = try await sourceKitD.cursorInfo(CursorInfoRequest(sourceFile: file, byteOffset: offset, compilerArguments: arguments))
            return result.primary.usr
        } catch {
            return nil
        }
    }

    /// The plain sequential path -- used directly when there's no worker parallelism available
    /// (`--oracle-workers` defaulted to 1, or too few items to bother splitting), and as each
    /// spawned worker process's own inner loop.
    static func resolveSequentially(
        unresolved: [(placeholder: String, location: SymbolLocation)],
        compilerArguments: CompilerArgumentsProviding,
        sourceKitD: SourceKitDQuerying,
        fileSystem: FileSystemQuerying
    ) async -> [String: String] {
        var overrides: [String: String] = [:]
        for (placeholder, location) in unresolved {
            if let realUSR = await resolveOne(file: location.file, line: location.line, column: location.column, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem) {
                overrides[placeholder] = realUSR
            }
        }
        return overrides
    }

    /// Root-side dispatch, same shape as `OracleWorker.resolveInParallel` -- splits `unresolved`
    /// into `workerCount` file-adjacency-preserving chunks (`OracleWorker.balancedChunks`,
    /// reused unmodified), resolves only the compiler arguments each chunk's own files need,
    /// spawns one real subprocess per chunk, merges outcomes back. A worker that fails
    /// (non-zero exit, missing/unparseable output) just leaves its chunk's placeholders
    /// unresolved -- matching this project's "never let one optional-enrichment component abort
    /// the whole run" precedent.
    static func resolveInParallel(
        unresolved: [(placeholder: String, location: SymbolLocation)],
        workerCount: Int,
        compilerArguments: CompilerArgumentsProviding,
        workerExecutablePath: String?,
        processRunning: ProcessRunning,
        fileSystem: FileSystemQuerying,
        sourceKitD: SourceKitDQuerying
    ) async -> [String: String] {
        guard workerCount > 1, let workerExecutablePath, unresolved.count >= workerCount else {
            return await resolveSequentially(unresolved: unresolved, compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem)
        }

        let chunks = OracleWorker.balancedChunks(
            items: unresolved.map { (targetUSR: $0.placeholder, file: $0.location.file, line: $0.location.line, column: $0.location.column) },
            workerCount: workerCount
        )

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-isolation-map-local-decl-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var results: [String: String] = [:]
        await withTaskGroup(of: LocalDeclarationWorkerOutput?.self) { group in
            for (index, chunk) in chunks.enumerated() {
                group.addTask {
                    await Self.runWorker(
                        chunk: chunk, index: index, tempDirectory: tempDirectory,
                        compilerArguments: compilerArguments, workerExecutablePath: workerExecutablePath, processRunning: processRunning
                    )
                }
            }
            for await output in group {
                if let output {
                    results.merge(output.realUSRByPlaceholder) { _, new in new }
                }
            }
        }
        return results
    }

    private static func runWorker(
        chunk: [(targetUSR: String, file: String, line: Int, column: Int)],
        index: Int,
        tempDirectory: URL,
        compilerArguments: CompilerArgumentsProviding,
        workerExecutablePath: String,
        processRunning: ProcessRunning
    ) async -> LocalDeclarationWorkerOutput? {
        var compilerArgsByFile: [String: [String]] = [:]
        for file in Set(chunk.map(\.file)) {
            if let args = try? compilerArguments.compilerArguments(forFile: file) {
                compilerArgsByFile[file] = args
            }
        }

        let input = LocalDeclarationWorkerInput(
            items: chunk.map { LocalDeclarationWorkItemWire(placeholder: $0.targetUSR, file: $0.file, line: $0.line, column: $0.column) },
            compilerArgsByFile: compilerArgsByFile
        )
        let inputPath = tempDirectory.appendingPathComponent("worker-\(index)-input.json").path
        let outputPath = tempDirectory.appendingPathComponent("worker-\(index)-output.json").path

        guard let inputData = try? JSONEncoder().encode(input) else { return nil }
        guard (try? inputData.write(to: URL(fileURLWithPath: inputPath))) != nil else { return nil }

        guard let result = try? processRunning.run(
            executable: workerExecutablePath,
            arguments: ["--local-declaration-worker-input", inputPath, "--local-declaration-worker-output", outputPath],
            workingDirectory: nil
        ), result.exitCode == 0 else {
            return nil
        }

        guard let outputData = try? Data(contentsOf: URL(fileURLWithPath: outputPath)) else { return nil }
        return try? JSONDecoder().decode(LocalDeclarationWorkerOutput.self, from: outputData)
    }
}

/// One local-declaration-resolution work item, serializable across the process boundary --
/// mirrors `OracleWorkItemWire`'s shape (`targetUSR` renamed `placeholder`, since it's an
/// identifier to match the result back up by, not something `USRMatching` searches for here).
struct LocalDeclarationWorkItemWire: Codable {
    let placeholder: String
    let file: String
    let line: Int
    let column: Int
}

struct LocalDeclarationWorkerInput: Codable {
    let items: [LocalDeclarationWorkItemWire]
    let compilerArgsByFile: [String: [String]]
}

struct LocalDeclarationWorkerOutput: Codable {
    let realUSRByPlaceholder: [String: String]
}

enum LocalDeclarationWorker {
    /// Entry point for `--local-declaration-worker-input`/`--local-declaration-worker-output`,
    /// mirroring `OracleWorker.run`'s own shape: reads its assignment, resolves every item
    /// against a real, fresh `SourceKitDClient` (its own process, its own `sourcekitd`), writes
    /// outcomes back out.
    static func run(inputPath: String, outputPath: String) async throws {
        let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
        let input = try JSONDecoder().decode(LocalDeclarationWorkerInput.self, from: inputData)
        let compilerArguments = StaticCompilerArgumentsProviding(cache: input.compilerArgsByFile)
        let fileSystem = LiveFileSystem()
        let sourceKitD = try SourceKitDClient()

        var realUSRByPlaceholder: [String: String] = [:]
        for item in input.items {
            if let realUSR = await LocalDeclarationLiveFallback.resolveOne(
                file: item.file, line: item.line, column: item.column,
                compilerArguments: compilerArguments, sourceKitD: sourceKitD, fileSystem: fileSystem
            ) {
                realUSRByPlaceholder[item.placeholder] = realUSR
            }
        }

        let output = LocalDeclarationWorkerOutput(realUSRByPlaceholder: realUSRByPlaceholder)
        try JSONEncoder().encode(output).write(to: URL(fileURLWithPath: outputPath))
    }
}
