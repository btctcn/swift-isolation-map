# Research-phase closure: final cross-review notes and the USR-matching requirement

**Status: review record + one binding design requirement for the integration phase.** Fourth and
final document of the compiled-dependency-isolation research thread, responding to the second
addendum of `compiled-dependency-isolation-sourcekit-lsp-spike.md`. All falsifiable claims across
the thread (`task-compiled-dependency-isolation.md` → `solution-compiled-dependency-isolation.md`
→ the spike document and its two addenda → `design-deltas-after-crosscheck.md`) are now
cross-verified between two independent researchers; every claim that turned out wrong has been
retracted *with its mechanism identified*, not merely observed to fail. This document closes the
research phase with two review notes and one concrete requirement that the integration design
must adopt.

## 1. Review note: the `Attr.cpp` carve-out, and a methodology lesson worth recording

The second addendum's trace of hover's implicit-attribute printing to the shared
`DeclAttributes::print` carve-out —

```cpp
// Don't skip implicit custom attributes. Custom attributes like global
// actor isolation have critical semantic meaning and should never be
// suppressed. ...
if (DA->getKind() != DeclAttrKind::Custom &&
    !Options.PrintImplicitAttrs && DA->isImplicit())
  continue;
```

— is accepted as the most precise explanation in the thread, superseding the earlier
`design-deltas-after-crosscheck.md` section-1 account (which correctly identified the Sema-side
materialization but left the print-time question open). One detail belongs in the record for
methodological honesty: **the decisive line was already present, verbatim, in the grep output of
the very session that formulated the now-refuted "inferred-isolation trap" claim** — captured as
a match on `!Options.PrintImplicitAttrs && DA->isImplicit()` but read without its surrounding
condition, so the `DeclAttrKind::Custom` exemption in the same `if` went unseen. This is the
same failure class as the project's earlier `evolution.json` WebFetch-summarization incident
(see the PR #2 follow-up record): a truncated excerpt of a primary source can confirm a wrong
conclusion exactly as convincingly as the full source would have refuted it. Standing rule
worth adopting alongside the existing "verify against primary sources" discipline: **when a
grep match is used as evidence, read the full surrounding construct, not the matching line.**

Consequence the carve-out settles for free: because it lives in the shared attribute-printing
path used by *any* `PrintOptions`-based printer — not in anything cursor-info/hover-specific —
`symbolgraph-extract`'s declaration fragments very likely carry inferred isolation through the
same exemption, despite that printer's `PrintImplicitAttrs = false`. This resolves
`design-deltas-after-crosscheck.md`'s section-5 open question in the affirmative, cited-not-
spiked, and only matters if the batch shape is ever revisited for performance.

## 2. Review note: what the `"Multiple results"` finding actually changes

The `DivergentIsolation` experiment (fourth synthetic dependency: `@MainActor` class with an
explicitly `nonisolated public init()`) is more valuable than a confirmed caveat. Hovering the
initializer call returned *both* the type's declaration (`@MainActor class DivergentIsolation`)
*and* the invoked member's (`nonisolated init()`) as separate labeled parts of one response —
meaning the oracle already disambiguates and surfaces the resolved invoked declaration alongside
the type's own. That upgrades the caveat from a prohibition ("don't proxy type isolation through
a member") into a **positive parsing-discipline requirement**: the oracle's answer is a *set* of
candidate declarations, and correctness depends entirely on selecting the one that matches the
actually-invoked declaration. Any implementation that scans the response for the presence of
`@MainActor` anywhere would misclassify this ordinary, compiler-accepted call as a high-risk
cross-isolation edge — recreating, in miniature, the exact confident-wrong-answer failure mode
this whole task exists to eliminate.

## 3. Binding requirement for the integration design: match oracle results by USR, never by text

The requirement that closes section 2's problem deterministically, with zero heuristics:

**For every analyzed edge, the oracle query must be resolved to a specific result by comparing
declaration USRs — the edge's member USR, which `IndexStoreIntegration` already resolves per
edge, against the USR carried by each oracle result. Text-level selection ("does `@MainActor`
appear", "take the first code block") is prohibited.**

Both viable transports provide the USR in structured form; LSP hover's human-oriented Markdown
does not, which demotes *hover specifically* (not sourcekit-lsp as a whole) from production duty
to what it has already served as: the ideal spike/diagnostic instrument.

- **`sourcekitd` cursor-info** (`source.request.cursorinfo`): per result, `key.usr` +
  `key.fully_annotated_decl` — XML in which `@MainActor`/`nonisolated` are structural nodes, not
  substrings. Same Apple-shipped-dylib dependency class as `libIndexStore`, for which this
  project already has a working `dlopen` precedent and pattern (`sourcekitdInProc` is present on
  the reference machine, per the original task spec's section 2.4).
- **sourcekit-lsp `textDocument/symbolInfo`** (nonstandard but supported request): returns
  symbol details including the USR, over the same long-lived JSON-RPC subprocess the spike
  already drove successfully — no `dlopen`/C-ABI bridging.

The resulting per-edge resolution loop is closed entirely within the project's native identifier
system: edge position (already known) → cursor-info/symbolInfo at that position → select the
result whose USR equals the edge's member USR → read isolation from that result's structured
declaration → feed the engine. The `DivergentIsolation` case is then correct *by construction*:
the initializer edge matches the `nonisolated init()` result and only that result. Transport
choice (long-lived `sourcekit-lsp` subprocess vs. in-process `sourcekitdInProc` via the
`libIndexStore` pattern) is an ordinary engineering decision for the integration phase; the
USR-matching rule is not — it is a correctness requirement, transport-independent, and any
future oracle (including a revived `symbolgraph-extract`, whose `precise` identifiers are USRs)
must satisfy it the same way.

## 4. Where the thread stands

Research phase closed. Verified across the thread: mechanisms A and B, case 4 (solvable),
negative controls, the Sema materialization mechanism with its print-time carve-out, the
module-default gap and its member-level resolution, and the member/type divergence with its
USR-matching fix. Standing obligations carried into the integration phase, none of them open
questions: explicit `unknown` for every oracle-failure path (never a silent `.nonisolated`);
per-edge queries against actual referenced members (no proxies); USR-based result matching
(section 3). **The single remaining blocker before Definition-of-done item 4 is reachable: the
Xcode-project build-settings decision** — third-party `xcode-build-server` versus a vendored
`xcodebuild`-log→`compile_commands.json` translator — to be made explicitly and in writing, per
`design-deltas-after-crosscheck.md` section 4, before integration work begins.
