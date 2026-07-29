# Compiled-dependency isolation — sourcekit-lsp spike (de-risking record)

Per `docs/task-compiled-dependency-isolation.md` section 2.4's explicit instruction: *"the first
thing the next session should spike empirically (send a `textDocument/hover`... for
`UITableViewCell` and separately for `SwiftUI.View`, from one running `sourcekit-lsp` process, and
confirm the response text actually surfaces MainActor isolation for both, before designing
anything around it)."* Same discipline as `docs/priority-2-phase-0-spike.md`: verified against the
real local toolchain, not assumed from documentation. No production code depends on this yet — the
spike code (a scratch SwiftPM package + a Python JSON-RPC driver) lived entirely under `/private/tmp`,
outside this repo, and was not added to the tree, matching this project's "throwaway spike code is
deleted, only the durable finding remains" convention.

## What was run

A scratch SwiftPM package (`platforms: [.macOS(.v13)]`, to avoid iOS-simulator overhead — AppKit's
`NS_SWIFT_UI_ACTOR` mechanism is textually identical to UIKit's, confirmed independently below) with
four fixture files, each hovered via a real, long-lived `sourcekit-lsp` subprocess driven over raw
JSON-RPC (`initialize` → `initialized` → `textDocument/didOpen` → `textDocument/hover`):

1. **Mechanism A substitute** (ObjC-bridged, header-macro isolation) — `NSCell` instead of
   `UITableViewCell`, chosen because it avoids the iOS SDK/simulator entirely while being the exact
   same mechanism: confirmed empirically that `NS_SWIFT_UI_ACTOR` sits directly above `@interface
   NSCell : NSObject ...` in `AppKit.framework/Headers/NSCell.h` (found via a header scan; most other
   AppKit classes only carry the macro on individual *methods*, not the class declaration — `NSCell`
   was verified to be a true class-level match before use).
   ```swift
   final class SpikeCell: NSCell {
       func touch() { self.title = "x" }
   }
   ```
2. **Mechanism B** (pure Swift + library evolution, `.swiftinterface`) — `SwiftUI.View`:
   ```swift
   struct SpikeView: View {
       var body: some View { Text("hi") }
   }
   ```
3. **Case 4** (binary-only, **no `.swiftinterface` at all**) — a synthetic dependency built on
   purpose, per the task doc's own suggested method: a tiny package (`SpikeDep`) with
   `@MainActor open class DepBase`, compiled *without* `-enable-library-evolution`
   (`swiftc -emit-module -emit-library`, matching deployment target explicitly via `-target
   arm64-apple-macosx13.0` to avoid an SDK-default-version module-compat error). Confirmed via
   `find -iname '*.swiftinterface'` that the build directory contains only
   `SpikeDep.swiftmodule`/`.swiftdoc`/`.swiftsourceinfo`/`.abi.json` + `libSpikeDep.dylib` — no
   textual interface of any kind. Wired into the main spike package via `unsafeFlags` (`-I`/`-L`/
   `-lSpikeDep`/`-rpath`), then subclassed:
   ```swift
   import SpikeDep
   final class SpikeDepSubclass: DepBase {
       override func touch() {}
   }
   ```
4. **Negative control** — a plain class with no isolated ancestor at all, to rule out
   `sourcekit-lsp` simply decorating every hover with `@MainActor` regardless of ground truth:
   ```swift
   final class PlainNonisolated { func touch() {} }
   ```

Ground truth for the mechanism-A substitute was independently re-verified the same way
section 2.1 of the task doc verified `UITableViewCell` — a paired real-`swiftc`-typecheck proof, not
assumed:
```swift
// subclasses NSCell — compiles clean (exit 0)
final class Wrapper { @MainActor var value: Int = 0 }
final class CellRepro: NSCell {
    let wrapper = Wrapper()
    func mutate() { wrapper.value = 1 }   // no error
}
// identical body, plain class instead of NSCell — hard compiler error (exit 1):
// "main actor-isolated property 'value' can not be mutated from a nonisolated context"
```
Confirms `NSCell` is a faithful stand-in for `UITableViewCell`'s exact mechanism before spending any
spike time on it.

## What came back

All four `textDocument/hover` requests, at the position of each type's own name in its declaration:

| Fixture | Hover result |
|---|---|
| `SpikeCell : NSCell` (mechanism A) | ```@MainActor final class SpikeCell : NSCell``` |
| `SpikeView : View` (mechanism B) | ```@MainActor struct SpikeView : View``` |
| `SpikeDepSubclass : DepBase` (case 4) | ```@MainActor final class SpikeDepSubclass : DepBase``` |
| `PlainNonisolated` (negative control) | ```final class PlainNonisolated``` — **no** `@MainActor` |

A fifth check — hovering directly on the **external** token (`NSCell` itself, referenced inside
`SpikeCell`'s own declaration line, not the project's own subclass name) — also resolved:
```swift
@MainActor @_nonSendable(_assumed) class NSCell : NSObject, NSCopying, NSCoding, ...
```

**This directly answers the task doc's open question in section 3: case 4 is solvable.**
`sourcekit-lsp` recovers isolation from a `.swiftmodule`-only dependency with no textual interface
of any kind, because it resolves through the compiler's real serialized semantic model (confirmed
by section 2.4's reasoning — this is exactly what Xcode's own Quick Help uses), not by re-deriving
facts from header/interface text. All three mechanisms (A, B, case 4) and the negative control
produced exactly the expected result, with no false positives.

