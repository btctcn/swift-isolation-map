# External Objective-C property accessor USR mismatch — research brief

Written for someone picking this up fresh, with no prior context on this specific investigation.
Supersedes the first draft of this file (which stopped one layer too shallow — see "What earlier
drafts of this investigation got wrong" below). If you're new to this codebase, skim
`docs/isolation-rules.md` and `docs/architecture.md` §1.5 first; this file assumes you already know
what `RawIndexStoreClient`, `DeclarationLinker`, `BulkSymbolGraphExtractor`, and
`ExternalIsolationBackfill` each do.

## 1. The problem, precisely

Measuring the real-world impact of an unrelated fix (PR #80, bulk-cache SE-0316 inheritance) against
a real ~40-dependency, ~2200-file Xcode workspace, the aggregate `unknown`/`unspecified` edge count
barely moved (24031 → 24030 medium edges) despite that fix being real, tested, and independently
confirmed correct (`UIWindow.init` now resolves). Root-caused to a much bigger, separate issue that
dominates this corpus's residual `unknown` count: the highest-frequency unresolved callees are all
**Objective-C property accessors** — `UIView.leadingAnchor`/`.trailingAnchor`/`.topAnchor`/
`.bottomAnchor`/`.heightAnchor` (getters), `UIViewController.view`, `UITableViewCell.contentView`,
`UIView.layer` (getters), `UILabel.setText:`/`.setTextColor:`/`.setFont:`/`.setAttributedText:`,
`UIView.setHidden:`/`.setBackgroundColor:`/`.setLayer:` (setters) — each with hundreds to over a
thousand real edges in this one corpus alone.

## 2. Why this happens — confirmed mechanism, not guessed

Objective-C interop, via ClangImporter, has two coexisting representations of the same declaration:
- **The Swift-visible facade**: ClangImporter synthesizes a single Swift `var text: String { get set }`
  for an Objective-C `@property`/getter-setter pair. This is the *only* thing Swift source code can
  reference (`label.setText(...)` is not callable Swift), and it's what `swift symbolgraph-extract`
  documents — confirmed directly: extracted a real UIKit module on this machine, `grep`'d the raw
  JSON (all 8 sibling `*.symbols.json` files, not just the primary one, full-text substring search,
  not just the structured `relationships`/`symbols` arrays) for `setText`, `setHidden`, and the
  general substring `accessor` — zero real matches for any ObjC accessor-method identifier or any
  accessor/property cross-reference of any kind. `symbolgraph-extract` genuinely never emits these,
  not a parsing gap on this project's side.
- **The underlying Clang-level declaration**: the real `-setText:` method as declared in UIKit's own
  header is still a real, indexable AST node inside the compiler's model — ClangImporter needs it to
  know what to `objc_msgSend` when the synthesized setter runs. `libIndexStore` (and therefore this
  project's own call graph, via `RawIndexStoreClient`) records a property mutation/read against
  *this* declaration's own USR (Clang USR grammar: `c:objc(cs)<Class>(im)setText:` for the setter,
  `c:objc(cs)<Class>(im)text` for a getter that happens to share the property's bare name) — not the
  synthesized Swift property's USR (`c:objc(cs)<Class>(py)text`).

Neither tool is wrong. `symbolgraph-extract` correctly documents the Swift-facing API surface;
`libIndexStore` correctly records the real, lowered call target. The mismatch is a genuine seam
between two legitimate views of the same declaration, and this project's own bulk cache (keyed by
raw USR equality) falls straight into it.

## 3. This project already solved a *sibling* version of this problem — read this before doing anything else

`docs/task-compiled-dependency-isolation-usr-granularity.md`, "Gap A" — **CLOSED**, already shipped.
It fixes the *same class* of problem for **pure-Swift properties**: `IndexStoreDB`'s call graph
records `Date.timeIntervalSince1970` as a call to that property's Swift-mangled synthesized-accessor
USR (`s:10Foundation4DateV21timeIntervalSince1970Sdvg`, note the trailing `vg`/`vs`/`vM` mangling
suffix), distinct from the property's own USR that both `symbolgraph-extract` and live `cursorinfo`
key by. The fix: `RawIndexStoreClient.owningPropertyUSR(forUSR:)`
(`Sources/IndexStoreIntegration/RawIndexStoreClient.swift:76-83`), using `libIndexStore`'s own real
`.accessorOf` relation, applied inside `DeclarationLinker.link(_:)`'s `canonicalized(_:)` step
(`Sources/IndexStoreIntegration/DeclarationLinker.swift:356-364`) to rewrite **both** `callerUSR` and
`calleeUSR` of *every* call-graph edge, before the external oracle ever sees them.

**This is the mechanism you'd reach for to fix the ObjC-property case too — and it may already
partially work, or may need a narrow, well-justified change, not a new mechanism.** Do not build a
second, parallel accessor-resolution system. Understand why this one doesn't currently cover the
ObjC case first.

### Why it doesn't currently cover the ObjC case

`owningPropertyUSR`'s exact implementation:

```swift
public func owningPropertyUSR(forUSR usr: String) -> String? {
    relationsBySymbolUSR[usr]?.first {
        $0.occurrenceRoles & INDEXSTORE_SYMBOL_ROLE_DEFINITION != 0 && $0.role & INDEXSTORE_SYMBOL_ROLE_REL_ACCESSOROF != 0
    }?.targetUSR
}
```

It only trusts an `.accessorOf` relation attached to a `.definition`-role occurrence of `usr`. An
external SDK symbol like `UIView.leadingAnchor`'s getter is **never locally defined** (this project
never compiles UIKit's own source) — only *referenced*, at real call sites. So this lookup always
returns `nil` for every external accessor, by construction, regardless of whether the underlying
relation data actually exists.

**This restriction was added on purpose, to fix a real regression — but check whether its scope is
now broader than the regression actually required.** The history
(`docs/task-raw-indexstore-spike.md`, "A real regression found and fixed along the way"): an earlier,
*unscoped* version of this function collected `.accessorOf` relations from *any* occurrence, not just
`.definition`-role ones. This broke a golden-fixture test
(`Tests/swift-isolation-mapTests/CompiledDependencyCLITests.swift:259`, `NSCell.setTitle:`) that
expected the edge's `calleeUSR` to stay as the raw setter USR (`isUnknown: true`, `.medium` risk) —
canonicalizing it to `c:objc(cs)NSCell(py)title` instead was, at the time, treated as the bug.

**Read that test's own comment closely — it does not assert canonicalizing to the property is
factually wrong.** It documents `unknown` as the *correct, honest* answer *given the tool's
then-current inability* to resolve this case ("a real, naturally-occurring USR-granularity miss ...
correctly `unknown`, not a confirmed risk, never silently dropped or miscounted either" — framed as
accepting a known limitation, not asserting the canonicalized value would have been wrong data). The
original bug report's own wording ("the unscoped lookup wrongly treated \[a reference occurrence's
relation\] as authoritative") is itself ambiguous about *why* it was wrong. Three distinct
hypotheses, not two:
- (a) the resulting USR was **factually incorrect** — pointed at the wrong property, or a
  fabricated one;
- (b) it was *correct*, but distrusted purely because it came from a non-definition occurrence, on
  principle;
- (c) **the unscoped `.first` was nondeterministic, not the relation itself being wrong** — if a
  single reference occurrence can carry *more than one* `.accessorOf` relation (e.g. something about
  how the occurrence relates to both a getter and a setter, or to more than one candidate property),
  `.first` would silently pick whichever one `relationsBySymbolUSR[usr]`'s own array-building order
  happened to put first — a real, reproducible-looking bug from the *outside*, but with a completely
  different fix than either (a) or (b) implies. Nothing in either doc rules this out, and it directly
  determines what step 1 below should actually measure. This was never disambiguated, as far as this
  document's author could find. **That's the open question this task needs to answer empirically, not
  by re-reading old comments further.**

## 4. What earlier drafts of this investigation got wrong

An earlier pass considered two fix directions and rejected both without finding this section 3
history first:
1. *"Extend bulk-cache's own data to expose an accessor↔property relationship."* Empirically dead —
   confirmed `symbolgraph-extract` never emits accessor-method symbols at all (section 2 above), so
   there is nothing in bulk data to relate. Correctly ruled out, stays ruled out.
2. *"String-transform `setXxx:` → `xxx` per Clang USR grammar."* Explicitly rejected by the project
   owner as unreliable — Objective-C supports custom accessor names (`getter=`/`setter=` property
   attributes), which a naive transformation gets silently, confidently wrong. This violates the
   project's own Guiding Principle (a wrong answer is worse than no answer) and should not be revived
   unless paired with a way to *verify* the derived USR actually exists before trusting it (e.g.
   checking it resolves in the bulk-extracted property list) — even then, treat as a fallback of last
   resort, not a first choice.

Neither pass noticed that a *directly relevant* mechanism (Gap A) already exists and already made a
deliberate, documented, but possibly overly-broad choice about exactly this shape of problem. That's
the real starting point.

## 5. Concrete next steps

1. **Query the real index store directly, empirically, before changing any code — and count
   relations, don't just check the first one.** Against a real project's index store (this session
   used `/Users/ab/ios/lsboutique.xcworkspace`, scheme `ls.net.ru` — real, ~40 CocoaPods/SPM
   dependencies, `~/Library/Developer/Xcode/DerivedData/lsboutique-*/Index.noindex/DataStore` once
   built with `--force-reindex`), check `relationsBySymbolUSR["c:@CM@UIKit@@objc(cs)UIView(im)
   leadingAnchor"]` (a *reference*-only occurrence, never a definition) with `.filter`, not `.first`:
   **how many entries carry `INDEXSTORE_SYMBOL_ROLE_REL_ACCESSOROF`, not just whether at least one
   does.** This directly separates hypothesis (c) above from (a)/(b) — if a reference occurrence
   routinely carries more than one `.accessorOf` relation, `.first`'s nondeterministic pick (not the
   relation data itself) is the real bug, and the fix is "pick correctly among candidates" or "reject
   and fall through to `unknown` when the choice is ambiguous," never "trust reference occurrences
   in general." If it's consistently exactly one, that rules out (c) and narrows the question back to
   (a) vs (b). Do this across several real accessor USRs, not one — the getter case (bare name) and
   the setter case (`setXxx:` prefix) may behave differently, and check whether `targetUSR` correctly
   equals `c:objc(cs)UIView(py)leadingAnchor` for whichever relation(s) are found.
