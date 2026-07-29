# cursor-info one-shot shape: confirmed in SourceKit source, pre-spike expectations for the dlopen step

**Status: source-verification record arming the one remaining not-yet-empirical step.** Fifth
document of the compiled-dependency-isolation thread, responding to the spike document's third
addendum, which accepted the USR-matching requirement, confirmed `textDocument/symbolInfo`
empirically, and correctly flagged the residual gap: `symbolInfo` carries no isolation, so the
proposed one-shot `sourcekitd` cursor-info (`key.usr` *and* the annotated declaration together,
per result) remained unspiked because it requires the `dlopen`/C-ABI route. This document closes
that gap the same way the thread's first document armed the hover spike: by verifying the exact
shape in SourceKit's own source (`swiftlang/swift` `main`,
`tools/SourceKit/lib/SwiftLang/SwiftSourceDocInfo.cpp` and
`tools/SourceKit/tools/sourcekitd/lib/Service/Requests.cpp`, read 2026-07-26), turning the
dlopen spike's outcomes into precise predictions. The thread has now twice seen the shipped
Xcode 26.4 toolchain match `main` on exactly this class of claim, but the usual discipline
stands: these are predictions to confirm, not facts to assume.

## 1. Per-result fields — confirmed: every result carries USR + fully annotated declaration together

`fillSymbolInfo` (SwiftSourceDocInfo.cpp) populates, for **each** `CursorSymbolInfo`
independently: `Name`, `USR`, `TypeUSR`, `ContainerTypeUSR`, `AnnotatedDeclaration`,
`FullyAnnotatedDeclaration`, doc comment — and optionally a per-symbol symbol graph (section 3).
Response serialization (Requests.cpp, cursor-info response builder): the first symbol is
serialized into the top-level response dictionary via `addCursorSymbolInfo` — which sets
`key.usr` and `key.fully_annotated_decl` — and **every additional symbol goes into a
`key.secondary_symbols` array, each element serialized through the very same
`addCursorSymbolInfo`**, i.e. each secondary result carries its own complete
`key.usr` + `key.fully_annotated_decl` pair. The one-shot shape the third addendum wanted
confirmed is exactly what the source builds: a single request at the edge position returns a set
of `{usr, fully_annotated_decl}` results; select by USR equality against the edge's member USR;
read isolation from the matched result only. No two-call correlation, no name/kind heuristics.

## 2. The `DivergentIsolation` ambiguity is codified behavior, not an accident — and it lands USR-labeled

`addCursorInfoForDecl` (SwiftSourceDocInfo.cpp) contains this comment, verbatim:

```cpp
// The primary result for constructor calls, eg. `MyType()` should be
// the type itself, rather than the constructor. The constructor will be
// added as a secondary result.
```

The exact shape the second addendum observed through hover as unlabeled `"Multiple results"`
Markdown is, at the cursor-info layer, **by-design, documented-in-source behavior**: primary =
the type, secondary = the invoked initializer — each with its own USR and annotated declaration.
Two consequences: the ambiguity is stable across toolchains (safe to design against, not a
quirk to defend around), and USR matching resolves it by construction — for an initializer-call
edge, the edge's member USR selects the secondary `init()` result, never the type's.

## 3. Bonus finding — the two research threads converge: cursor-info can return a per-symbol symbol graph

`fillSymbolInfo` honors an `AddSymbolGraph` flag (request key `key.retrieve_symbol_graph`):
when set, it runs `symbolgraphgen::printSymbolGraphForDecl` — the same `SymbolGraphGen` library
behind `swift symbolgraph-extract` — for that one declaration, with
`MinimumAccessLevel = Private`, `IncludeSPISymbols`, `IncludeClangDocs`, and attaches the JSON
as `key.symbol_graph` on the same result, alongside `key.usr` and `key.fully_annotated_decl`.
This merges the thread's two oracle candidates into one request: the sourcekitd transport the
spikes validated, carrying the machine-oriented data format the batch proposal wanted —
declaration fragments where `@MainActor` is a `"kind": "attribute"` JSON fragment (with the
global actor's own USR as `preciseIdentifier`), not a substring and not XML. **Recommendation
for the integration design: parse isolation from the matched result's `key.symbol_graph`
attribute fragments as the primary format, with `key.fully_annotated_decl` XML as the fallback
if the symbol-graph flag proves unavailable or costly on the real toolchain.** The dlopen spike
should measure both (the per-decl symbol graph may carry a latency cost worth knowing).

## 4. One matching nuance to handle: synthesized-extension USRs

`fillSymbolInfo` appends, for symbols presented through a synthesized extension, a suffix to the
USR: the base is joined with `LangSupport::SynthesizedUSRSeparator`, whose value is the literal
string `"::SYNTHESIZED::"` (SwiftLangSupport.cpp), followed by the extended nominal's USR. The
USR-equality check must therefore be: exact match, else match on the prefix before
`"::SYNTHESIZED::"`. One line of code, but a silent exact-match-only comparison would
misreport such members as unresolved (`unknown`) — correct direction of failure, wasted
coverage.

## 5. Pre-registered expectations for the dlopen spike (falsifiable, per thread discipline)

Request: `source.request.cursorinfo` with `key.sourcefile`, `key.offset` (edge position, already
known per edge from `IndexStoreIntegration`), `key.compilerargs` (the same build-settings
material as the LSP path — reinforcing that the Xcode build-settings decision is the shared
prerequisite for **both** transports, not an LSP-specific one), and `key.retrieve_symbol_graph: 1`.

Expected, per section 1–3:
1. `DivergentIsolation()` call site → top-level result = the class (its USR), plus
   `key.secondary_symbols[0]` = `init()` with USR `...ACycfc` (the exact USR the `symbolInfo`
   check already returned) and a `fully_annotated_decl` whose XML contains the `nonisolated`
   node; the class-level result's declaration contains `@MainActor`. USR selection picks the
   init; the edge is correctly judged non-crossing.
2. `isolatedMethod()` call site → single result, USR `...isolatedMethodyyF`,
   `@MainActor` present in both `fully_annotated_decl` and the symbol-graph attribute fragments.
3. The module-default fixture's member → `@MainActor` present (same materialization mechanism
   already proven for hover; this is the regression check that the transport change loses
   nothing).
4. `sourcekitdInProc` loads via the `libIndexStore` `dlopen` pattern
   (`ToolchainLocating` precedent), one in-process session reused across all queries.

Any deviation localizes to the cited source immediately. If all four hold, the integration
design has its final transport decision input, and every obligation carried out of the research
phase (explicit `unknown`, per-edge actual-member queries, USR matching with the
synthesized-suffix rule, structured-format parsing) is implementable against a fully
source-and-empirically-verified oracle.