## Two viable integration shapes, both confirmed working

1. **Hover on the project's own declaration** (`SpikeCell`, `SpikeView`, `SpikeDepSubclass`) returns
   the **already-fully-resolved effective isolation** — inheritance is pre-computed by the compiler,
   not something this tool needs to re-derive from a separately-fetched superclass fact. This is the
   simplest possible integration: for any project declaration whose superclass/protocol conformance
   isn't resolvable in `declarations[...]`, ask `sourcekit-lsp` to hover the declaration's own name
   token in its own source file and parse the leading attribute out of the returned Swift-syntax
   code block. No mechanism-specific branching (A vs. B vs. case 4) needed at all — one code path.
2. **Hover on the external symbol reference itself** (the `NSCell` token) also resolves, independent
   of any particular subclass — this is what would back a `DeclarationLinker`-style backfill keyed
   by the external symbol's own USR (this project's existing `protocolGlobalActorName` precedent),
   letting the result be cached once per external symbol rather than re-queried per subclass.

Both are real options for section 4's integration-point decision; this spike doesn't pick between
them — that's the next session's design step, now backed by evidence that either is viable.

## A new, concrete finding this spike surfaced — not yet in the task doc

The spike package above is a **SwiftPM** package (`Package.swift`), which `sourcekit-lsp`
auto-detects and drives with zero extra configuration (it invisibly ran `swift build` itself, per
`window/logMessage` notifications observed during the spike). **Both of this project's actual
real-world validation targets are not SwiftPM packages**:
```
~/SQLumen/SQLumen.xcodeproj          (no Package.swift)
Project Iris (docs/reference-project-corpora.md)   (no Package.swift)
```
`sourcekit-lsp --help` confirms three workspace-type discovery modes
(`--default-workspace-type [swiftPM|compilationDatabase|buildServer]`) — Xcode-project builds need
either a `compile_commands.json`/`compile_flags.txt` (`compilationDatabase` mode) or a
`buildServer.json` (`buildServer` mode, normally produced by the third-party `xcode-build-server`
tool, generated from an `xcodebuild -project/-workspace -scheme` invocation). **Neither exists yet
for either real-world project, and `xcode-build-server` is not installed on this machine** (absent
from `PATH`, present in `brew search` but not installed). This was not exercised or confirmed by
this spike — it's a real, concrete prerequisite for Definition-of-done item 4 (re-running against
`Project Iris`/`~/SQLumen` and diffing findings), not a hypothetical risk. **Next concrete step: spike
`xcode-build-server` (or an equivalent `compile_commands.json` generation path) against one of the
two real Xcode projects, confirm `sourcekit-lsp` picks up the resulting build settings, and only
then re-run the same hover check against a real `UITableViewCell`/`SwiftUI.View` symbol from that
project** — this spike used synthetic SwiftPM fixtures throughout, which proves the mechanism but
not yet the real-project plumbing.

