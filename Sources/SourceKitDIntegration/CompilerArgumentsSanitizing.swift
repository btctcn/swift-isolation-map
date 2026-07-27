import Foundation

/// `key.compilerargs` must be **driver**-style (`swiftc`) arguments -- confirmed the hard way,
/// empirically, against a real fixture, not assumed: passing SwiftPM's real `swift build -v`
/// captured line verbatim (a **frontend**-level `swift-frontend -frontend -c -primary-file ...`
/// invocation, `ProjectResolution.CompilerArgsLogParser`'s own real, faithful capture of what the
/// build actually ran) makes every single cursor-info query fail with `sourcekitd`'s own
/// `"error creating ASTInvocation: error: unknown argument: '-frontend'"` and a dozen further
/// frontend-only flags the driver's argument parser rejects outright. `CompilerArgumentsProviding`
/// itself stays unchanged (it faithfully reports the real build's real arguments, useful on its
/// own terms) -- this sanitization is specific to what `sourcekitd` needs and lives here, applied
/// once, right before a cursor-info request is built.
public enum CompilerArgumentsSanitizing {
    /// Frontend-only flags confirmed, empirically, to make `sourcekitd` reject the whole request
    /// (`docs/priority-3-phase-e-fixtures.md`) -- not a guess at Swift driver/frontend flag
    /// documentation, which doesn't exhaustively enumerate this boundary anywhere. `true` means
    /// the flag takes a following value argument that must be dropped along with it.
    private static let frontendOnlyFlags: [String: Bool] = [
        "-frontend": false,
        // `-primary-file <file>` is dropped, but `<file>` itself is deliberately *not* --
        // real captured `swift build -v` output shows the primary file as this flag's own value,
        // with every *sibling* file already listed as a separate bare positional right after it,
        // so dropping the flag alone (keeping the value) turns the line into exactly what a plain
        // driver-level `swiftc file1.swift file2.swift ... -flags` invocation looks like -- the
        // full file list stays intact, just with no `-primary-file` marker at all.
        "-primary-file": false,
        "-emit-dependencies-path": true,
        "-emit-reference-dependencies-path": true,
        "-enable-objc-interop": false,
        "-new-driver-path": true,
        "-empty-abi-descriptor": false,
        "-enable-anonymous-context-mangled-names": false,
        "-disable-clang-spi": false,
        "-target-sdk-version": true,
        "-target-sdk-name": true,
        "-index-system-modules": false,
        "-serialize-diagnostics-path": true
    ]

    public static func sanitized(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if let takesValue = frontendOnlyFlags[argument] {
                skipNext = takesValue
                continue
            }
            result.append(argument)
        }
        return result
    }
}
