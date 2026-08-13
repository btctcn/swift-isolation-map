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

## 5. Spike results — empirical, against the real lsboutique index store

Done: a temporary `RawIndexStoreClient.debugAllRelations(forUSR:)` (unfiltered, every relation
attached to any occurrence of a USR) plus a temporary test querying it directly against the real,
on-disk index store (`~/Library/Developer/Xcode/DerivedData/lsboutique-*/Index.noindex/DataStore`),
for nine real accessor USRs. Both are temporary and must be reverted before this branch merges
anything else (see section 7).

**Finding 1 — hypothesis (c) is ruled out; the relation data itself is reliable.** Every reference
occurrence checked that had *any* `.accessorOf` relation had either exactly one, or two *byte-identical
duplicates* (same `role`, same `occurrenceRoles`, same `targetUSR`) — never two genuinely different
candidates. `.first`'s nondeterminism is real in principle but harmless in every case observed here.
And critically, `targetUSR` was **correct in every single case tested** — `UILabel(im)setText:` →
`UILabel(py)text`, `UIView(im)isHidden`/`UIView(im)setHidden:` → **both** correctly → `UIView(py)hidden`
(confirming getter and setter both link to the same real property), `UIViewController(im)view` →
`UIViewController(py)view`, `UITableViewCell(im)contentView` → `UITableViewCell(py)contentView`,
`UIView(im)layer` → `UIView(py)layer`, `UIView(im)leadingAnchor`/`trailingAnchor` → their own real
property USRs. `occurrenceRoles` never carried the `.definition` bit in any of these (`0x8341`/`0x8241`
— bit `0x2` clear) — confirming these are genuinely reference-only, exactly the case
`owningPropertyUSR`'s current restriction excludes. **This directly answers hypotheses (a)/(b)/(c) from
section 3: the data is reliable, resolving hypothesis (b)/(c) in favor of "safe to trust." Hypothesis
(a) (the original `NSCell.setTitle:` regression having genuinely wrong data) remains unconfirmed either
way — not reproduced directly, but no longer the most likely explanation given how uniformly correct
every other case here was.**

