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
    /// The analyzed project's own real Swift source file count (`StalenessOrchestration.swiftFiles`,
    /// already computed by every real caller before constructing this provider) -- see
    /// `retryThreshold`'s own doc comment for why this, not a fixed number, is what the
    /// retry-with-clean decision actually needs. `nil` (every caller that predates issue #142, and
    /// every existing test double) falls back to a fixed, absolute floor instead.
    private let expectedFileCount: Int?
    private let lock = NSLock()
    private var cachedArguments: [String: [String]]?

    public init(packageDirectory: URL, processRunning: ProcessRunning = LiveProcessRunner(), expectedFileCount: Int? = nil) {
        self.packageDirectory = packageDirectory
        self.processRunning = processRunning
        self.expectedFileCount = expectedFileCount
    }

    public func compilerArguments(forFile path: String) throws -> [String] {
        let argumentsByFile = try loadArgumentsIfNeeded()
        guard let arguments = argumentsByFile[path] else {
            throw CompilerArgumentsError.argumentsNotFound(file: path)
        }
        return arguments
    }

    /// A real, incremental `swift build -v` only prints a compile invocation line for a file
    /// SwiftPM actually (re)compiles *this run* -- a target it decides is already fully up to date
    /// gets no line at all, real source and real arguments notwithstanding. Confirmed directly
    /// (issue #142, this project's own self-analysis as the real corpus): four consecutive `swift
    /// build -v` invocations against this exact package, zero source changes between them, parsed
    /// to 10 real compile lines each -- while an isolated, from-scratch build (`--build-path` a
    /// fresh temp directory) of the identical source parsed to 1244. The *first* of that
    /// four-invocation streak, run immediately after unrelated build activity, parsed to 32 --
    /// direct, reproduced evidence that a plain incremental `-v` parse's own completeness is
    /// **not stable** run to run, purely as a function of `.build`'s own leftover incremental
    /// state, never of the analyzed source itself changing. This is `LiveSwiftPMCompilerArguments
    /// Provider`'s own real, previously-unidentified contribution to the broader "oracle-query
    /// resolved/unknown counts vary between otherwise-identical runs" symptom
    /// (`docs/task-sourcekitd-cooperative-pool-starvation.md` §9's own loose end 2, issue #142) --
    /// **a different, independent mechanism from that section's own Swiftfin evidence**, which
    /// goes through the unrelated, non-log-parsing `SwiftBuildCompilerArgumentsProvider` (an Xcode-
    /// container-only path) instead; fixing this does not, on its own, explain or close that
    /// separate finding.
    ///
    /// Same shape of fix this project's own now-removed `LiveXcodeCompilerArgumentsProvider` once
    /// shipped for the analogous Xcode-side gap (PR #71: retry with a forced-clean rebuild when a
    /// parsed build log looks suspiciously incomplete) -- `swift package clean` (real, measured:
    /// ~11s) then a real full `swift build -v` (real, measured: ~93s for this project's own 178
    /// real source files) reliably produces a complete listing (confirmed: 1235 real compile lines
    /// after `clean`, matching the from-scratch `--build-path` figure above) without needing a
    /// wholly separate build directory (which would also re-resolve/re-fetch every dependency from
    /// scratch -- slower, and network-dependent). **Not free**: this real cost is paid only when
    /// the cheap incremental attempt already looks broken, matching PR #71's own accepted
    /// trade-off exactly -- correctness over always-cheap.
    ///
    /// **A fixed absolute floor alone is the wrong tool here -- found the hard way, by this fix's
    /// own first version regressing a real test.** This project's own `Tests/Fixtures/simple-actor`
    /// fixture has exactly one real Swift file; a fixed threshold of 10 would retry-with-clean
    /// *unconditionally* for it (any complete build already has fewer than 10 lines), doubling its
    /// real build cost every single time and -- confirmed directly, a real failure this session --
    /// racing a *different*, concurrently-running test's own build against the same shared fixture
    /// directory's `.build/build.db` (`"disk I/O error"`, real `swift build -v` output). Conversely,
    /// a fixed 10 is *too low* for a large real project: this project's own self-analysis (178 real
    /// files) produced incomplete parses of both 10 *and* 32 lines, and 32 is not `< 10`, so a flat
    /// floor alone would have missed exactly the corpus that motivated this whole investigation.
    /// `retryThreshold` instead scales with the analyzed project's own real file count (a quarter of
    /// it, floored at 1) when known, falling back to the fixed floor only when it genuinely isn't
    /// (an existing caller/test double that predates `expectedFileCount`).
    static let minimumUsableFileCountFallback = 10

    private func retryThreshold() -> Int {
        guard let expectedFileCount, expectedFileCount > 0 else { return Self.minimumUsableFileCountFallback }
        return max(1, expectedFileCount / 4)
    }

    /// `swift build -v` runs a real build once per process lifetime (subsequent calls reuse the
    /// cached parse) -- an incremental build if `.build` state already exists, matching this
    /// project's existing "don't force a rebuild you don't need" discipline elsewhere
    /// (`StalenessOrchestration`), *unless* that incremental attempt's own parse looks suspiciously
    /// incomplete (see `retryThreshold`'s own doc comment), in which case one retry with a
    /// forced-clean rebuild replaces it.
    private func loadArgumentsIfNeeded() throws -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedArguments {
            return cachedArguments
        }
        var parsed = try runAndParseBuildLog(forceClean: false)
        if parsed.count < retryThreshold() {
            parsed = try runAndParseBuildLog(forceClean: true)
        }
        cachedArguments = parsed
        return parsed
    }

    private func runAndParseBuildLog(forceClean: Bool) throws -> [String: [String]] {
        if forceClean {
            // Fail-soft on purpose: a `clean` failure (e.g. no prior `.build` at all) shouldn't
            // block the real build attempt that follows -- that attempt's own exit code is what
            // actually matters.
            _ = try? processRunning.run(executable: "swift", arguments: ["package", "clean"], workingDirectory: packageDirectory)
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
        return CompilerArgsLogParser.parse(buildLog: result.standardOutput)
    }
}
