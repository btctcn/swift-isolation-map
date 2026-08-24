import Foundation

/// `ProjectResolution` is a library target with no access to the executable's own `eprint`
/// (`swift-isolation-map/SwiftIsolationMap.swift`) -- a local, minimal equivalent, same stderr-only
/// rationale (never stdout, which `--output`'s actual report needs to stay safely pipeable).
func writeStderr(_ message: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((message + terminator).utf8))
}

/// Legacy/fallback conformer for Xcode projects -- `SwiftBuildCompilerArgumentsProvider` is the
/// main path since docs/task-swift-build-prepare-for-indexing-spike.md's Steps 13-26 real-corpus-
/// verified it end to end; this type is no longer reachable from any CLI flag, but kept in the tree
/// rather than deleted (months of prior production mileage, in case the direct `swift-build` API
/// path ever needs a fallback). The one remaining production call site
/// (`SwiftIsolationMap.makeCompilerArgumentsProvider`) only falls through here when
/// `derivedDataPath` is `nil`, which that method's own doc comment already documents as a state
/// this project's invariants say can't happen for an Xcode container -- deliberately left as a
/// live (if practically unreachable) fallback rather than a force-unwrap, so the deprecation
/// warning it now produces there is expected, not a sign of a missed cleanup.
///
/// Real per-file `swiftc` compiler arguments for an Xcode project/workspace, obtained by running
/// a real `xcodebuild -verbose ... build` and parsing the log -- see
/// docs/priority-3-phase-a-compiler-args.md for the decision record and the empirical finding
/// that motivates this shape: Xcode's new build system logs one driver-level `swiftc` invocation
/// per *target* (source file list behind an `@`-referenced response file), not one line per file
/// the way SwiftPM's `-v` output does. Every file in a target's expanded file list shares that
/// target's one argument list, mirroring `CompilerArgsLogParser`'s existing whole-module-
/// optimization fallback for SwiftPM.
@available(*, deprecated, message: "Superseded by SwiftBuildCompilerArgumentsProvider (the default path for Xcode projects/workspaces since PR #108). Kept only as an unreachable-from-the-CLI legacy fallback -- see this type's own doc comment.")
public final class LiveXcodeCompilerArgumentsProvider: CompilerArgumentsProviding, @unchecked Sendable {
    private let container: ProjectContainer
    private let scheme: String
    private let processRunning: ProcessRunning
    private let fileSystem: FileSystemQuerying
    /// EXPERIMENTAL (docs/task-private-derived-data-hypothesis.md) -- when non-`nil`, every
    /// `xcodebuild` invocation this provider runs targets this private location (`-derivedDataPath`)
    /// instead of Xcode's own shared default, so the compiler-argument-resolution build and the
    /// index-store-populating build (`SwiftIsolationMap.build`) always agree on where the same
    /// run's own build artifacts live -- never `nil` and `non-nil` mixed within one invocation.
    private let derivedDataPath: URL?
    private let lock = NSLock()
    private var cachedArguments: [String: [String]]?
    private var cachedModuleNames: Set<String>?
    private var cachedError: Error?
    private let skipMacroValidation: Bool
    // Resolved once per provider instance, not once per `runVerboseBuild` attempt -- the plain-vs-
    // clean retry in `loadArgumentsIfNeeded` would otherwise re-run the `-showdestinations` probe a
    // second time for no reason; the destination doesn't change between the two attempts.
    private var cachedDestination: String??

    /// See `loadArgumentsIfNeeded`'s own doc comment for the real failure this guards against --
    /// a plain build result covering fewer files than this is treated the same as an empty one,
    /// triggering the clean-rebuild retry.
    private static let minimumUsableFileCount = 10

    public init(
        container: ProjectContainer,
        scheme: String,
        processRunning: ProcessRunning = LiveProcessRunner(),
        fileSystem: FileSystemQuerying = LiveFileSystem(),
        skipMacroValidation: Bool = false,
        derivedDataPath: URL? = nil
    ) {
        self.container = container
        self.scheme = scheme
        self.processRunning = processRunning
        self.fileSystem = fileSystem
        self.skipMacroValidation = skipMacroValidation
        self.derivedDataPath = derivedDataPath
    }

    public func compilerArguments(forFile path: String) throws -> [String] {
        let argumentsByFile = try loadArgumentsIfNeeded()
        guard let arguments = argumentsByFile[path] else {
            throw CompilerArgumentsError.argumentsNotFound(file: path)
        }
        return arguments
    }