## Operational notes for the next design step

- One `sourcekit-lsp` process should be started once per analysis run and reused for every hover
  query, not spawned per-symbol — `initialize` is the expensive step; each subsequent `didOpen`/
  `hover` round-trip was fast (full 4-fixture run including artificial 2s post-`didOpen` indexing
  waits per file: ~8.7s wall time total). This matches the project's existing single-long-lived-
  process pattern for `IndexStoreDB` (`docs/priority-2-phase-0-spike.md`).
- The 2-second sleep between `didOpen` and `hover` used in this spike was not tuned — it was enough
  for correct results on a tiny fixture package; the real indexing-completion signal (rather than a
  fixed sleep) should be determined during the next design step (candidates: waiting for the
  `window/logMessage` "Indexing" completion notification, or retrying hover until a non-empty result
  arrives).
- `swift-ide-test` remains absent from this toolchain (confirmed again, consistent with section 2.4)
  — not relevant to this finding since `sourcekit-lsp` needed no such tool.

## Status (original spike)

This spike (mechanism A substitute, mechanism B, case 4, negative control, both integration shapes)
is **complete and passed** — the core empirical question the task doc asked for is answered: yes,
for all three tiers, unambiguously, via `textDocument/hover`. No spike code remains in this
repository (it lived under `/private/tmp`, never added to the tree). The Xcode-project
build-settings-discovery gap above is a new, unstarted, concrete follow-up — the next actual
blocker before this task's Definition of done (section 3) can be satisfied end-to-end.

## Addendum (2026-07-26): cross-checked against an independent researcher's proposal

A second researcher, working without macOS/toolchain access, independently produced
`solution-compiled-dependency-isolation.md`, recommending `swift symbolgraph-extract` over
`sourcekit-lsp` hover as the primary oracle, backed by direct citations of `swiftlang/swift`
(`main` branch) source. Its central claim (its "Fact 4" / "the inferred-isolation trap", section 3):
hover/cursor-info's printer (`printQuickHelpDeclaration`) only prints *attached* attributes, never
compiler-*inferred* isolation — so a symbol whose `@MainActor`-ness comes purely from inheritance
with no attribute physically on the leaf declaration would print nothing. This directly implied my
original spike's positive mechanism-A/B/case-4 results might not generalize, since none of my
original fixtures tested a *pure* inheritance-only inferred case in isolation from an
explicitly-attributed one.

**Both of that document's central claims were checked empirically, with real, decisive, opposite-
in-part results — not assumed from either side:**

