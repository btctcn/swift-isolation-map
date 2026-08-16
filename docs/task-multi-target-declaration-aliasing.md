# The same source file compiled into multiple Xcode targets

## 1. Context

Continuing from `docs/task-bridged-extern-function-property-isolation.md`'s §5 baseline (real
`Project Iris` corpus, 21% of cross-isolation edges unresolved): the largest remaining cluster was
`lsboutiqueNotifications_Release`/`lsboutiqueContentExtension_Release` -- module-qualified USRs
belonging to the project's own Notification Service Extension and Content Extension targets, not
the analyzed `ls.net.ru` app scheme.

Structurally distinct from every other finding in this investigation: this isn't an *external*
Clang/SDK USR mismatch at all. Every USR involved is 100% project-local -- just compiled under a
*sibling Xcode target's* own module namespace.

## 2. Root cause, confirmed via a real, from-scratch minimal reproduction

`AppGroupFetcher.swift`/`ExtensionListener.swift` are each real members of three separate
`PBXBuildFile` entries in the real corpus's own `.pbxproj` -- the main app target plus both
extension targets. A shared source file compiled into multiple targets is compiled once per target,
and the real Swift indexer records one full set of occurrences per compiled unit -- so the *same*
physical property (`AppGroupFetcher.hostApplicationName`) ends up with three real, distinct,
module-qualified USRs, one per target:

```
s:9Ls_net_ru15AppGroupFetcherC19hostApplicationNameSSSgvp
s:31lsboutiqueNotifications_Release15AppGroupFetcherC19hostApplicationNameSSSgvp
s:34lsboutiqueContentExtension_Release15AppGroupFetcherC19hostApplicationNameSSSgvp
```

`DeclarationLinker`'s own per-file syntactic-to-real USR rewrite (`disambiguate`'s own "exact name
match" rule, with no notion of "which target" at all) only ever picks *one* winning candidate at a
given (line, column) -- so only one target's own variant ever enters `linked.declarations` with a
real location. The other two targets' own call-graph edges (recorded by the same multi-unit
index-store scan, independent of which target's variant won) reference `calleeUSR`s that are simply
absent from `declarations` -- genuinely project-local, yet not externally resolvable either:
`compilerArguments(forFile:)` is scoped to the *one* analyzed scheme's own build log, so a live
`cursorinfo` query at that same file/line always resolves through *that* scheme's own compiled unit,
never matching a sibling target's own differently-module-qualified `targetUSR` by strict equality.

**Confirmed via a real, from-scratch minimal reproduction**, per this session's established
discipline: a 3-target Xcode project (one app target + two embedded app-extension targets,
generated with `xcodegen`, fully reverted after use) sharing one source file across all three
targets' own `Sources` build phases, with the *same* internal cross-property reference shape the
real corpus has (`applicationGroupIdentifier`'s own getter reading `self.hostApplicationName`)
reproduced the exact `isUnknown: true` symptom -- 2/2 extension-qualified variants unresolved,
main-app variant fine. An earlier, simpler version of the mini-repro (without the internal
cross-property reference, only external reads) did *not* reproduce the bug -- a useful negative
result that narrowed down the real trigger shape before the fix was designed.

## 3. The real mangling fact that makes this safely fixable without any live query

A Swift USR's module-name component is always the *first* length-prefixed identifier immediately
after `"s:"` -- everything after it (the type/member path, accessor markers) is a pure function of
the *declaration itself*, never the compiling target. Confirmed byte-for-byte identical across all
three real module-qualified variants above: all three share the identical
`"15AppGroupFetcherC19hostApplicationNameSSSgvp"` suffix.

**A known, deliberately accepted limitation, not a correctness risk**: Swift's own mangling
substitution compression can make two module-qualified variants' suffixes *diverge* when the module
name happens to be a textual prefix of the type name -- confirmed directly while building this fix's
own mini reproduction: naming the test app target `"App"` (a prefix of `"AppGroupFetcher"`)
triggered a compressed `"0A12GroupFetcherC..."` suffix instead of the uncompressed
`"15AppGroupFetcherC..."` form, which the real corpus's own module names (none of them a prefix of
`AppGroupFetcher`) never hit. A false *negative* (this fix simply doesn't fire for that one variant,
exactly as if it didn't exist), never a false positive, since the comparison is exact-string.

## 4. Fix

New `Sources/IsolationCore/MultiTargetDeclarationAliasing.swift`:
`moduleNameAndSuffix(ofSwiftUSR:)` parses this shape. Reading a digit right after `"s:"` naturally
excludes every Swift-stdlib substitution (`s:Sb...`, `s:Si...`) and every imported-Clang USR
(`s:So...`) -- neither is ever a length-prefixed real module name -- so this never overlaps with any
of the previous five matchers' own domains.

Wired into `ExternalIsolationBackfill.collectEdgeLevelWorkItems` as a pre-filter (zero live query):
a project-wide `[suffix: DeclarationInfo]` index is built once from every already-linked
declaration (a real `location`, never a placeholder), then a calleeUSR absent from `declarations`
is checked against that index by its own suffix. A match means "the same declaration, a different
target" -- its already-fully-known `DeclarationInfo` (including `containingTypeUSR`, so downstream
inheritance/module-default resolution works identically to the winning variant) is copied verbatim
under the new USR key.

7 new unit tests (`MultiTargetDeclarationAliasingTests.swift`) + 2 end-to-end tests in
`ExternalIsolationBackfillTests.swift` (one confirming the alias preserves `containingTypeUSR`
correctly, one confirming a sibling-shaped USR with no actual linked match falls through to the
live query rather than being fabricated).

## 5. Real `Project Iris` corpus, before/after

| | before | after |
|---|---|---|
| External oracle unknown | 1594 | **1588** (**-6**) |
| Cross-isolation edges (denominator) | 1916 | **1922** |
| Unresolved % | 21% | **21%** |

Confirmed directly against the real corpus's own node/edge data: all three module-qualified
variants of `hostApplicationName` now resolve to `nonisolated` with a real location, and the
`applicationGroupIdentifier`/`ExtensionListener` edges that were previously `isUnknown: true` are
now `isUnknown: false`.

Smaller numeric win than some earlier fixes -- most of this cluster's own ~68 original mentions
turned out to already be non-risky pairs once the caller/callee's own real facts are known (e.g.
`nonisolated -> nonisolated`), so they were never counted as "unresolved" `isUnknown` edges to begin
with, even before this fix -- the real win here is *correctness* for the edges that were flagged
`isUnknown: true` even though both sides were, in fact, perfectly resolvable.

## 6. Status

**FIXED AND VERIFIED**, 9 new tests, real-corpus before/after above. The temporary 3-target
`xcodegen` mini-repro project used to confirm the real behavior has been fully removed -- no trace
in the final diff.
