import Foundation

/// Real per-file `swiftc`/`swift-frontend` arguments for a SwiftPM package, obtained by running
/// `swift build -v` once and parsing the real invocation lines (`CompilerArgsLogParser`) --
/// deliberately not `-showBuildSettings`-style key/value introspection (SwiftPM has no such
/// command) and not a hand-assembled `-sdk`/`-target` guess: this is the actual, verbatim argument
/// list the real build already used for that file, guaranteeing `sourcekitd` sees the same
/// semantics as the real compile. SwiftPM containers need no scheme/build-settings resolution
/// beyond this -- confirmed already proven zero-config end to end against this very repo during
/// the compiled-dependency-isolation research spike (docs/compiled-dependency-isolation-sourcekit-lsp-spike.md).
public final class LiveSwiftPMCompilerArgumentsProvider: CompilerArgumentsProviding, @unchecked Sendable {
    private let packageDirectory: URL
    private let processRunning: ProcessRunning
    private let lock = NSLock()
    private var cachedArguments: [String: [String]]?

    public init(packageDirectory: URL, processRunning: ProcessRunning = LiveProcessRunner()) {
        self.packageDirectory = packageDirectory
        self.processRunning = processRunning
    }

    public func compilerArguments(forFile path: String) throws -> [String] {
        let argumentsByFile = try loadArgumentsIfNeeded()
        guard let arguments = argumentsByFile[path] else {
            throw CompilerArgumentsError.argumentsNotFound(file: path)
        }
        return arguments
    }

    /// `swift build -v` runs a real build once per process lifetime (subsequent calls reuse the
    /// cached parse) -- an incremental build if `.build` state already exists, matching this
    /// project's existing "don't force a rebuild you don't need" discipline elsewhere
    /// (`StalenessOrchestration`).
    private func loadArgumentsIfNeeded() throws -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedArguments {
            return cachedArguments
        }
        let result = try processRunning.run(
            executable: "swift",
            arguments: ["build", "-v"],
            workingDirectory: packageDirectory
        )
        guard result.exitCode == 0 else {
            throw CompilerArgumentsError.buildLogParseFailed(
                reason: "swift build -v exited \(result.exitCode): \(result.standardError)"
            )
        }
        let parsed = CompilerArgsLogParser.parse(buildLog: result.standardOutput)
        cachedArguments = parsed
        // TEMP diagnostic: investigating why some Consumer fixture files throw argumentsNotFound
        // on CI only -- see if the raw `swift build -v` log even mentions them, versus the parser
        // silently dropping a present-but-differently-shaped line.
        if result.standardOutput.contains("compiled-dependency") {
            let path = "/tmp/swift-isolation-map-diag.log"
            let interestingNames = ["NegativeControl.swift", "Divergent.swift", "MechanismB.swift", "Case4.swift", "MechanismA.swift"]
            let rawMentions = interestingNames.map { "\($0): rawLogContains=\(result.standardOutput.contains($0))" }.joined(separator: ", ")
            let parsedFiles = parsed.keys.map { ($0 as NSString).lastPathComponent }.sorted()
            let message = "SwiftPMCompilerArgumentsProvider: rawLog.count=\(result.standardOutput.count) parsed.count=\(parsed.count) \(rawMentions); parsedFiles=\(parsedFiles)\n"
            if let data = message.data(using: .utf8) {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    try? data.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        return parsed
    }
}
