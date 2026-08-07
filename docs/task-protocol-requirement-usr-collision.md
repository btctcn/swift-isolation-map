# Protocol requirement placeholder USRs collide across files

Tracks [issue #53](https://github.com/btctcn/swift-isolation-map/issues/53). Found continuing the
"401 remaining declarations" follow-up to #51 (`docs/task-indexstore-declaration-completeness.md`'s
Step 6) -- a real, deterministic bug in this project's own `SyntaxAnalysis` extraction, not another
instance of `IndexStoreDB` instability.

**Status: shipped.**

## Step 1 — Hypothesis

Demangling the remaining "referenced but never declared" USRs after #51/#52's live-fallback fix
landed showed a real cluster (~69 of 401) shaped like `XxxRouter.dismiss()`,
`XxxViewInput.setViewData(_:)` -- protocol *requirements* (no implementation), not witnesses.
`FastBuyRouter.dismiss()` resolved correctly in an isolated single-file
`DeclarationLinker.link()` probe (same methodology as #51's own investigation), yet was still
missing from a real full-project run -- but unlike #51's cases, a targeted `resolveOne` trace
never fired for its exact location at all, meaning it never even reached the live-fallback path.
Hypothesis: something other than `IndexStoreDB` load-dependent instability was responsible for
this specific case.

## Step 2 — Spike

Traced precisely, not guessed, using a fast (extraction + linking only, no live oracle -- a
full, real 2251-file extraction of Project Iris against its real index store, without the
20-30-minute external-oracle phase) reproduction:

1. Instrumented `DeclarationLinker.link()`'s main `byUSR`-building loop directly. Found: both
   `FastBuyRouter.dismiss()` (`FastBuyRouter.swift:13`) and `OrderRouter.dismiss()`
   (`OrderRouter.swift:13` -- a *different*, unrelated protocol in a *different* file) produced
   the *identical* syntactic placeholder USR, `syntactic:.dismiss#234`, and both rewrote (via
   correct, independent, non-colliding `usrRewriteMap` entries) to the *same* real USR
   (`s:9Ls_net_ru13FastBuyRouterP7dismissyyF`). The second declaration processed silently
   overwrote the first's entry in `byUSR`.
2. Confirmed `buildUSRRewriteMap`/`candidatesByLocation` itself is not at fault: a direct,
   standalone `IndexStoreClient.definedSymbols(inFile:)` call for each of the two real files
   returned the correct, distinct, non-colliding real USR for each -- no file-attribution mixup
   inside `IndexStoreDB`.
3. Read `Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `DeclarationVisitor`: it pushes onto
   its `path` stack (via `enterTypeScope`/`exitTypeScope`) for `ActorDeclSyntax`,
   `ClassDeclSyntax`, `StructDeclSyntax`, `EnumDeclSyntax`, `ExtensionDeclSyntax` -- but has **no**
   `visit(_ node: ProtocolDeclSyntax)` override. A member declared directly inside a `protocol {
   }` body is therefore emitted with an empty `path`, so `emitMember`'s
   `"syntactic:\(qualifiedTypeName).\(name)#\(offset(of: node))"` becomes
   `"syntactic:.\(name)#\(byteOffset)"` -- no containing-type qualification, a raw UTF-8 byte
   offset as the *only* discriminator, unique only within one file.
4. Confirmed the real-world trigger: `FastBuyRouter.swift` and `OrderRouter.swift` are both
   VIPER-style router protocol files with byte-identical header comment blocks and `protocol
   XxxRouter {` on the same source line, so `func dismiss()` lands at the exact same byte offset
   in both. Measured scope: this project's VIPER architecture uses this exact boilerplate shape
   (`XxxRouter`/`XxxViewInput` protocols with common requirement names -- `dismiss()`,
   `setViewData(_:)`, `setTitle(_:)`, `setTableViewData(_:)`) pervasively, not as a one-off.

## Step 3 — Documentation (this document)

## Step 4 — Code

`Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `emitMember`: when `qualifiedTypeName` is
empty (the protocol-requirement case -- no enclosing type scope), disambiguate with the
declaration's own file name instead of the byte offset alone:

```swift
let discriminator: String
if qualifiedTypeName.isEmpty {
    let sanitizedFileName = fileName.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "/", with: "_")
    discriminator = "\(sanitizedFileName)_\(offset(of: node))"
} else {
    discriminator = "\(offset(of: node))"
}
let memberUSR = "syntactic:\(qualifiedTypeName).\(name)#\(discriminator)"
```

`fileName` is sanitized (`.`/`/` replaced) because `DeclarationLinker`'s own nesting-mismatch
fallback (`docs/priority-2-phase-3-linking.md`'s Gap B Phase I2) scans every `syntactic:` USR for
its rightmost `.` as a qualified-name separator -- an unsanitized file path's own `.swift`
extension would be misread as one.

Deliberately scoped to only the empty-`qualifiedTypeName` case: ordinary members (non-empty path)
keep their exact previous USR shape, so this doesn't risk perturbing any other declaration's
placeholder identity.

## Step 5 — Tests

`Tests/SyntaxAnalysisTests/DeclarationExtractorTests.swift`:
- `protocolRequirementsAtIdenticalByteOffsetInDifferentFilesDoNotCollide`: two unrelated protocols
  in different files (deliberately same-length names, so their identically-named requirement lands
  at the identical byte offset) now produce distinct placeholder USRs. Confirmed to fail without
  the fix (`git stash` on just this file) -- both produced `"syntactic:.dismiss#23"` -- and pass
  with it.
- `protocolRequirementUSRIsWellFormed`: a protocol requirement's placeholder USR is still
  well-formed (`syntactic:` prefix present) when the protocol has no name-qualified path at all.

Full `swift test -c release`: 297/297 passing.

## Step 6 — Documenting results

Real-corpus re-run against Project Iris, before vs. after (both after #51/#52's live-fallback fix
already shipped, so directly comparable):

| | before | after |
|---|---|---|
| Total linked declarations | 46873 | **47126 (+253)** |
| Missing app-module declarations (#51's "401 remaining") | 401 | **361 (-40)** |
| `highRiskBoundaries` | 933 | 933 (unchanged) |

`highRiskBoundaries` staying flat is expected, not a sign the fix did nothing: a protocol
requirement with no explicit isolation attribute resolves `.nonisolated` by default regardless of
which of the two colliding declarations "won" before this fix -- the fix corrects *which*
declaration in `declarations` owns that fact (and therefore whether its own call sites resolve
correctly, rather than silently defaulting through `.unspecified`), not what the isolation fact
itself is for this specific corpus. The `+253`/`-40` numbers are the direct, measured evidence the
collision was real and is now resolved for a meaningful fraction of cases; the remaining gap
between the ~126 protocol-shaped candidates in the original 401 and the 40 actually fixed here is
consistent with not every protocol requirement's real USR being referenced by a call-graph edge at
all (silently-lost declarations never show up as "missing" unless something actually calls them),
and/or a residual fraction still being genuine `IndexStoreDB`-instability cases from #51, not this
bug.

## Step 7 — PR

Next.
