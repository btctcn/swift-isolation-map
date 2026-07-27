import Foundation

/// Pure parsing of a real `swift build -v`/`xcodebuild build`-style verbose log into per-file
/// compiler arguments. No I/O, no process execution -- unit-testable against captured real log
/// text alone. Deliberately parses `swift-frontend` invocation lines specifically (not the
/// higher-level `swiftc` driver lines that sometimes precede them) -- verified empirically
/// against this project's own `swift build -v` output that every real per-file compile step is a
/// `swift-frontend -frontend -c -primary-file <file> <every sibling file in the module> ...
/// -target ... -sdk ... -module-name ...` line, which already carries everything `sourcekitd`'s
/// `key.compilerargs` needs -- the full sibling-file list included, so cross-file symbol
/// resolution within the same module works exactly like the real build's.
enum CompilerArgsLogParser {
    /// Maps each file path found as a `-primary-file` argument -- one per file for a plain
    /// single-file-per-invocation compile, or *several* per line under batch mode, where the
    /// driver groups multiple files into one `swift-frontend` invocation and marks each with its
    /// own `-primary-file` flag (confirmed empirically: a real CI run with fewer cores than a dev
    /// machine grouped multiple fixture files into shared batch lines, and mapping only the first
    /// `-primary-file` per line silently dropped the rest, throwing `argumentsNotFound` for files
    /// that were genuinely compiled) -- or, for whole-module-optimization compiles where no single
    /// file is ever marked primary, every `.swift` file named positionally in a `-wmo` invocation --
    /// to the full compiler argument list from that one line (everything after the executable path
    /// itself). A file that never appears as a compile target in the log (e.g. it wasn't actually
    /// built, or the log doesn't cover it) is simply absent from the result -- callers surface
    /// that as `CompilerArgumentsError.argumentsNotFound`, not a crash.
    static func parse(buildLog: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in buildLog.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("swift-frontend") else { continue }
            let tokens = tokenize(String(line))
            guard let executablePath = tokens.first, executablePath.hasSuffix("swift-frontend") else { continue }
            let args = Array(tokens.dropFirst())
            guard args.contains("-frontend") else { continue }

            let primaryIndices = args.indices.filter { args[$0] == "-primary-file" }
            if !primaryIndices.isEmpty {
                // Batch mode: the Swift driver groups several files into one `swift-frontend`
                // invocation, each marked with its own `-primary-file` flag (count/grouping driven
                // by core count, so this varies by machine -- confirmed empirically: a single-file-
                // per-batch run never hit this, but a lower-core CI runner grouping multiple files
                // per invocation did). Every primary file in the line maps to the same `args` --
                // `CompilerArgumentsSanitizing.sanitized` strips every `-primary-file` flag anyway
                // (keeping the file itself as a plain positional), so the sanitized result is
                // identical regardless of which of this batch's files it's requested for.
                for primaryIndex in primaryIndices {
                    let fileIndex = args.index(after: primaryIndex)
                    guard fileIndex < args.count else { continue }
                    result[args[fileIndex]] = args
                }
            } else if args.contains("-wmo") {
                for token in args where isLikelySwiftSourceFile(token) {
                    result[token] = args
                }
            }
        }
        return result
    }

    private static func isLikelySwiftSourceFile(_ token: String) -> Bool {
        token.hasSuffix(".swift") && !token.hasPrefix("-")
    }

    /// One target's real `swiftc` driver invocation from an `xcodebuild -verbose` build log, with
    /// the source file list still unresolved (an `@`-referenced response file path, not literal
    /// file arguments -- confirmed empirically against a real project's real build log, see
    /// docs/priority-3-phase-a-compiler-args.md: unlike SwiftPM's `-v` output, Xcode's new build
    /// system prints one driver-level line per target, not one `-primary-file` line per source
    /// file). Resolving `sourceFileListPath` into the real file list is I/O (reading that file),
    /// deliberately left to the caller -- this parser stays pure.
    struct XcodeCompileInvocation: Equatable {
        let sourceFileListPath: String
        let arguments: [String]
    }

    /// Every real per-target `swiftc` compile invocation in an `xcodebuild -verbose` log.
    /// Deliberately matches only the `builtin-Swift-Compilation --` build-log line (the one that
    /// actually compiles, `-c`/`-incremental`/`-enable-batch-mode`), not the similarly-named
    /// `builtin-Swift-Compilation-Requirements --` line (dependency-scanning only, no `-c`) or the
    /// bare `ExecuteExternalTool ... swiftc --version` sanity-check line that also appears in
    /// every real build log -- all three were present and distinguished in the real log this was
    /// verified against.
    static func parseXcodeSwiftCompileInvocations(buildLog: String) -> [XcodeCompileInvocation] {
        var results: [XcodeCompileInvocation] = []
        for line in buildLog.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("builtin-Swift-Compilation --") else { continue }
            guard let markerRange = line.range(of: "-- ") else { continue }
            let tokens = tokenize(String(line[markerRange.upperBound...]))
            guard let executablePath = tokens.first, executablePath.hasSuffix("swiftc") else { continue }
            var args = Array(tokens.dropFirst())
            guard let fileListIndex = args.firstIndex(where: { $0.hasPrefix("@") }) else { continue }
            let fileListPath = String(args[fileListIndex].dropFirst())
            args.remove(at: fileListIndex)
            results.append(XcodeCompileInvocation(sourceFileListPath: fileListPath, arguments: args))
        }
        return results
    }

    /// Minimal shell-word tokenizer: splits on whitespace, honoring single/double-quoted spans
    /// (real `-v` output quotes arguments containing `#`, e.g. `-external-plugin-path
    /// '.../plugins#.../swift-plugin-server'`, confirmed against this project's own build log) --
    /// a naive `.split(separator: " ")` would break such an argument into two tokens.
    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingleQuote = false
        var inDoubleQuote = false
        var hasContent = false
        var escaped = false

        for character in line {
            if escaped {
                current.append(character)
                hasContent = true
                escaped = false
                continue
            }
            switch character {
            // Real `xcodebuild -verbose` output backslash-escapes characters like `=` even
            // outside quotes (confirmed against a real build log: `-fmodule-map-file\=/path`) --
            // the backslash itself must be dropped, not kept as part of the argument.
            case "\\" where !inSingleQuote:
                escaped = true
                hasContent = true
            case "'" where !inDoubleQuote:
                inSingleQuote.toggle()
                hasContent = true
            case "\"" where !inSingleQuote:
                inDoubleQuote.toggle()
                hasContent = true
            case " ", "\t":
                guard !inSingleQuote && !inDoubleQuote else {
                    current.append(character)
                    hasContent = true
                    continue
                }
                if hasContent {
                    tokens.append(current)
                    current = ""
                    hasContent = false
                }
            default:
                current.append(character)
                hasContent = true
            }
        }
        if hasContent {
            tokens.append(current)
        }
        return tokens
    }
}
