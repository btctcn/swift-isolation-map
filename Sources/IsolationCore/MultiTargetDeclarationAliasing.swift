import Foundation

/// A sixth, structurally distinct real gap: unlike every other `ExternalIsolationBackfill` matcher
/// (which resolve genuinely *external* Clang/SDK USRs), this one resolves a call-graph edge whose
/// `calleeUSR` is a **project-local** declaration -- just compiled under a *sibling Xcode target's*
/// own module namespace, never the analyzed scheme's own.
///
/// **Root cause, confirmed via a real, from-scratch minimal reproduction** (a 3-target Xcode
/// project -- one app target plus two embedded app-extension targets, generated with `xcodegen`,
/// fully reverted after use -- sharing one source file across all three targets' own `Sources`
/// build phases, exactly matching the real corpus's own `AppGroupFetcher.swift`/
/// `ExtensionListener.swift`, each a member of three separate `PBXBuildFile` entries in the real
/// `.pbxproj`): a source file that's a member of multiple targets is compiled once per target, and
/// the real Swift indexer records one full set of occurrences per compiled unit -- so the *same*
/// physical property (`AppGroupFetcher.hostApplicationName`) ends up with three real, distinct,
/// module-qualified USRs, one per target. `DeclarationLinker`'s own per-file syntactic-to-real USR
/// rewrite only ever picks *one* winning candidate at a given (line, column) (`disambiguate`'s own
/// "exact name match" rule, with no notion of "which target" at all) -- so only one target's own
/// variant of the declaration ever enters `linked.declarations` with a real location. The other two
/// targets' own call-graph edges (recorded by the *same* multi-unit index-store scan, independent
/// of which target's variant won the disambiguation) reference `calleeUSR`s that are simply absent
/// from `declarations` -- genuinely project-local, yet **not** externally resolvable either:
/// `compilerArguments(forFile:)` is scoped to the *one* analyzed scheme's own build log, so a live
/// `cursorinfo` query at that same file/line always resolves through *that* scheme's own compiled
/// unit, never matching a sibling target's own differently-module-qualified `targetUSR` by strict
/// equality -- and none of this project's other five matchers apply either, since this isn't a
/// Clang-bridging shape at all.
///
/// **The real mangling fact that makes this safely fixable without any live query**: a Swift USR's
/// module-name component is always the *first* length-prefixed identifier immediately after `"s:"`
/// -- everything after it (the type/member path, accessor markers) is a pure function of the
/// *declaration itself*, never the compiling target, confirmed byte-for-byte identical across all
/// three real module-qualified variants of `hostApplicationName`
/// (`s:9Ls_net_ru15AppGroupFetcherC19hostApplicationNameSSSgvp`,
/// `s:31lsboutiqueNotifications_Release15AppGroupFetcherC19hostApplicationNameSSSgvp`,
/// `s:34lsboutiqueContentExtension_Release15AppGroupFetcherC19hostApplicationNameSSSgvp` all share
/// the identical `"15AppGroupFetcherC19hostApplicationNameSSSgvp"` suffix). So a calleeUSR absent
/// from `declarations`, once its own module-name component is stripped, can be looked up by that
/// remaining suffix against every *already-linked* (real `location`, not itself a placeholder)
/// project-local declaration's own suffix -- a match means "the same declaration, a different
/// target," and its already-fully-known `DeclarationInfo` (including `containingTypeUSR`, so
/// inheritance/module-default resolution downstream works identically to the winning variant) can
/// be reused verbatim under the new USR key, zero live query needed.
///
/// **A known limitation of *this* cheap suffix comparison alone -- already closed by a fallback,
/// not left open (issue #122 reopened this question by reading only this doc comment, which had
/// never been updated since; corrected here)**: Swift's own mangling substitution compression can
/// make two module-qualified variants' suffixes *diverge* when the module name happens to be a
/// textual prefix of the type name (confirmed directly while building this fix's own mini
/// reproduction: naming the test app target `"App"`, a prefix of `"AppGroupFetcher"`, triggered a
/// compressed `"0A12GroupFetcherC..."` suffix instead of the uncompressed `"15AppGroupFetcherC..."`
/// form) -- a false *negative* here (this exact-string comparison simply doesn't fire for that one
/// variant), never a false positive, matching this project's own "a wrong answer is worse than no
/// answer" principle. `ExternalIsolationBackfill.collectEdgeLevelWorkItems` runs `
/// DemangledSiblingMatching`'s own real-`swift-demangle`-based fallback (immune to compression by
/// construction) on exactly the USRs this comparison misses, closing the gap without weakening this
/// type's own zero-query, exact-string matching -- see that fallback's own doc comment, and PR #99
/// (2026-08-16, real Project Iris verification: unresolved edges 81 -> 46).
public enum MultiTargetDeclarationAliasing {
    /// Reads one length-prefixed identifier per Swift's own real mangling convention. `nil` (not
    /// this shape at all) whenever the byte right after `"s:"` isn't a digit -- this is exactly
    /// what naturally excludes every Swift-stdlib substitution (`s:Sb...`, `s:Si...`) and every
    /// imported-Clang USR (`s:So...`), neither of which is ever a length-prefixed real module name.
    public static func moduleNameAndSuffix(ofSwiftUSR usr: String) -> (moduleName: String, suffix: String)? {
        let prefix = "s:"
        guard usr.hasPrefix(prefix) else { return nil }
        var remainder = usr.dropFirst(prefix.count)
        var digitsEnd = remainder.startIndex
        while digitsEnd < remainder.endIndex, remainder[digitsEnd].isASCII, remainder[digitsEnd].isNumber {
            digitsEnd = remainder.index(after: digitsEnd)
        }
        guard digitsEnd > remainder.startIndex, let length = Int(remainder[remainder.startIndex..<digitsEnd]) else {
            return nil
        }
        let nameStart = digitsEnd
        guard let nameEnd = remainder.index(nameStart, offsetBy: length, limitedBy: remainder.endIndex) else {
            return nil
        }
        let moduleName = String(remainder[nameStart..<nameEnd])
        remainder = remainder[nameEnd...]
        guard !remainder.isEmpty else { return nil }
        return (moduleName, String(remainder))
    }
}
