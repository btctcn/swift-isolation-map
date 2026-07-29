import Foundation

/// Real per-file `swiftc` compiler arguments for an Xcode project/workspace, obtained by running
/// a real `xcodebuild -verbose ... build` and parsing the log -- see
/// docs/priority-3-phase-a-compiler-args.md for the decision record and the empirical finding
/// that motivates this shape: Xcode's new build system logs one driver-level `swiftc` invocation
/// per *target* (source file list behind an `@`-referenced response file), not one line per file
/// the way SwiftPM's `-v` output does. Every file in a target's expanded file list shares that
/// target's one argument list, mirroring `CompilerArgsLogParser`'s existing whole-module-
/// optimization fallback for SwiftPM.
public final class LiveXcodeCompilerArgumentsProvider: CompilerArgumentsProviding, @unchecked Sendable {
    private let container: ProjectContainer
    private let scheme: String
    private let processRunning: ProcessRunning
    private let fileSystem: FileSystemQuerying
    private let lock = NSLock()
    private var cachedArguments: [String: [String]]?

    public init(
        container: ProjectContainer,
        scheme: String,
        processRunning: ProcessRunning = LiveProcessRunner(),
        fileSystem: FileSystemQuerying = LiveFileSystem()
    ) {
        self.container = container
        self.scheme = scheme
        self.processRunning = processRunning
        self.fileSystem = fileSystem
    }

    public func compilerArguments(forFile path: String) throws -> [String] {
        let argumentsByFile = try loadArgumentsIfNeeded()
        guard let arguments = argumentsByFile[path] else {
            throw CompilerArgumentsError.argumentsNotFound(file: path)
        }
        return arguments
    }

    private func loadArgumentsIfNeeded() throws -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedArguments {
            return cachedArguments
        }

        // An already-fully-built target (the common case for a repeated analysis run, or any CI
        // pipeline that just built the app before invoking this tool) makes Xcode's incremental
        // build system skip re-emitting `builtin-Swift-Compilation --` lines entirely -- `-verbose`
        // only echoes commands the build system actually decides to run, and "nothing needs
        // rebuilding" means zero such lines, confirmed empirically against `Project Iris` (`docs/
        // priority-3-compiled-dependency-isolation.md`: a real `xcodebuild -verbose build` against
        // an up-to-date project produced zero compile invocations, silently starving every
        // external-isolation query downstream). The only reliable fix is forcing every file to be
        // considered dirty, which only a real `clean build` guarantees -- so an empty first attempt
        // triggers exactly one retry with `clean` prepended, never a silent empty result.
        var parsed = try runVerboseBuild(extraActions: [])
        if parsed.isEmpty {
            parsed = try runVerboseBuild(extraActions: ["clean"])
        }
        cachedArguments = parsed
        return parsed
    }

    private func runVerboseBuild(extraActions: [String]) throws -> [String: [String]] {
        var arguments = ["-verbose", "-scheme", scheme]
        switch container {
        case .xcodeproj(let url):
            arguments += ["-project", url.path]
        case .xcworkspace(let url):
            arguments += ["-workspace", url.path]
        case .swiftPackage:
            preconditionFailure("LiveXcodeCompilerArgumentsProvider is only valid for .xcodeproj/.xcworkspace containers")
        }
        // Same real, empirically-confirmed build setting as SwiftIsolationMap.build's existing
        // --auto-build path (a bare KEY=VALUE argument, not a `-flag` -- see
        // docs/priority-2-phase-4-cli-wiring.md for the flag-form bug this already caught once).
        arguments += ["COMPILER_INDEX_STORE_ENABLE=YES"] + extraActions + ["build"]

        let result = try processRunning.run(executable: "xcodebuild", arguments: arguments, workingDirectory: nil)

        var parsed: [String: [String]] = [:]
        for invocation in CompilerArgsLogParser.parseXcodeSwiftCompileInvocations(buildLog: result.standardOutput) {
            let files = try expandFileList(at: invocation.sourceFileListPath)
            let fullArguments = invocation.arguments + files
            for file in files {
                parsed[file] = fullArguments
            }
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
        return parsed
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