    /// The real `-module-name` value of every target this instance's own real build compiled --
    /// see `RawIndexStoreClient.allowedModuleNames`'s own doc comment for what this exists to feed.
    /// Best-effort: a build that failed outright (`loadArgumentsIfNeeded` throwing, `cachedError`
    /// already set) has no module names to report, `nil` here exactly like `compilerArguments
    /// (forFile:)` would throw for the same reason -- callers of *this* method (unlike
    /// `compilerArguments(forFile:)`'s own single-file callers) have no natural per-file fallback,
    /// so failure is reported as "unknown" (disables filtering) rather than propagated.
    public func realModuleNames() -> Set<String>? {
        _ = try? loadArgumentsIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return cachedModuleNames
    }

    private func loadArgumentsIfNeeded() throws -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedArguments {
            return cachedArguments
        }
        // A thrown failure must be memoized exactly like a successful result -- `compilerArguments
        // (forFile:)`'s only caller, `detectConfiguredDefaultIsolation`, walks every source file in
        // a loop and swallows this method's throw via `try?` to move on to the next file. Without
        // caching the failure too, a build that's genuinely, persistently unbuildable (confirmed
        // against a real project once its provisioning-profile bug was still unfixed: every single
        // attempt threw `buildLogParseFailed`) reran the full, expensive double-`xcodebuild`
        // (plain + `clean`) cycle from scratch for *every remaining source file* -- observed as
        // dozens of independent `xcodebuild` invocations firing every few seconds against a real,
        // ~424-file project, instead of failing once and letting every subsequent file's lookup
        // fail cheaply from the cache.
        if let cachedError {
            throw cachedError
        }