**Finding 2 — a second, independent, larger blocker: some real call-graph edges use a
Clang-module-qualified USR form the index's own relation storage never uses.** `UIView.leadingAnchor`
in a real edge's own `calleeUSR` is `c:@CM@UIKit@@objc(cs)UIView(im)leadingAnchor` (note the `@CM@
UIKit@@` prefix) — querying `relationsBySymbolUSR` with *that exact string* found **zero**
`.accessorOf` relations (out of 2366 total relations touching it). The **same real declaration**,
queried as the plain `c:objc(cs)UIView(im)leadingAnchor` (no prefix), found the correct relation
immediately. Same story for `trailingAnchor` and `setHidden:`. `UILabel(im)setText:`/`.view`/
`.contentView`/`.layer` never carried this prefix in their real edge form to begin with, which is
exactly why they resolved cleanly even before this was found — this second issue is specific to
*some* symbols, not universal, and it's plausibly the *larger* blocker for this corpus specifically:
`leadingAnchor`/`trailingAnchor`/`setHidden:`'s real edges are the single highest-frequency unresolved
USRs measured against this corpus (section 1). The property USR that `owningPropertyUSR` would
eventually return is *itself* always in the plain, unprefixed form (confirmed: `c:objc(cs)UIView(py)
leadingAnchor`, no `@CM@` prefix) — matching what `BulkSymbolGraphExtractor`'s own bulk cache is keyed
by, confirmed separately in section 2. So the prefix mismatch only needs handling on the *input* side
of the lookup, not the output.

**Why some edges carry the `@CM@<Module>@@` qualifier and others don't** was not root-caused this
session from source — but see the amendments below for further empirical narrowing (not a full
root-cause; a real Clang-source citation is still the right bar before trusting this universally).

## 5a. Reviewer amendments (2026-08-13) — incorporated, partially verified empirically

A reviewer's addendum (`/Users/ab/Downloads/task-external-property-accessor-usr-mismatch-amendments.md`
at the time it was written) proposed four changes to the fix design in section 6. Each was checked
against the real corpus before being accepted, per the reviewer's own "of course this all needs
checking in practice" framing — not accepted on the strength of the argument alone.

- **Amendment 1 (fail-to-`nil` on disagreement, not `.first`-then-log)** — accepted as-is, no
  empirical check needed beyond Finding 1 above: on every real case observed, "require unanimous
  agreement among candidates" and "`.first`" produce identical results (every multi-candidate case was
  byte-identical duplicates), so the stronger version costs nothing on real data and is strictly safer
  for the undreserved-disagreement case. See the proposed `owningPropertyUSR` replacement in that
  addendum — adopted as the design for section 6, part 1, below.
- **Amendment 2 (root-cause `@CM@<Module>@@` before stripping; specifically, test the same external
  symbol referenced from different importing modules)** — **partially verified empirically.** Checked
  directly against this corpus's real edges: `UIView.leadingAnchor` is referenced from four different
  real importing contexts (the main app target, and three separate CocoaPods — `Mindbox`,
  `MindboxNotifications`, `OverlayContainer`) — **all 1181 real edges carry the identical
  `c:@CM@UIKit@@objc(cs)UIView(im)leadingAnchor` qualified form**, no variation by importing module.
  Separately, scanned every callee USR in this corpus's full edge set for any "bare" declaration
  (qualifier stripped) that appears in *both* a `@CM@`-qualified and unqualified form simultaneously —
  **zero such collisions found** across the whole real corpus. This is real evidence *against* the
  specific risk the amendment raised (cross-module qualifier disagreement), on this one corpus — it is
  not the Clang-source citation the amendment still correctly asks for as the real bar before trusting
  this as a general rule, and a single corpus is not proof of a language-level guarantee.
- **Amendment 3 (check whether `.baseOf`/`.extendedBy` share the same qualifier gap)** — **checked
  directly, real data suggests they don't.** Queried `containingExtensionUSR`/`extendedTypeUSR`
  against a real project extension of `UIViewController`
  (`Extensions/UIViewController+Navigation.swift`'s `addCustomBackButton`): `extendedTypeUSR` returned
  the plain `c:objc(cs)UIViewController`, **no `@CM@` qualifier at all.** Queried `baseTypeUSRs`
  against a real project-local subclass (`BaseLuxuryViewController`): every base type/protocol
  returned (`BaseViewController`, `DZNEmptyDataSetSource`, `DZNEmptyDataSetDelegate`) was likewise
  unqualified. This suggests the `@CM@` gap is specific to how *call-graph edges* get their USRs (the
  `.call`-role occurrence scan behind `callGraphEdges`/`callSites`), not a property of external USRs
  in general — `.baseOf`/`.extendedBy` read through a different occurrence path and don't appear to
  carry it. Checked on one real case each, not exhaustively; treat as a real, corpus-grounded signal
  that narrows Amendment 3's worry, not a closed question.
- **Amendment 4 (log actual competing USRs, not a boolean)** — accepted, folded into the part 1 design
  below.

## 6. What the real fix needs — two parts, not one

1. **Replace `owningPropertyUSR` to require unanimous agreement among `.accessorOf` candidates,
   returning `nil` on disagreement — never `.first`-and-hope** (Amendment 1, adopted verbatim from the
   addendum):

   ```swift
   public func owningPropertyUSR(forUSR usr: String) -> String? {
       let relations = relationsBySymbolUSR[usr]?.filter {
           $0.role & INDEXSTORE_SYMBOL_ROLE_REL_ACCESSOROF != 0
       } ?? []
       let definitionRelations = relations.filter {
           $0.occurrenceRoles & INDEXSTORE_SYMBOL_ROLE_DEFINITION != 0
       }
       // Prefer a definition-role relation when one exists (today's project-local behavior,
       // unchanged); fall back to reference-role relations only for genuinely external USRs.
       let candidates = definitionRelations.isEmpty ? relations : definitionRelations
       let targets = Set(candidates.map(\.targetUSR))
       guard targets.count == 1 else {
           if targets.count > 1 {
               // log the actual competing USRs verbatim (Amendment 4), not just "disagreement found"
           }
           return nil
       }
       return targets.first
   }
   ```

   DoD: a synthetic fixture with deliberately disagreeing `.accessorOf` relations asserts `nil`, not a
   guess — doesn't need to occur in a real corpus to be worth testing (this spike never observed real
   disagreement, which is exactly why a synthetic case is the only way to exercise this path at all).
2. **Strip a leading `c:@CM@<Module>@@` qualifier before the `relationsBySymbolUSR` lookup**, scoped to
   the call-graph-edge path specifically (per the Amendment 3 check above, `.baseOf`/`.extendedBy`
   don't appear to need it) — still worth a real Clang-source citation before trusting this as a
   blanket rule (Amendment 2), even though the corpus-level cross-module check found no
   counter-example.

Both parts, together, in `DeclarationLinker.canonicalized(_:)` (`Sources/IndexStoreIntegration/
DeclarationLinker.swift:356-364`) or wherever `owningPropertyUSR` ends up being called from — verify
the fix rewrites `callerUSR` and `calleeUSR` **symmetrically**, matching how `canonicalized(_:)`
already applies to both sides of every edge for Gap A. Re-run `CompiledDependencyCLITests`'s
`NSCell.setTitle:` assertion (`Tests/swift-isolation-mapTests/CompiledDependencyCLITests.swift:259`)
with fresh eyes afterward — it may need to change from `isUnknown: true` to a real resolved
expectation, which would be the fix working, not a regression, provided the reasoning is written into
the test's own updated comment.

## 7. Remaining steps

1. Implement the two-part fix above.
2. **Measure real impact the same way Gap A did**: `docs/task-raw-indexstore-spike.md`'s temporary
   diagnostic technique (log a bulk/live hit-or-miss right where each trigger loop in
   `ExternalIsolationBackfill.swift` checks it, short-circuit to `unknown` under an env-var guard so a
   full pass completes in seconds instead of tens of minutes) is the fast, cheap way to verify without
   a full real-corpus run every iteration. A full real run (this session used `.build/release/
   swift-isolation-map <workspace> --scheme <scheme> --severity high --output json --out-file
   result.json --verbose`, no `--force-reindex` if the index store is already fresh) is still worth
   doing once at the end for a real before/after `medium`/`unknown` edge count, the same way this
   session did (see `/tmp/lsboutique_diag_run.json` vs `/tmp/lsboutique_fix_run.json`-style comparison
   — those specific temp files won't survive between sessions, regenerate).
3. **Revert the temporary spike instrumentation** — `RawIndexStoreClient.debugAllRelations(forUSR:)`
   and `Tests/IndexStoreIntegrationTests/TEMP_AccessorSpike.swift` — before merging the real fix, or
   earlier if this task is paused. Neither is meant to ship.

## 8. Explicitly out of scope for this task

- The already-closed Gap A (Swift-mangled `vg`/`vs`/`vM` accessor case) — don't touch, don't re-verify
  unless a change here risks breaking it (it shares `owningPropertyUSR`, so regression-test it).
- Changing `IsolationInferenceEngine` or the risk heuristic — unrelated, stays untouched.
- The bulk-cache SE-0316 inheritance fix (PR #80) — already shipped, separate concern, real but small
  impact on this specific corpus (one edge, `UIWindow.init`) precisely because this accessor-mismatch
  issue dominates the same corpus's residual `unknown` count.
