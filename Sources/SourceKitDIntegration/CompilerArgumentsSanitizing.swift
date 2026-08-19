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
        // Not frontend-only, the reverse: a **driver**-only flag real Xcode incremental builds
        // put in the captured build log, that `sourcekitd`'s own ASTInvocation builder rejects --
        // confirmed empirically against real WordPress-iOS/Swiftfin live-oracle runs, both showing
        // `error creating ASTInvocation: warning: option '-incremental' is only supported in
        // swift-driver` on effectively every cursor-info request. Meaningless for a single
        // `key.compilerargs` query anyway (it only affects caching across repeated whole-build
        // invocations), so dropping it is strictly correct, not just a workaround.
        "-incremental": false,
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
        "-serialize-diagnostics-path": true,
        // Bare (not `-Xcc`-prefixed) in `swift-build`'s own `generateIndexingFileSettings`
        // response under `action = "indexbuild"` (docs/task-swift-build-prepare-for-indexing-
        // spike.md) -- confirmed empirically against a real regression: switching that provider's
        // own `action` from `"build"` to `"indexbuild"` (needed to fix a real Swiftfin app-target
        // failure) broke every single Project Iris cursor-info query with `sourcekitd`'s own
        // `"error creating ASTInvocation: error: unknown argument: '-fretain-comments-from-system-
        // headers'"` -- a real Clang-only flag the Swift driver's own argument parser rejects
        // outright, exactly the same failure shape as this list's other driver-vs-frontend
        // mismatches, just sourced from a different provider than the ones that motivated this
        // file originally.
        "-fretain-comments-from-system-headers": false,
        // Same `action = "indexbuild"` source as `-fretain-comments-from-system-headers` above --
        // confirmed empirically against a second real Project Iris regression check after the
        // first fix: `-working-directory <path>` also produces `sourcekitd`'s own `"unknown
        // argument: '-working-directory'"` under this provider's args, for a different
        // target/file than the one used to diagnose the first flag (not visible in a single-file
        // A/B diff of `build` vs `indexbuild` args, only in the full multi-target real run).
        // Meaningless for a single `key.compilerargs` query anyway, same as `-incremental` above --
        // it only affects relative-path resolution across a whole build's own multiple
        // invocations, and every path in a live query's own argument list is already absolute.
        "-working-directory": true
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
