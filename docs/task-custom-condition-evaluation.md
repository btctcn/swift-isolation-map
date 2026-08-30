# Real `#if <name>` custom-condition evaluation (issue #121)

Tracks [issue #121](https://github.com/btctcn/swift-isolation-map/issues/121).

**Status: `isCustomConditionSet` fixed for real, verified against Project Iris. The other
`PlatformBuildConfiguration` axes (arch, target environment, runtime, pointer authentication,
object format, pointer/atomic bit widths) remain deliberately permissive -- checked against both
real corpora available to this project, zero declaration-level evidence found for any of them.**

## Step 1 — Hypothesis

Issue #121's own text: "not a request to eagerly wire up every one of these axes... revisit if a
real corpus surfaces an `#if` branch gated on one of these axes where the current permissive
answer causes a visible problem." Before touching any code, checked whether a real problem
actually exists today, for any of the 8 hardcoded-permissive axes plus `isCustomConditionSet`.

## Step 2 — Spike

`grep -rn` for `arch(`/`hasFeature(`/`hasAttribute(`/`targetEnvironment(`/`_pointerBitWidth(`/
`_endian(`/`_runtime(`/`_hasAtomicBitWidth(` across the two real corpora available to this project
(Project Iris: 2227 Swift files including all Pods; SQLumen): **exactly one hit**, in Project
Iris, `AppGroupFetcher.swift:18`'s `#if targetEnvironment(simulator)` -- gating a plain `return ""`
statement inside a function body, never a declaration. Structurally invisible to this project's
declaration-level extraction either way; zero real impact.

`#if DEBUG`/`#if !DEBUG` (a *custom* condition, `isCustomConditionSet`'s own domain): 12 real
occurrences in Project Iris's own app code, several gating real declarations, not just statements:

- `SpotlightKeywordsService.swift:4-6` -- a protocol requirement, `func encryptKeywords()`, exists
  only under `#if DEBUG`.
- `MoyaPlugins.swift:15-19` -- **two competing declarations of the same name**,
  `static let logOptions`, one per branch of `#if DEBUG ... #else ... #endif`.
- `CocoaDebugWrapper.swift` -- an `import CocoaDebug` and a call, both `#if DEBUG`-gated.

Real Debug-configuration compiler arguments (confirmed via a temporary debug dump of
`compilerArguments.compilerArguments(forFile:)` for `MoyaPlugins.swift`, removed after use) do
contain `-DDEBUG` -- so the *old* hardcoded-`true` answer happens to agree with reality for `DEBUG`
specifically, purely by coincidence (this tool documents itself as analyzing exactly the Debug
configuration). That coincidence doesn't hold for other real custom conditions, confirmed next.

**Real grammar, confirmed from the same debug dump, not guessed**: a Swift-driver custom condition
appears as either the joined form (`-DDEBUG`, one array element) or the split form (`-D`,
`COCOAPODS`, two consecutive array elements) -- both real, both present in the same real argument
list. Every `-D<name>=<value>` form observed was *always* immediately preceded by a literal `-Xcc`
token (a Clang/Objective-C preprocessor macro, e.g. `-Xcc -DPB_FIELD_32BIT=1` from a
nanopb-generated header) -- categorically unrelated to Swift's own `#if` evaluation. A bare Swift
condition never carries `=`.

## Step 3 — Documentation (this document)

## Step 4 — Code

- `Sources/SyntaxAnalysis/PlatformBuildConfiguration.swift`: `PlatformBuildConfiguration` gained
  `activeCustomConditions: Set<String>?` (`nil` = unresolvable, permissive -- mirrors
  `platform == .unknown`'s own fail-safe direction). `isCustomConditionSet(name:)` now returns
  `activeCustomConditions?.contains(name) ?? true`. New `ActiveCustomConditionParsing.parse(fromCompilerArguments:)`
  implements the real grammar above: joined and split `-D` forms recognized; anything immediately
  after a literal `-Xcc` token skipped entirely, joined or split.
- `DeclarationExtractor.extract`/`extractWithContext`, `FileAnalyzer.analyze`: threaded the new
  parameter through, each defaulting to `nil` (unchanged behavior for every existing caller that
  doesn't pass one, e.g. every test fixture).
- `SwiftIsolationMap.swift`'s per-file extraction loop: computes this file's own real
  `activeCustomConditions` via `compilerArguments.compilerArguments(forFile:)` +
  `ActiveCustomConditionParsing.parse(fromCompilerArguments:)`, `nil` when this file's compiler
  arguments can't be resolved at all (never an empty set masquerading as "confirmed nothing set").

The remaining permissive axes' own doc comment was updated to record this same real-corpus check
(zero declaration-level evidence for any of them, `targetEnvironment(simulator)`'s one real hit
being statement-only) rather than leaving the original "unconfirmed here" wording unmodified.

## Step 5 — Tests

`Tests/SyntaxAnalysisTests/PlatformBuildConfigurationTests.swift` (new): `ActiveCustomConditionParsing`
unit tests (joined form, split form, `-Xcc`-prefixed exclusion, the real mixed Project Iris shape,
a bare `-D...=...` with no `-Xcc` still excluded since real Swift `-D` never carries a value),
`PlatformBuildConfiguration.isCustomConditionSet` unit tests (`nil` permissive, a real set,
confirmed-empty set), and an end-to-end `DeclarationExtractor` test reproducing `MoyaPlugins.swift`'s
own two-competing-declarations shape directly, proving the mechanism, not just the parsing utility
in isolation.

## Step 6 — Documenting results

Real, controlled before/after run against Project Iris (`--oracle-workers 4`, same on-disk index
store, same corpus state as the immediately-preceding `-g` fix's own verification run):

| | before | after |
|---|---|---|
| `crossActorBoundaries` / edges | 1547 (unchanged) | 1547 (unchanged) |
| `highRiskBoundaries` | 1462 (unchanged) | 1462 (unchanged) |
| Total nodes | 41738 | **41736 (-2)** |
| `unspecifiedIsolation` | 234 | **233 (-1)** |

Zero edges changed at all -- this fix only affects node/type-level completeness, not any reported
risk. Diffed the exact node-level change, not just the count, per this project's own "compile every
line" discipline:

**3 phantom declarations correctly removed**, all in `Pods/PromiseKit/Sources/Deprecations.swift`,
all still `syntactic:`-placeholder USRs (never linked to a real index-store USR, i.e. never really
compiled) even before this fix: `Thenable.flatMap`/`flatMap`/`map`, each gated by
`#if PMKFullDeprecations ... #endif` in the real source. `PMKFullDeprecations` is not defined for
this real build -- confirmed directly: these methods have no compiled USR in the index store either.
The old hardcoded-`true` answer wrongly treated this custom condition as always active, extracting
three declarations that don't really exist in the compiled binary -- exactly the "phantom
declaration" failure mode this whole `PlatformBuildConfiguration` mechanism exists to prevent
(`docs/task-bulk-extraction-wrong-platform.md`), just via a different axis than the one that
motivated the original fix.

**1 real declaration correctly recovered**, `Pods/PromiseKit/Sources/CustomStringConvertible.swift`'s
`AnyPromise.description` (`c:@CM@PromiseKit@@objc(cs)AnyPromise(py)description`), gated by
`#if !SWIFT_PACKAGE ... #endif`. This is the *negated*-condition failure direction the original
design doc's own risk analysis anticipated but had no real corpus evidence for: the old hardcoded-
`true` answer for `isCustomConditionSet("SWIFT_PACKAGE")` made `!SWIFT_PACKAGE` evaluate `false`
unconditionally -- silently dropping this real declaration on every CocoaPods-integrated build
(where `SWIFT_PACKAGE` is genuinely never defined), regardless of what the real build actually was.
Confirmed real and compiled: this USR now resolves with a real, non-placeholder isolation
(`nonisolated`, an `@objc` override of `NSObject.description`).

Both directions of risk this mechanism exists to balance -- a phantom declaration, and a real one
silently dropped -- were real, present in this exact real corpus, for this exact axis, confirmed
only once real evidence existed to check against (matching this project's own discipline: root-cause
before symptom, evidence before implementation).

## Step 7 — PR

Not yet opened.