1. **The "inferred-isolation trap" claim is empirically REFUTED on this toolchain (Xcode 26.4.0 /
   Apple Swift 6.3) for declaration-level hover.** Built a synthetic dependency
   (`@MainActor open class IsolatedRoot`, `open class InferredChild: IsolatedRoot {}` — **zero**
   attribute on `InferredChild` itself, exactly the failure case the other document describes),
   compiled binary-only (no `.swiftinterface`). Ground truth reconfirmed first, same paired-repro
   discipline as every other finding in this project: calling `InferredChild.touch()` from a
   nonisolated context is a real compiler error (*"main actor isolation inferred from inheritance
   from class 'IsolatedRoot'"*). Hovering `InferredChild` **as an external reference the consuming
   project does not itself subclass** — the precise scenario the other document says must fail —
   returned ```@MainActor class InferredChild : IsolatedRoot```. Whatever print path
   `sourcekit-lsp`'s hover actually uses on this shipped toolchain, it does consult resolved
   `ActorIsolation`, not just attached-attribute text — contradicting the other document's Fact 4
   as literally stated for this Swift version. (That document explicitly flagged its own risk:
   *"Sources read are main-branch; the Xcode 26.4 toolchain may differ in detail"* — this is exactly
   such a case, and worth a note back to that researcher.)

2. **The other document's *separate*, section-4 "module-default isolation" gap is empirically
   CONFIRMED — this is a real, narrower hole, not a false alarm.** Built a second synthetic
   dependency compiled with `-default-isolation MainActor` (SE-0466/478), containing a class with
   **no `@MainActor` anywhere and no isolated superclass at all** — isolation exists solely because
   of the module's own build flag. Ground truth reconfirmed the same way: calling its method from a
   nonisolated context is a real compiler error, and — new finding, not in either document —
   **this holds even for a consumer that does not itself pass `-default-isolation MainActor`**, i.e.
   the resolved isolation is baked into the compiled module, not re-derived per consumer.
   Hovering **the bare class declaration** of this type — both the external type directly, and a
   project-owned subclass of it — returned plain ```class ModuleDefaultIsolated```/
   ```final class ProjectSubclassOfDefault : ModuleDefaultIsolated```, **no `@MainActor` at all**.
   This one case is a genuine, confirmed blind spot for hover used this way.

3. **The practical fix for (2), found empirically, is narrower than either document assumed: query
   a *member*, not the bare type declaration.** Hovering `.touch()` — as a direct call on the
   module-default type, and separately as a call through the project's own subclass
   (`x.touch()` where `x: ProjectSubclassOfDefault`) — **both** returned
   ```@MainActor func touch()```, correctly, in every case tried. Cross-checked against the real
   `.swiftinterface` text for an (unrelated, library-evolution-enabled) build of the same fixture:
   the interface's `swift-module-flags:` header does **not** contain `-default-isolation` at all
   (contradicting the other document's section-4 suggestion to recover it from there) — but each
   individual member is printed with an explicit `@_Concurrency.MainActor` attribute regardless of
   whether the source ever wrote one, confirming the interface generator itself materializes
   resolved isolation per-member, which is exactly what member-level hover surfaces too. A
   member-level negative control (a genuinely nonisolated method) hovered clean, no false positive.
   **Practical conclusion: for any query the tool actually needs — "does this specific call/member-
   access cross an isolation boundary" — hovering the member/call site, not the bare type name,
   closes 100% of the cases tested across both documents, including the one real gap the other
   researcher correctly predicted.** ~~Where a bare per-type answer is still wanted..., hover a
   canonical member (its initializer, e.g.) instead of the type name itself.~~ **Retracted by the
   second addendum below — member isolation can genuinely diverge from type isolation (a
   `nonisolated init` on an otherwise-`@MainActor` type is routine), so a canonical-member proxy is
   unsound in general. Query the actual referenced member for each edge, never a stand-in.**

4. **SwiftPM-package coverage, per explicit user follow-up request, was checked against a real,
   non-synthetic project, not just fixtures.** Ran the same `sourcekit-lsp` hover approach against
   this repository itself (`swift-isolation-map`'s own `Package.swift`, a real multi-dependency
   graph: `swift-syntax`, `swift-argument-parser`, `indexstore-db`, `swift-lmdb`) — hovering the
   real `IndexStoreDB` usage in `Sources/IndexStoreIntegration/IndexStoreClient.swift:38`.
   `sourcekit-lsp` auto-resolved the entire manifest graph with zero extra configuration and
   returned a correct, clean result (```final class IndexStoreDB``` plus its real doc comment, no
   spurious isolation attribute — correct, since `IndexStoreDB` genuinely isn't actor-isolated).
   **Confirms the whole approach — not just the Xcode-project path (still blocked on
   `xcode-build-server`, per the original spike above) — already works end-to-end, today, with zero
   extra plumbing, for any project that is itself a SwiftPM package**, real or synthetic.

**Where this leaves the design decision:** the other researcher's `symbolgraph-extract` proposal
remains architecturally reasonable — it gives declarations + relationship edges in one batch per
module, which is a cleaner fit if the integration point ends up being a `DeclarationLinker`-style
bulk backfill rather than live per-call queries, and it may still be worth spiking directly (its
section 6 script is ready-to-run) as a comparison once the Xcode-project build-settings gap is
closed and there's a real end-to-end harness to compare both oracles against on real projects. But
its central argument for preferring it *over* hover — that hover structurally cannot see inferred
isolation — is now empirically known to be wrong on this toolchain for the inheritance case, and
only narrowly right for the module-default case, which member-level hover already closes. Hover
does not need to be demoted to "validation/spot-check" duty as that document proposed; it is a
viable primary oracle at the member-query granularity, still by far the simpler integration
(one process, one request type, no batch-extraction/caching/USR-filtering machinery to build).

No spike code for this addendum remains in the repository either (same `/private/tmp` scratch
package, extended with three more synthetic dependencies, never added to the tree).

## Second addendum (2026-07-26): design-deltas cross-check, mechanism confirmed in real source

A third document, `design-deltas-after-crosscheck.md`, reviewed the addendum above and contributed
three claims — checked the same way as before, empirically and against real compiler source, not
accepted on authority.

### 1. The mechanism behind the refutation — confirmed directly in `swiftlang/swift` `main`

Fetched the real files (`gh api repos/swiftlang/swift/contents/...`, not a fork, not a guess) to
check the claim that a typechecker function materializes inferred isolation as an implicit
attribute:

- `lib/Sema/TypeCheckConcurrency.cpp:6040`, `addAttributesForActorIsolation(Decl*, ActorIsolation)`
  — confirmed to exist exactly as described, called from the inference paths for per-decl inherited
  isolation (lines 6622/6625/6631), module-default isolation (6855/6866), and extensions (6884). For
  `ActorIsolation::GlobalActor` it does
  `CustomAttr::create(ctx, SourceLoc(), typeExpr, /*owner=*/decl, /*implicit=*/true)` — genuinely
  `implicit=true`, unlike ClangImporter's own explicit (`implicit=false`) attachment for mechanism A
  (the first document's Fact 1) — two different mechanisms, both real, confirmed in source.
- This raised a real question the design-deltas document itself flagged as open: `hover`'s own
  `PrintOptions::printQuickHelpDeclaration()` (`include/swift/AST/PrintOptions.h:892`) sets
  `PO.PrintImplicitAttrs = false` — so why does hover print an `implicit=true` attribute at all?
  Traced to the answer, in `lib/AST/Attr.cpp`, `DeclAttributes::print`, verbatim:
  ```cpp
  // Don't skip implicit custom attributes. Custom attributes like global
  // actor isolation have critical semantic meaning and should never be
  // suppressed. Other custom attrs that can be suppressed, like macros,
  // are handled below.
  if (DA->getKind() != DeclAttrKind::Custom &&
      !Options.PrintImplicitAttrs && DA->isImplicit())
    continue;
  ```
  The general "skip implicit attrs" rule explicitly excludes `DeclAttrKind::Custom` — which is
  exactly the kind `addAttributesForActorIsolation` uses for global-actor isolation. **This is a
  deliberate, named carve-out in the compiler's own shared attribute-printing code, not a
  toolchain-specific accident** — settles the question completely, and does so more precisely than
  either prior document (neither traced print-time back to this exact exclusion). Bonus: since this
  carve-out lives in the shared `DeclAttributes::print` used by any `PrintOptions`-based printer —
  not something specific to cursor-info/hover — it resolves the design-deltas document's own
  section-5 open question about whether `symbolgraph-extract`'s declaration fragments would also
  carry inferred isolation despite its `PrintImplicitAttrs = false`: very likely yes, same
  mechanism, same exemption. Not spiked directly (no need — hover already covers the requirement),
  but worth citing if `symbolgraph-extract` is ever picked up for a batch-shape comparison.

### 2. "Canonical member as type-isolation proxy" — confirmed unsound, with a useful nuance

Built a fourth synthetic dependency to test the caveat directly:
```swift
@MainActor
open class DivergentIsolation {
    nonisolated public init() {}   // explicitly nonisolated on an otherwise-@MainActor type
    open func isolatedMethod() {}  // takes the type's MainActor isolation
}
```
Ground truth first, same paired-repro discipline as every other finding: a nonisolated caller can
construct `DivergentIsolation()` with no error, but calling `.isolatedMethod()` on it is a real
compiler error — confirming genuine, real-world-realistic divergence between a type's own baseline
isolation and one specific member's.

Hovering the two call sites:
- `obj.isolatedMethod()` → clean single result, ```@MainActor func isolatedMethod()```.
- `DivergentIsolation()` (the initializer call) → **`"Multiple results"`**, containing *both*
  ```@MainActor class DivergentIsolation``` (the type's own isolation) *and*
  ```nonisolated init()``` (the specific initializer actually being invoked) as two labeled parts of
  one response.

This directly confirms the caveat: naively scanning hover text for "does `@MainActor` appear
anywhere" would misjudge this exact, ordinary call as unsafe when the real compiler accepts it
without error — the type-level block and the member-level block disagree, and only the member block
matches the invoked declaration. It also shows hover is more capable than a blind point-lookup would
suggest: it already disambiguates and surfaces the specific resolved declaration alongside the
type's own, as separate, labeled parts — so the fix is a parsing-discipline requirement (select the
result block matching the actually-invoked declaration, never "any `@MainActor` substring"), not a
need for a different oracle. The addendum's own suggestion above (¶3, "hover a canonical member as a
type-level stand-in") is retracted per this result — adopt the design-deltas document's fix instead:
resolve and hover the *actual* referenced member for each real edge (which `IndexStoreIntegration`
already does, USR + location, per existing edge data) — never a proxy member standing in for the
type as a whole.

### 3. `unknown` as a first-class outcome, and the `xcode-build-server` trust decision

Both restated points are sound engineering judgment rather than falsifiable technical claims, so
not independently re-tested — noted for whoever does the integration design:
- Every oracle-failure path (timeout, unresolved build settings, a module that doesn't load, a
  malformed position) must surface as `unknown` in the declarations table, never default to
  `.nonisolated` — orthogonal to which oracle is chosen, and this closes the *epistemic* half of the
  original bug regardless.
- The choice between depending on third-party `xcode-build-server` versus vendoring a minimal
  `xcodebuild build`-output-to-`compile_commands.json` translator is a real, deliberate
  trust/distribution decision for a correctness-focused tool (current install story is
  self-contained SPM+Homebrew) — flagged as a decision to make explicitly and in writing when DoD
  item 4 (real Xcode-project re-run) is picked up, not inherited implicitly from whatever happened
  to be spiked first.

### Status

Both checkable claims in `design-deltas-after-crosscheck.md` were verified: the compiler mechanism
against real `swiftlang/swift main` source (not a fork, not assumed), and the member/type isolation
divergence against a real, freshly-built synthetic dependency with a paired ground-truth compiler
proof. One piece of this addendum's own prior guidance (canonical-member-as-type-proxy) is corrected
as a result. No spike code added to the repository (same scratch package, one more synthetic
dependency; the `swiftlang/swift` source files fetched for citation-checking were read from
`/tmp`, not vendored into this repo).

## Third addendum (2026-07-26): research-phase closure — the USR-matching requirement, verified

A fourth document, `research-phase-closure-usr-matching.md`, closes the research thread with one
binding requirement for the integration phase: **oracle results must be matched to an edge by
comparing declaration USRs, never by scanning printed text** — because `textDocument/hover`'s
`"Multiple results"` response (second addendum, section 2) is a *set* of candidates, and only USR
equality picks the right one deterministically. It further claims hover's Markdown carries no USR
at all, which is why it proposes demoting *hover specifically* (not `sourcekit-lsp` as a transport)
in favor of `sourcekitd` cursor-info (`key.usr` + `key.fully_annotated_decl`) or
`textDocument/symbolInfo`, both of which do carry a structured USR per result.

**Checked directly, on the same running spike setup, reusing the `DivergentIsolation` fixture:**

- Every `textDocument/hover` response captured across this entire spike (re-checked, not assumed)
  contains only `contents` (Markdown) and `range` — **no `usr` field anywhere, confirmed.**
- `textDocument/symbolInfo` (the "nonstandard but supported" request the document names) **is
  real and works** — sent at the exact same position as the `DivergentIsolation()` init-call hover
  that earlier produced the ambiguous `"Multiple results"` response, it returned a structured
  array with **real per-result USRs**:
  ```json
  [
    {"usr": "s:4Dep418DivergentIsolationC", "kind": 5, "name": "DivergentIsolation", ...},
    {"usr": "s:4Dep418DivergentIsolationCACycfc", "kind": 9, "name": "init()", ...}
  ]
  ```
  and, separately, at the `isolatedMethod()` call site, a single result carrying
  `usr: "s:4Dep418DivergentIsolationC14isolatedMethodyyF"` plus `receiverUsrs` pointing back at the
  type's own USR. **This confirms the document's core factual claim directly: the ambiguity hover
  surfaces as unlabeled Markdown blocks is, at the `symbolInfo` layer, a set of results each
  carrying its own real, comparable USR** — exactly the structured anchor needed to pick the one
  matching a known call-graph edge (already resolved by `IndexStoreIntegration`) without any
  text/name heuristic.
- **Residual gap, not fully closed by this check:** `symbolInfo` itself carries no isolation
  annotation (no `@MainActor`/`nonisolated` in its response shape — only USR/kind/name/location) —
  so a real implementation still needs a second call for the annotated declaration text. If that
  second call is `hover` (no USR field), matching its unlabeled Markdown blocks back to the
  USR-confirmed `symbolInfo` result still requires some correlation (by declared name/kind, since
  position alone is what produced the ambiguity in the first place) — less clean than the
  document's proposed one-shot `sourcekitd` cursor-info (`key.usr` *and*
  `key.fully_annotated_decl` together, per its section 3). **Not spiked this round**: raw
  `sourcekitd` cursor-info requires the `dlopen`/C-ABI route (`sourcekitdInProc`, same class of
  dependency as `libIndexStore`, per the original task doc's section 2.4 and this project's
  existing `ToolchainLocating` precedent) rather than the JSON-RPC transport this whole spike
  thread has used — a real, not-yet-empirical step for whoever picks up the integration phase, to
  confirm the one-shot-usr-plus-annotated-declaration shape before committing to it over a
  `symbolInfo`-then-`hover` two-call correlation.

**Accepted as binding for the integration design**, consistent with the evidence above: resolve
each real call-graph edge's member (position already known, from `IndexStoreIntegration`) via a
USR-carrying request (`symbolInfo` confirmed working now; raw `sourcekitd` cursor-info to be
confirmed before final transport choice), match against the edge's own known USR, and only then
read isolation off the matched result — never off unlabeled hover text. Hover remains exactly what
it has been throughout this whole thread: the fast, zero-new-plumbing instrument that found every
mechanism (A, B, case 4, module-default, the divergence itself) and is not going anywhere as a
diagnostic — it is production per-edge resolution, specifically, that must go through USR matching.

No spike code added to the repository for this addendum (`textDocument/symbolInfo` requests sent
over the same throwaway `/private/tmp` scratch package and JSON-RPC driver as every prior check in
this file).

## Fourth addendum (2026-07-26): the raw `sourcekitd` cursor-info dlopen spike, actually run

A fifth document, `cursorinfo-oneshot-preverification.md`, armed the one step the third addendum
left unspiked: it read `SwiftSourceDocInfo.cpp`/`Requests.cpp` in real `swiftlang/swift` source and
pre-registered four falsifiable predictions for what raw `sourcekitd` cursor-info (via
`sourcekitdInProc`, `dlopen`, no JSON-RPC) would return. Per this project's own discipline, these
were treated as predictions to run, not facts to file away — so the dlopen client was actually
built and the four predictions actually checked, not accepted on the strength of the source
citations alone (which were independently spot-checked and matched: `fillSymbolInfo`,
`addCursorInfoForDecl`'s constructor-call comment, and the `AddSymbolGraph`/
`key.retrieve_symbol_graph` path were all found exactly as cited).

**Built:** a minimal, from-scratch Python 3 `ctypes` client for `sourcekitdInProc.framework`
(the project's own `tools/SourceKit/bindings/python/sourcekitd/capi.py` was used as the API-shape
reference, not imported directly — it has Python-2-only bugs, `dict.iteritems()` and a lazy
`map()` over `register_functions` that silently never registers a single function under Python 3 —
worth knowing if anyone else reaches for that file directly). Sent real
`source.request.cursorinfo` requests with `key.compilerargs`, `key.offset`, and
`key.retrieve_symbol_graph: 1` against the same `DivergentIsolation`/module-default fixtures
already on disk from prior addenda.

**A real bug found and fixed before any of the four predictions could be checked**: the first
attempt crashed sourcekitd itself (`SIGTRAP`/`_xpc_api_misuse`, confirmed via a macOS `.ips` crash
report after `lldb`'s own backtrace came back empty across the trap). Root-caused via `nm` (the
symbol genuinely resolves inside `sourcekitdInProc`, ruling out a symbol-collision theory) plus
instrumented step-tracing (crash isolated to the very first `sourcekitd_request_array_set_string`
call): **array elements must be appended at index `-1` (`SIZE_MAX` once passed through
`c_size_t`), never at sequential `0, 1, 2, ...`** — confirmed by rereading `capi.py`'s own `Object`
class, which does exactly this (`sourcekitd_request_array_set_value(self, -1, Object(v))`) and was
overlooked on the first pass. Sequential indices crash immediately because the array starts empty
and `xpc_array_set_*` (the primitive `sourcekitd`'s request objects are built on) rejects an
out-of-bounds index rather than growing the array to fit. **Worth carrying forward as a standing
note for the integration phase**: this is exactly the kind of primary-source detail that's present
in the reference implementation but easy to skim past — the same methodological lesson the fourth
document itself flagged in section 1 about reading full surrounding context, now hit firsthand
rather than just cited.

**All four pre-registered predictions confirmed, exactly:**

1. `DivergentIsolation()` init call → top-level result is the class, USR
   `s:4Dep418DivergentIsolationC`, `key.fully_annotated_decl` containing `@MainActor`;
   `key.secondary_symbols[0]` is `init()`, USR `s:4Dep418DivergentIsolationCACycfc` — **the exact
   same USR** the `symbolInfo` check in the third addendum already found independently — with its
   own `key.symbol_graph` declaration fragments reading
   `[{"kind":"attribute","spelling":"nonisolated"}, ...]`. USR selection against a known edge
   target picks the `init()` secondary result and only that one, correctly.
2. `isolatedMethod()` call → single result, USR `s:4Dep418DivergentIsolationC14isolatedMethodyyF`
   (matches `symbolInfo`'s prior finding), `@MainActor` present in **both** formats on the same
   result: `key.fully_annotated_decl` (XML, `<ref.class usr="s:ScM">MainActor</ref.class>`) and
   `key.symbol_graph` (JSON, `{"kind":"attribute","spelling":"MainActor","preciseIdentifier":"s:ScM"}`
   — a structural fragment, not a substring, exactly as predicted).
3. Module-default fixture (`Dep3.ModuleDefaultIsolated.touch()`) → `@MainActor` present in both
   formats, same as (2) — the regression check confirming the transport change from hover to raw
   cursor-info loses nothing of what the second addendum already proved for the module-default
   case.
4. `sourcekitdInProc` loads and answers multiple queries in one process via the `dlopen` pattern,
   consistent with this project's existing `ToolchainLocating`/`libIndexStore` precedent — no
   XPC/subprocess transport needed for this path, confirming the fifth document's framing of it as
   "the same class of dependency."

Also observed, matching the fifth document's framing exactly: `key.retrieve_symbol_graph: 1` really
does merge both oracle candidates from the whole thread into one response — `key.usr` +
`key.fully_annotated_decl` (XML) + `key.symbol_graph` (the same `SymbolGraphGen` JSON format
`symbol graph-extract` produces, scoped to one declaration) all present together on every result,
each carrying its own USR. The synthesized-extension USR-suffix nuance (point 4 of the fifth
document, `"::SYNTHESIZED::"`) was not separately exercised — no synthesized-extension member
appeared in any fixture used across this whole thread — noted as a real, low-risk, easy-to-implement
rule to apply in the integration code rather than something requiring its own fixture right now.

**Status: the research phase's single remaining unverified step is now verified.** Every falsifiable
claim across all five documents in this thread has been checked empirically against this machine's
real toolchain (Xcode 26.4.0 / Apple Swift 6.3) — mechanisms A/B/case 4, the negative control, the
Sema materialization mechanism and its print-time carve-out, the module-default gap and its
member-level resolution, the type/member isolation divergence, USR-matching via `symbolInfo`, and
now the full one-shot `sourcekitd` cursor-info shape via a real, working `dlopen` client. Nothing
falsifiable remains open. No spike code added to the repository (the `ctypes` client, fixture
files, and fetched `swiftlang/swift` source used for citation-checking all live under
`/private/tmp` and `/tmp`, never added to this tree).