2. **Re-examine the original regression's exact data, if reproducible.** Was
   `c:objc(cs)NSCell(py)title` (what the unscoped lookup produced for `setTitle:`) actually the
   *correct* USR for `NSCell`'s real `title` property, or was it wrong — and did that occurrence
   carry exactly one `.accessorOf` relation, or more than one that `.first` silently chose between?
   If reproducible with a small real repro (an `NSCell` subclass, or any similarly-shaped real ObjC
   class with a property/setter pair), settle this directly rather than trusting either doc's own
   wording.
3. **If reference-occurrence `.accessorOf` relations turn out reliable when uniquely present**
   (hypothesis (c) confirmed, or ruled out with a consistently-single, consistently-correct relation),
   the fix is likely narrow: relax `owningPropertyUSR`'s `.definition`-role requirement specifically
   for the case where `usr` has *no* definition occurrence at all (i.e., a genuinely external symbol)
   — fall back to trusting a reference occurrence's relation *only* in that case, still preferring a
   definition-role relation when one exists (preserves today's behavior for project-local code
   entirely), and **explicitly log/reject (never silently `.first`) the case where more than one
   `.accessorOf` candidate exists on the same occurrence** rather than guessing. Also verify the fix
   rewrites `callerUSR` and `calleeUSR` **symmetrically**, matching how `DeclarationLinker.
   canonicalized(_:)` already applies `owningPropertyUSR` to both sides of every edge for Gap A — an
   asymmetric fix (only ever canonicalizing `calleeUSR`, say) would silently miss the case where the
   isolation-relevant side of a boundary is the *caller*. Re-run `CompiledDependencyCLITests`'s
   `NSCell.setTitle:` assertion with fresh eyes — it may need to change from `isUnknown: true` to a
   real resolved expectation, which would be the fix working, not a regression, provided the
   reasoning behind the change is written into the test's own updated comment.
