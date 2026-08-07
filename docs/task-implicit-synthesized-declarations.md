# Implicit/synthesized declarations are structurally invisible to SwiftSyntax extraction

Tracks [issue #55](https://github.com/btctcn/swift-isolation-map/issues/55). Found continuing the
"361 remaining declarations" follow-up to #53 (`docs/task-protocol-requirement-usr-collision.md`),
itself a follow-up to #51 (`docs/task-indexstore-declaration-completeness.md`).

**Status: documented as a known, permanent limitation of the current SwiftSyntax-first extraction
design. Not fixed. Not planned as a small patch — would require a real architectural addition (see
Step 4).**

## Step 1 — Hypothesis

After #51/#52's live-fallback fix and #53's protocol-requirement-collision fix both shipped, a real
full-project run against Project Iris still showed 361 app-module declarations missing entirely
(down from 401, down from the original 803). Going in, the working hypothesis was "more of the
same" — either residual `IndexStoreDB` load-instability (#51's own root cause) or another
collision/extraction bug shaped like #53's.

## Step 2 — Spike

Demangled all 361 real USRs (`xcrun swift-demangle -simplified`, after rewriting each USR's `s:`
mangling prefix to `$s` — required for the tool to accept them). Sorted by shape:

| Shape | Count | % |
|---|---|---|
| `.init(...)` (initializers) | 275 | 76% |
| `.rawValue.getter` / `.allCases.getter` / `.deinit` / `.getter` / `.setter` | 28 | 8% |
| Bare protocol/type names (the type itself, not a member) | 57 | 16% |
| Unexplained (`static ExtensionListener.MindboxNotificationReceived`) | 1 | <1% |

**303 of 361 (84%) are `.init`/`.deinit`/`.rawValue`/`.allCases` shapes.** Traced precisely, not
guessed: picked `CartClient.init()` from the list and read `lsboutique/Api/CartClient.swift`
directly — there is genuinely no explicit `init()` written for `CartClient` anywhere in that file.
The compiler synthesizes a default/memberwise initializer because none was written by hand, and
`SwiftSyntax`'s tree — which represents parsed *source text* — has no node for it. Confirmed the
same shape for a `rawValue.getter` case: the enum's `rawValue` accessor is compiler-generated for
any `RawRepresentable` enum that doesn't hand-write its own `var rawValue`, and no source line
describes it either.

Read `Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `DeclarationVisitor`: every declaration
this project extracts comes from visiting a concrete `SwiftSyntax` node type
(`InitializerDeclSyntax`, `DeinitializerDeclSyntax`, `VariableDeclSyntax`, `FunctionDeclSyntax`,
...). This is correct and by design — `SwiftSyntax` is a lossless parse of exactly what's in the
file, nothing more, nothing less. A synthesized declaration that exists only after semantic
analysis (typechecking) has, structurally, nothing in the parse tree to visit. This is not a gap in
which node types `DeclarationVisitor` handles; it's a category of declaration that has zero
representation in the data structure the whole extraction pass is built on.

By contrast, `IndexStoreDB`/`sourcekitd` (the tools this project uses *after* extraction, to
resolve real USRs and query the call graph) operate on the *compiled* declaration set, which does
include synthesized members — that's exactly how the 803→401 gap in #51 was measured in the first
place: real call-graph edges reference these USRs, so they're visibly "real" from that side, just
invisible from the `SwiftSyntax` side that has to emit the placeholder before any USR resolution
can even begin.

The remaining 57 "bare protocol/type name" cases are a *different* mechanism, still under
investigation (see Step 6) — not folded into this finding's 84%, since a bare protocol name isn't
a synthesized member; it's the protocol type itself.

## Step 3 — Documentation (this document)

## Step 4 — Why this isn't a small patch

Every other gap found this cycle (#51, #53) was fixable within the existing pipeline shape because
the missing information already existed somewhere this project's own code could reach it — a live
`cursorinfo` query at a known source location (#51/#52), or a corrected discriminator string for an
already-known placeholder (#53). Here there is no source location to query and no existing
placeholder to disambiguate: the declaration has no textual anchor at all.

A real fix would mean **not treating "one `SwiftSyntax` node → one placeholder" as universal** —
instead, for every type that's entitled to a synthesized member (a `struct`/`class` with stored
properties and no hand-written matching initializer; any `RawRepresentable`/`CaseIterable` enum;
any type without an explicit `deinit`), synthesizing a `DeclarationInfo` placeholder that has no
byte offset and no `SwiftSyntax` node behind it, then resolving *that* against IndexStoreDB the
same way. This requires re-deriving, in this project's own extraction pass, a non-trivial slice of
the same eligibility rules the Swift compiler itself uses to decide whether to synthesize a given
member (e.g. a memberwise initializer is only synthesized if *no* initializer at all is declared,
across the whole type, not just checked member-by-member) — a real, scoped feature, not a one-line
change to `emitMember`. Given the fix's real cost and this project's own guiding principle ("a tool
that gives an incorrect result is worse than no tool at all" — README's Guiding principle section),
inventing synthesis-eligibility rules independently of the compiler risks introducing *new*,
harder-to-verify false positives/negatives, for a class of declaration (implicit boilerplate)
that's rarely where undiscovered actor-isolation risk actually hides in practice (see Step 5).

**Decision: document as a structural limitation now; revisit only if a real occurrence shows actual
isolation risk hiding specifically behind one of these synthesized declarations** (not yet observed
in Project Iris — see Step 5).

## Step 5 — Impact assessment

Call sites into these 303 synthesized declarations resolve their callee isolation as `.unspecified`
rather than the correct inferred value (which, for most of these shapes, follows the same
containing-type inference already applied to every explicit member — a synthesized `init()` on a
`@MainActor` type is `@MainActor` too). This is the same "silent under-reporting, never
over-reporting" direction as every other gap in this project's fail-safe design — `.unspecified`
never gets escalated to `.high`, so this cannot manufacture a false-positive high-risk boundary; it
can only leave a real one unclassified. Checked Project Iris's own real report: none of the 303
declarations' call sites currently register as a *would-be*-high-risk edge if resolved (i.e., none
of their callers are confirmed-`nonisolated` while the containing type is a confirmed global actor)
— the practical risk from this specific gap, on this specific corpus, today, is low. Documented as
a limitation to watch, not an active source of missed real bugs right now.

## Step 6 — Related but distinct: the 57 bare protocol/type names

Separately investigated (not part of this finding's 84%, a different mechanism): a bare protocol
name like `Disposable` (`lsboutique/Redesign/ToolKit/Disposable/Disposable.swift`, the only file
declaring it — ruling out a #53-style cross-file collision) extracts with `location: nil` on its
own `DeclarationInfo`. Traced as far as: `DeclarationExtractor.swift`'s first pass
(`TypeIndexBuilder.Visitor`) has its own, separate `visit(_ node: ProtocolDeclSyntax)` override that
only records `protocolGlobalActorNames[node.name.text]` — unlike its handlers for
`ActorDeclSyntax`/`ClassDeclSyntax`/`StructDeclSyntax`/`EnumDeclSyntax`, it never calls
`recordPrimaryDeclaration` (the function that sets `TypeIndexEntry.location`), and the main
`DeclarationVisitor` has no protocol handler at all (the same root fact #53 already established).
Without a location, neither the bulk `usrRewriteMap` (needs `declaration.location` to build
`candidatesByLocation`) nor the live fallback (`unresolvedPlaceholders(for:)` explicitly skips
`location == nil`) can ever resolve it. This looks like a third, related-but-distinct consequence of
the same "protocols aren't a type scope" gap #53 partially addressed (for protocol *members*, not
protocol *declarations themselves*) — worth its own follow-up issue if a fix is found to be
tractable, rather than folding it into this document's "can't be fixed" conclusion. Not yet
resolved as of this writing.

## Step 7 — PR

This document + README section + issue #55.
