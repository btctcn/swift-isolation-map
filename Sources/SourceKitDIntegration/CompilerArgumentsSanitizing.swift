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

    /// Root cause of the `<unknown>:0: error: unknown argument: '-enable-anonymous-context-mangled-
    /// names'` stderr noise (docs/task-anonymous-context-mangled-names-noise.md, issue #120) --
    /// confirmed directly against real `swiftlang/swift` source, not the frontend-rejection
    /// reasoning `frontendOnlyFlags` above documents (bare `-g` is itself a perfectly valid driver
    /// argument; sourcekitd never rejects *it*). `lib/Driver/ToolChains.cpp`'s real condition:
    ///
    /// ```cpp
    /// if (inputArgs.hasArg(options::OPT_g)) {
    ///   auto OptArg = inputArgs.getLastArgNoClaim(options::OPT_O_Group);
    ///   if (!OptArg || OptArg->getOption().matches(options::OPT_Onone))
    ///     arguments.push_back("-enable-anonymous-context-mangled-names");
    /// ```
    ///
    /// -- confirmed against `include/swift/Option/Options.td` that `OPT_g` matches *only* the bare
    /// `-g` flag, never `-gnone`/`-gline-tables-only`/`-gdwarf-types` (each its own, separate option
    /// ID, despite sharing `g_Group` for help-text organization only) -- so removing exactly the
    /// literal `-g` token, and nothing else in that family, is both necessary and sufficient to stop
    /// sourcekitd's own driver-emulation logic from ever reaching this branch. A real Debug-
    /// configuration build (Xcode's own default, and SwiftPM's) is exactly `-g` plus `-Onone`/no
    /// `-O` at all -- confirmed against this project's own real captured fixture build logs
    /// (`Tests/Fixtures/*/.build/debug.yaml`), matching the condition precisely. `cursorinfo`'s own
    /// semantic query (type/USR/isolation-attribute lookup on an already-type-checked AST) has no
    /// use for debug info at all, so dropping `-g` changes nothing about what a query can resolve --
    /// confirmed via a real before/after CLI run against Project Iris (docs/task-anonymous-context-
    /// mangled-names-noise.md): byte-identical `crossActorBoundaries`/`highRiskBoundaries`/
    /// `unspecifiedIsolation`, zero occurrences of the diagnostic in a previously-reproducing run.
    private static let debugInfoFlagsThatTriggerSourcekitdsOwnBuggyReinjection: Set<String> = ["-g"]

    /// docs/task-anonymous-context-mangled-names-noise.md's own real-corpus verification found that
    /// stripping `-g` lets sourcekitd's internal driver-emulation logic proceed *further* into its
    /// own default-argument computation than it could before -- issue #135 (docs/task-external-
    /// plugin-path-noise.md) is the second, separate bug that further progress newly reaches, not a
    /// regression in the `-g` fix itself. Investigating *why* `-g`'s presence had been masking it led
    /// to this file's real root cause, fixed directly above (the `-Xcc`/`-Xfrontend` orphan repair in
    /// `sanitized(_:)`) -- `-external-plugin-path` itself needs no special-casing at all once that
    /// repair is in place; it was never sourcekitd's own value that was the problem (an early attempt
    /// to supply a correct, verified-existing toolchain-relative value in its place was empirically
    /// falsified: identical error count, just renamed). A real, isolated-file A/B against Project
    /// Iris confirmed the fix directly: dropping the blanket `-external-plugin-path` strip this entry
    /// used to also carry *increased* `crossActorBoundaries` by 10 and `unspecifiedIsolation` by 2,
    /// converging exactly on the same numbers a real pre-issue-#120 build (`-g` still present, before
    /// either fix existed) produces -- the blanket strip had been silently masking a real 10-edge
    /// discrepancy the `-Xcc`/`-Xfrontend` repair actually resolves, not just hides.
    ///
    /// `-plugin-path` is the one entry still kept here, for a *separate*, confirmed-but-narrower
    /// defect: a real Swift Testing target file legitimately carries `-plugin-path <toolchain>/usr/
    /// lib/swift/host/plugins/testing` -- a real, correct, *existing* directory, put there by the
    /// real build system itself, unrelated to any `-Xcc` orphaning (confirmed: no `-Xcc` precedes it
    /// in the real captured arguments). sourcekitd's own `fileContentsForFilesInCompilerInvocation`/
    /// `getBufferStamp` file-content pre-loading step still can't tell a directory from a file it
    /// should read, failing with "Is a directory" -- reproduced directly via a live `lldb` breakpoint
    /// on `ArgsToFrontendInputsConverter::addFile` for this exact value. Not observed at real Project
    /// Iris corpus scale in practice (a real A/B with this entry disabled found zero "Is a directory"
    /// occurrences and byte-identical `crossActorBoundaries`/`highRiskBoundaries`/`unspecifiedIsolation`
    /// either way) -- kept anyway as a cheap, confirmed-harmless defensive fix for the one file shape
    /// that does trigger it.
    private static let pluginPathFlagsThatSourcekitdMisreadsAsFileContent: [String: Bool] = [
        "-plugin-path": true
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
                // `-fretain-comments-from-system-headers` (and potentially others in this list)
                // can arrive as the tail of a real `-Xcc -Xclang -Xcc <flag>` unit -- Swift's own
                // idiom for forwarding a flag straight to Clang's cc1, bypassing its driver
                // (confirmed directly against a real Project Iris file,
                // docs/task-external-plugin-path-noise.md, issue #135's real root cause). Dropping
                // only the trailing `<flag>` -- or naively popping just the immediately-preceding
                // `-Xcc` -- corrupts every *other*, untouched `-Xcc -Xclang -Xcc <flag>` unit that
                // follows: Clang's own driver re-pairs "-Xclang" with whatever token the shifted
                // count leaves next to it. Confirmed the hard way: a real, reproduced cascading
                // "-Xclang: unknown argument" failure from the naive single-token-pop version of
                // this fix. Removing the whole 4-token unit keeps every other unit's own pairing
                // intact.
                if result.count >= 3, result[result.count - 1] == "-Xcc",
                   result[result.count - 2] == "-Xclang", result[result.count - 3] == "-Xcc" {
                    result.removeLast(3)
                } else if result.last == "-Xcc" || result.last == "-Xfrontend" {
                    // `-Xfrontend <flag>` is the same real idiom as `-Xcc <flag>`, one level up
                    // (forwards `<flag>` straight to `swift-frontend`, bypassing the *driver's* own
                    // validation) -- confirmed against a second, real orphaning case in the same
                    // file: `-Xfrontend -empty-abi-descriptor`. Popping only the trailing flag here
                    // leaves a bare `-Xfrontend` that then swallows whatever real token comes next
                    // (here, the start of the next unit's own `-Xcc`), corrupting it identically.
                    result.removeLast()
                }
                skipNext = takesValue
                continue
            }
            if debugInfoFlagsThatTriggerSourcekitdsOwnBuggyReinjection.contains(argument) {
                continue
            }
            if let takesValue = pluginPathFlagsThatSourcekitdMisreadsAsFileContent[argument] {
                skipNext = takesValue
                continue
            }
            result.append(argument)
        }
        return result
    }
}
