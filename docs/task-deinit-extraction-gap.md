# `deinit` was never extracted as a declaration at all

Tracks [issue #48](https://github.com/btctcn/swift-isolation-map/issues/48).

**Status: shipped. Root cause is different from the issue's own original hypothesis.**

## Step 1 — Hypothesis

Auditing medium-risk edges from a real run against Project Iris: a small but real subset of edges
whose caller is an `@objc`-visible override method -- `deinit` (Clang USR spelling
`...(im)dealloc`), `init?(coder:)`, `init(style:reuseIdentifier:)`, `layoutSubviews()` -- resolve
to `callerIsolation: "unspecified"` even though the declaration is a real, ordinary override in an
app-declared UIKit subclass that should inherit `@MainActor` per SE-0316. Measured scope: 631
resolve correctly vs. 74 resolve to `.unspecified`, split per-*class*, not per-selector. Original
hypothesis (from the issue body): `IndexStoreDB` reports **two different USRs** for the same
`@objc`-visible override -- a Clang-interop symbol and a Swift-native one -- and `usrRewriteMap`'s
location-based match vs. the call graph's raw `.calledBy` USR pick different ones, causing a lookup
miss.

## Step 2 — Spike

Traced precisely, not guessed, using the same real-index-store-probe methodology as #44/#53/#57:
a direct, standalone probe against Project Iris's real index store for `MaskTextField.swift`
(`lsboutique/Controls/MaskTextField.swift`, the issue's own example):

```
DEF usr=c:@M@Ls_net_ru@objc(cs)MaskTextField(im)dealloc name=deinit line=69 col=5
CALL callerUSR=c:@M@Ls_net_ru@objc(cs)MaskTextField(im)dealloc calleeUSR=...deRegisterForNotifications... line=70 col=9
```

**`IndexStoreClient.definedSymbols(inFile:)` and `callSites(inFile:)` agree on the exact same USR**
for `deinit`, at both its definition and its call site. There is no USR to reconcile -- the
issue's own original hypothesis is wrong for this case.

Read `Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `DeclarationVisitor` for every
`override func visit(_ node: ...)` it implements: `FunctionDeclSyntax`, `InitializerDeclSyntax`,
`SubscriptDeclSyntax`, `VariableDeclSyntax`, `AccessorDeclSyntax`, `EnumCaseElementSyntax`,
`TypeAliasDeclSyntax` -- **no `DeinitializerDeclSyntax` override anywhere in the file.** An
explicit `deinit` is a real, hand-written declaration with its own `SwiftSyntax` node type (unlike
#55's implicit/synthesized shapes, which genuinely have no node at all) -- this is a plain, missing
visitor override, the same *category* of bug as #53 (a `SwiftSyntax` node type with zero coverage),
just for `deinit` instead of `protocol`.

This explains the "631 succeed / 74 fail" split from Step 1: `deinit` itself *always* fails (100%
of explicit deinits in the whole codebase, `@objc`-visible or not, `@MainActor` or not, silently
missing from `declarations`) -- the 631 successes in the same measured family come from the other
method kinds (`init?(coder:)`, `init(style:reuseIdentifier:)`, `layoutSubviews()`), which already
have working `InitializerDeclSyntax`/`FunctionDeclSyntax` handlers and hit a *different*, much
rarer failure mode (or none at all) unrelated to this gap.

## Step 3 — Documentation (this document)

## Step 4 — Code

`Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `DeclarationVisitor` gained
`visit(_ node: DeinitializerDeclSyntax)`, mirroring `InitializerDeclSyntax`'s own shape exactly:

```swift
override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    emitMember(name: "deinit", node: node, namePosition: node.deinitKeyword.positionAfterSkippingLeadingTrivia, attributes: node.attributes, modifiers: node.modifiers, kind: .deinitializerDecl)
    return .visitChildren
}
```

`Sources/SyntaxAnalysis/ModuleDefaultIsolationEligibility.swift`'s `SyntacticDeclarationKind`
gained a `.deinitializerDecl` case, routed the same as `.function`/`.initializerDecl` (`deinit`
isn't in SE-0466's exclusion list -- `docs/isolation-rules.md` rule 12 excludes "enum cases,
typealiases, accessors, actor-type members, `SendableMetatype`-conforming types, nested types in
nonisolated types," not deinitializers -- so it's eligible for the module default the same way an
ordinary method is).

## Step 5 — Tests

`Tests/SyntaxAnalysisTests/DeclarationExtractorTests.swift`:
- `deinitIsExtractedAsAMemberDeclaration`: an explicit `deinit` produces its own `DeclarationInfo`
  with the correct `containingTypeUSR`. Confirmed to crash (force-unwrap on a `nil` lookup) without
  the fix.
- `deinitInheritsContainingTypeIsolation`: a `deinit` inside a `@MainActor` class resolves to
  `globalActor(MainActor)` through the unmodified `IsolationInferenceEngine`, the same as any other
  member.

Full `swift test -c release`: 313/313 passing.

## Step 6 — Documenting results

Real-corpus re-run against Project Iris (post-#46/#47):

| | before | after |
|---|---|---|
| Total linked declarations | 47126 | **47170 (+44)** -- one per explicit `deinit` in the corpus |
| `highRiskBoundaries` | 1167 | 1167 (unchanged) |
| `crossActorBoundaries` | 24852 | **24801 (-51)** |
| `unspecifiedIsolation` | 1501 | **1458 (-43)** |

`highRiskBoundaries` staying flat is expected: every affected caller in this corpus is a real
`@MainActor` override (SE-0316 inheritance), so its call sites were never a `.nonisolated`-reaching-
isolated shape to begin with -- fixing the caller's own isolation moves it out of `.unspecified`
(previously counted in `crossActorBoundaries` as "crossing," since `.unspecified` differs from any
real isolation) into correctly resolving as the *same* isolation domain as its `@MainActor` callees,
which `IsolationInferenceEngine.crossIsolationEdges()` then correctly excludes entirely (not a
crossing at all). That's the `-51`/`-43` drops: real noise removed, not risk hidden -- consistent
with `highRiskBoundaries` never having depended on these specific edges' correctness in the first
place, and with this project's fail-safe direction (a previously-`.unspecified` edge resolving to a
confirmed-safe shape is exactly the intended outcome, distinct from #51/#57's "surfacing previously-
hidden risk," which moved numbers the other way for a different reason).

## Step 7 — PR

Next.