4. **If reference-occurrence relations turn out genuinely unreliable even after accounting for
   hypothesis (c)** (inconsistent, sometimes wrong target even when uniquely present), this task's fix
   direction changes entirely, and BOTH candidate directions from section 4 are actually dead — that
   finding itself would be valuable to record precisely (which cases were wrong, and why) before
   considering a third approach.
5. **Measure real impact the same way Gap A did**: `docs/task-raw-indexstore-spike.md`'s temporary
   diagnostic technique (log a bulk/live hit-or-miss right where each trigger loop in
   `ExternalIsolationBackfill.swift` checks it, short-circuit to `unknown` under an env-var guard so a
   full pass completes in seconds instead of tens of minutes) is the fast, cheap way to verify any fix
   without a full real-corpus run every iteration. A full real run (this session used
   `.build/release/swift-isolation-map <workspace> --scheme <scheme> --severity high --output json
   --out-file result.json --verbose`, no `--force-reindex` if the index store is already fresh) is
   still worth doing once at the end for a real before/after `medium`/`unknown` edge count, the same
   way this session did (see `/tmp/lsboutique_diag_run.json` vs `/tmp/lsboutique_fix_run.json`-style
   comparison, though those specific temp files won't survive between sessions — regenerate).

## 6. Explicitly out of scope for this task

- The already-closed Gap A (Swift-mangled `vg`/`vs`/`vM` accessor case) — don't touch, don't re-verify
  unless a change here risks breaking it (it shares `owningPropertyUSR`, so regression-test it).
- Changing `IsolationInferenceEngine` or the risk heuristic — unrelated, stays untouched.
- The bulk-cache SE-0316 inheritance fix (PR #80) — already shipped, separate concern, real but small
  impact on this specific corpus (one edge, `UIWindow.init`) precisely because this accessor-mismatch
  issue dominates the same corpus's residual `unknown` count.