        do {
            // An already-fully-built target (the common case for a repeated analysis run, or any CI
            // pipeline that just built the app before invoking this tool) makes Xcode's incremental
            // build system skip re-emitting `builtin-Swift-Compilation --` lines entirely -- `-verbose`
            // only echoes commands the build system actually decides to run, and "nothing needs
            // rebuilding" means zero such lines, confirmed empirically against `Project Iris` (`docs/
            // priority-3-compiled-dependency-isolation.md`: a real `xcodebuild -verbose build` against
            // an up-to-date project produced zero compile invocations, silently starving every
            // external-isolation query downstream). The only reliable fix is forcing every file to be
            // considered dirty, which only a real `clean build` guarantees.
            //
            // A literal `parsed.isEmpty` check isn't enough, though -- confirmed the hard way against
            // a real, repeatedly-analyzed Swiftfin checkout (docs/task-sourcekitd-cooperative-pool-
            // starvation.md's real root cause, despite that doc's own title: chasing a `sourcekitd`
            // theory for this exact symptom was a dead end, this was the actual bug). On an otherwise
            // fully-built 773-file project, Xcode's incremental build system sometimes decides only
            // one small, unrelated target needs rebuilding (a single-digit file count from 1-2
            // `builtin-Swift-Compilation` invocations, not the whole app target) -- non-empty, so the
            // old check silently accepted and cached this near-useless map for the rest of the run,
            // starving *every* other file's lookup with `argumentsNotFound`. `minimumUsableFileCount`
            // is a deliberately conservative heuristic threshold (not zero, not the real project's
            // full file count, which this provider doesn't know) -- high enough to reliably catch
            // "only a stray unrelated target rebuilt" the same way the real failure did. **Not a free
            // lunch**: a genuinely tiny real project (fewer real Swift files than the threshold)
            // triggers this same retry every single run, unconditionally -- one harmless but
            // unnecessary extra `clean` rebuild (this whole method only runs once per process,
            // memoized below, so the cost is a one-time constant, not per-file). And the retry is
            // exactly one attempt, not a loop: whatever the `clean` rebuild returns -- even if *it*
            // also comes back under the threshold, whether from a genuinely tiny project or from this
            // same bug somehow surviving a clean build too -- is accepted as final and cached; any
            // file missing from that map still fails soft, one `argumentsNotFound` throw at a time,
            // exactly like before this fix.
            let destination: String?
            if let cachedDestination {
                destination = cachedDestination
            } else {
                destination = resolveDeterministicSimulatorDestination(
                    container: container, scheme: scheme, processRunning: processRunning, derivedDataPath: derivedDataPath
                )
                cachedDestination = destination
            }
            var (parsed, moduleNames) = try runVerboseBuild(extraActions: [], destination: destination)
            if parsed.count < Self.minimumUsableFileCount {
                // Silent until now: a plain build against an already-up-to-date project (the common
                // case right after this same run's own `--force-reindex`, or any CI pipeline that
                // just built the app) routinely hits this retry, and the clean rebuild it triggers
                // can take real minutes on a large project -- confirmed directly against a real,
                // ~40-dependency workspace (issue report: a user's run produced a report dominated by
                // `unknown`/`unspecified` edges with zero indication anything unusual had happened).
                // One line, not gated behind `--verbose`: this is exactly the kind of "why is this
                // taking so long, and is it stuck" moment `--verbose`'s deeper per-file detail doesn't
                // help with, and a plain hang with no output at all is what erodes trust in the tool's
                // output once results do come back thin.
                writeStderr(
                    "Initial build produced too few real compiler invocations (\(parsed.count) file(s), " +
                    "likely already up to date) -- retrying with a clean rebuild for compiler-argument " +
                    "resolution. This can take a while on a large project."
                )
                (parsed, moduleNames) = try runVerboseBuild(extraActions: ["clean"], destination: destination)
            }
            cachedArguments = parsed
            cachedModuleNames = moduleNames
            return parsed
        } catch {
            cachedError = error
            throw error
        }
    }

    private func runVerboseBuild(extraActions: [String], destination: String?) throws -> (arguments: [String: [String]], moduleNames: Set<String>) {
        var arguments = ["-verbose"]
        if skipMacroValidation {
            arguments.append("-skipMacroValidation")
        }
        arguments += ["-scheme", scheme]
        switch container {
        case .xcodeproj(let url):
            arguments += ["-project", url.path]
        case .xcworkspace(let url):
            arguments += ["-workspace", url.path]
        case .swiftPackage:
            preconditionFailure("LiveXcodeCompilerArgumentsProvider is only valid for .xcodeproj/.xcworkspace containers")
        }
        // Shared with SwiftIsolationMap.build's --auto-build path -- see
        // `xcodeIndexingBuildSettings`'s own doc comment for why each setting is here (in
        // particular, why code signing must be disabled), and
        // `resolveDeterministicSimulatorDestination`'s for why the destination itself must also be
        // pinned down explicitly. Resolved once by the caller, not per attempt -- see
        // `cachedDestination`'s own comment.
        if let destination {
            arguments += ["-destination", destination]
        }
        if let derivedDataPath {
            arguments += ["-derivedDataPath", derivedDataPath.path]
        }
        arguments += xcodeIndexingBuildSettings + extraActions + ["build"]

        let result = try processRunning.run(executable: "xcodebuild", arguments: arguments, workingDirectory: nil)

        // Every invocation that mentions a given file is kept (not just the first/last one seen)
        // -- `SwiftBuildCompilerArgumentsProvider.preferredArguments`'s own doc comment explains
        // why: `WordPressShareExtension`/`WordPressDraftActionExtension` both compile the same 14
        // files under `.../WordPress/WordPressShareExtension/Sources/...`, and this provider used
        // to let whichever target's compile line the `-verbose` log happened to print *last* win
        // via a plain dictionary overwrite -- an arbitrary artifact of xcodebuild's own build-graph
        // ordering for this run, not a meaningful choice (confirmed the hard way,
        // docs/task-swift-build-prepare-for-indexing-spike.md Step 25: a real run resolved this
        // exact shared-file group to `WordPressDraftActionExtension`'s args, silently feeding every
        // downstream live oracle query -- e.g. an external protocol conformance's own isolation --
        // the *wrong* target's compiled context, producing a real, reproducible divergence against
        // `SwiftBuildCompilerArgumentsProvider` (the main path since Step 25 shipped), which
        // already got this right via #106). Reusing the identical `preferredArguments` home-
        // directory heuristic here closes
        // the same gap for this provider, using each invocation's own `-module-name` as the
        // candidate's identity -- the same real string `indexstore_unit_reader_get_module_name`
        // reports for the same compiled unit, and identical to the target name for every real
        // target this project has hit so far (see the module-name-collection comment below for the
        // one confirmed case, `Ls.net.ru`, where they'd differ -- irrelevant here since that
        // project has no shared-file target group to disambiguate in the first place).
        var candidatesByPath: [String: [(targetName: String, args: [String])]] = [:]
        var moduleNames: Set<String> = []
        for invocation in CompilerArgsLogParser.parseXcodeSwiftCompileInvocations(buildLog: result.standardOutput) {
            let files = try expandFileList(at: invocation.sourceFileListPath)
            let fullArguments = invocation.arguments + files
            // The real, compiled module name for this target -- `RawIndexStoreClient
            // .allowedModuleNames`'s own doc comment explains what this set feeds. Read directly
            // from this same real `-verbose` line rather than derived from the target name shown
            // in the log's own `(in target 'X' ...)` annotation, which is never guaranteed to match
            // (Swift module names can't contain characters a target name can, e.g. `Ls.net.ru`'s
            // own real module name is `Ls_net_ru`) -- `-module-name`'s own value is the same string
            // `indexstore_unit_reader_get_module_name` reports for the same compiled unit.
            var moduleName = ""
            if let moduleNameIndex = invocation.arguments.firstIndex(of: "-module-name"),
               invocation.arguments.index(after: moduleNameIndex) < invocation.arguments.endIndex {
                moduleName = invocation.arguments[invocation.arguments.index(after: moduleNameIndex)]
                moduleNames.insert(moduleName)
            }
            for file in files {
                candidatesByPath[file, default: []].append((targetName: moduleName, args: fullArguments))
            }
        }

        var parsed: [String: [String]] = [:]
        parsed.reserveCapacity(candidatesByPath.count)
        for (file, candidates) in candidatesByPath {
            parsed[file] = SwiftBuildCompilerArgumentsProvider.preferredArguments(candidates: candidates, filePath: file)
        }

        // A non-zero `xcodebuild` exit code alone does not invalidate compiler-invocation lines
        // already captured for targets that DID compile successfully -- confirmed against a real
        // `Project Iris` build where the main app target compiles cleanly (and its invocations parse
        // fine) while a *different*, unrelated target (e.g. a notification extension with an
        // unresolved dependency) fails the overall exit code. Throwing unconditionally on a
        // non-zero exit code discarded everything already parsed, and since `cachedArguments` is
        // only ever set on a successful return from `loadArgumentsIfNeeded`, that forced *every
        // single subsequent distinct file lookup* to repeat this whole (expensive, minutes-long)
        // `xcodebuild -verbose` invocation from scratch -- observed as an apparent hang gating a
        // real ~1400 distinct live-query file groups against `Project Iris`. Only treat this as a hard,
        // unrecoverable failure when nothing at all could be recovered from the log.
        guard result.exitCode == 0 || !parsed.isEmpty else {
            throw CompilerArgumentsError.buildLogParseFailed(
                reason: "xcodebuild -verbose \((extraActions + ["build"]).joined(separator: " ")) exited \(result.exitCode) and produced no usable compiler invocations: \(result.standardError)"
            )
        }
        return (parsed, moduleNames)
    }

    /// The `@`-referenced response file is one absolute source path per line -- confirmed against
    /// a real `SwiftFileList` produced by a real Xcode build. **A path containing a space is
    /// backslash-escaped** (`News\ List/NewsController.swift`, confirmed against a real file list
    /// for a real project with space-containing directory names, `Project Iris`'s own `UI/News/News List`)
    /// -- a plain per-line split alone leaves the literal backslash in the resulting path string,
    /// which then never matches the real filesystem entry. Root-caused after real-world validation
    /// showed every single live `cursorinfo` query against `Project Iris` separately failing to `stat`
    /// ~130 sibling files each time (confirmed via the same real project) -- every file under a
    /// space-containing directory in the *entire compile unit's* sibling-file list, on *every*
    /// query, not merely cosmetic stderr noise as first assumed.
    private func expandFileList(at path: String) throws -> [String] {
        let url = URL(fileURLWithPath: path)
        guard fileSystem.fileExists(at: url) else {
            throw CompilerArgumentsError.buildLogParseFailed(reason: "referenced file list not found: \(path)")
        }
        let data = try fileSystem.readData(at: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CompilerArgumentsError.buildLogParseFailed(reason: "file list not UTF-8: \(path)")
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { Self.unescaped(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// Drops each backslash escape character, keeping whatever it precedes literally -- mirrors
    /// `CompilerArgsLogParser.tokenize`'s own backslash handling (real captured `-verbose` output
    /// backslash-escapes characters like `=` even outside quotes), applied here to one already
    /// newline-delimited path per line rather than a whitespace-delimited argument list.
    static func unescaped(_ line: String) -> String {
        var result = ""
        var escaped = false
        for character in line {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
