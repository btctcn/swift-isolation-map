# Two more matching fixes, batched together

## 1. Context

Continuing from `docs/task-syntactic-placeholder-name-collision.md`'s final combined run (unknown
1512, unresolved edges 97, 5.3%). Clustered the remaining `isUnknown` edges by `calleeUSR` shape and
picked the two largest, independently-verifiable clusters to batch, per this investigation's own
established process (investigate + fix on fast local checks, one combined corpus run at the end).

## 2. Finding: `"SC"` (plain-C, non-Objective-C) module-code variant of a top-level imported constant

`ImportedTopLevelConstantMatching` (already shipped) covers a plain, non-member Clang global
constant's real mangling shape -- but hard-required the `"s:So"` prefix, the module code Swift
mangling assigns to **Objective-C**-imported symbols specifically. 12 real edges in the remaining
unknown set share the identical grammar one prefix over: `"s:SC"` --
`SQLITE_ROW`/`SQLITE_OK`/`SQLITE_OPEN_READONLY`/`SQLITE_OPEN_FULLMUTEX` (SQLite3),
`NSEC_PER_SEC`/`USEC_PER_SEC`/`AF_INET` (Darwin), `CC_SHA256_DIGEST_LENGTH` (CommonCrypto),
`kCFStringEncodingInvalidId` (CoreFoundation) -- all **plain C** macro constants, never
Objective-C-affiliated at all.

Checked, not assumed by analogy (this project's own discipline, directly called out in the existing
fix's own doc comment after a prior by-analogy guess turned out wrong elsewhere): a real
`swift symbolgraph-extract -module-name Darwin` run against the iOS SDK confirms
`NSEC_PER_SEC`/`USEC_PER_SEC`/`AF_INET`'s own `declarationFragments` carry no isolation attribute of
any kind -- and their real Clang identifier is `c:@macro@NSEC_PER_SEC` (a preprocessor macro, not
even a real Clang declaration), even further from anything an isolation attribute could attach to
than the `"So"` case.

**Fix**: `ImportedTopLevelConstantMatching.isTopLevelImportedConstant` now accepts either `"s:So"` or
`"s:SC"` as the module-code prefix; the rest of the grammar (length-prefixed name, no nominal marker
immediately after, `"vg"`/`"vs"` suffix) is identical and unchanged.

## 3. Finding: `Hashable.hashValue`'s synthesized default-witness accessor

4 real edges: `Moya.Endpoint.hashValue`, `Mindbox.ApplicationEvent.hashValue`,
`Mindbox.InAppMessageTriggerEvent.hashValue` -- all real Pod source, already linked with a real
location via ordinary extraction (same in-source-Pod shape as `MindboxLogger.LogLevel`). `hashValue`
is `Hashable`'s own protocol-extension default implementation (computed from `hash(into:)`) -- no
`SwiftSyntax` node exists for it even when the type provides a custom `hash(into:)`/`==`, exactly
like `SynthesizedEnumAccessorMatching`'s `rawValue`/`allCases` case.

**Deliberately not hardcoded `.nonisolated`** the way the enum case is: whether a default-witness
protocol-extension method genuinely inherits the conforming type's own actor isolation is a real,
non-obvious question this fix does not answer, because it doesn't have to. `SynthesizedHashableAccessorMatching.enclosingTypeUSR`
derives the enclosing type's own real USR (the accessor's own USR is always that type's USR with a
literal `"9hashValueSivg"` suffix appended), and the backfilled `DeclarationInfo` carries only
`containingTypeUSR` -- no `explicitIsolation` -- so the existing, unmodified `IsolationInferenceEngine`
applies its own already-verified whole-type inference to it, exactly as it already does for every
real member of that type. Confirmed via a new end-to-end test that a `@MainActor`-attributed
enclosing type's own isolation is what actually reaches the accessor, not an assumption baked into
this fix.

## 4. Real `Project Iris` corpus, before/after (both fixes together, one combined run)

| | before | after |
|---|---|---|
| External oracle unknown | 1512 | **1500** (-12) |
| Cross-isolation edges (denominator) | 1847 | **1831** |
| Unresolved edges (isUnknown) | 97 | **81** (-16) |
| Unresolved % | 5.3% | **4.4%** |

`highRiskBoundaries` (1471), `mainActorTypes` (12105), and `typesAnalyzed` (35454) unchanged --
confirms resolved uncertainty, not hidden or newly-introduced risk. Every targeted USR (`SC`-prefixed
constants, `hashValueSivg` accessors) is confirmed absent from the new run's own remaining
unknown-edge bucket.

## 5. Status

**FIXED AND VERIFIED**, batched: 2 new unit tests
(`ImportedTopLevelConstantMatchingTests.acceptsPlainCModuleCodeVariant`,
`SynthesizedHashableAccessorMatchingTests`, 2 tests) + 1 end-to-end test in
`ExternalIsolationBackfillTests.swift`, full suite (468/468) passing, real-corpus before/after above
from one combined run.
