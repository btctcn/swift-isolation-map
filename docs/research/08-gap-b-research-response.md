# Research response: Gap B — one index primitive subsumes both halves, and the corpus itself names new suspects

**Status: remote analysis of `task-gap-b-declaration-linker-real-scale.md`, source-verified
where checkable from here (`swiftlang/indexstore-db` `main`, read 2026-07-26), with
pre-registered predictions per thread discipline. Ninth document of the
compiled-dependency-isolation thread.** The single-case end-to-end trace the task doc mandates
remains step one — nothing below replaces knowing the true H-local root cause. What this
document adds: a verified index-store primitive that changes the *fix shape* for both H-external
and H-local at once, one root-cause suspect cheaper than the doc's entire ranked list (visible in
the doc's own captured corpus), and three corpus observations with direct consequences for the
28134 number itself.

## 1. Verified: `occurrences(relatedToUSR:roles:)` exists — one query per declaration resolves its whole inheritance clause from the index

`Sources/IndexStoreDB/IndexStoreDB.swift` (`main`):

```swift
public func occurrences(relatedToUSR usr: String, roles: SymbolRole) -> [SymbolOccurrence]
```

backed by `forEachRelatedSymbolOccurrence(byUSR:roles:)`. Combined with the already-verified
relation roles (`.baseOf` — "A is base of B" — this thread's eighth document), the recipe is:
for a project declaration whose *own* USR is already real (and the captured corpus shows exactly
that — the left column of the samples is overwhelmingly real USRs), one call
`occurrences(relatedToUSR: declUSR, roles: .baseOf)` returns the occurrences of **every
supertype and conformed protocol referenced in that declaration's inheritance clauses**, each
carrying its real, compiler-assigned USR — `c:objc(cs)UICollectionViewCell` and the project's own
`NotificationsListViewInput` alike. This is not an exotic use: it is the exact primitive
sourcekit-lsp's type-hierarchy supertypes request is built on.

Consequences for the task's Definition of done:

- **H-external (DoD #1) is satisfied without touching `SyntaxAnalysis` at all.** The doc's
  option 2 assumed capturing clause locations in `DeclarationExtractor`; the relation query makes
  that unnecessary — the index already knows which symbols a type's clauses reference, no
  location arithmetic, no name matching, no "known-SDK-name pre-check" that would skirt the
  no-name-tables principle. Resolved external USRs then route through the existing bulk-first
  oracle machinery exactly as the out-of-scope section demands.
- **H-local's *symptom* is fixed by the same pass** even before its root cause is repaired:
  the project-local protocol's real USR comes back from the same query, decoupled from whatever
  placeholder-string or location mechanics failed in `buildUSRRewriteMap`.
- Integration shape: after the existing linking pass, for each declaration whose
  needs still contain a `syntactic:` placeholder, run the relation query once against the
  declaration's real USR and rewrite the surviving needs from its results (match by name where a
  clause has several entries; a returned symbol that matches no surviving need is simply
  ignored). `DeclarationLinker`'s location machinery stays for what it already does well —
  declarations' own USRs — and stops being load-bearing for inheritance needs.

**Pre-registered predictions to verify on the real store:** P1 — conformances declared on
*extensions* (the corpus's dominant shape; see §3a) also surface via `.baseOf` related to the
*nominal* type's USR (if the relation instead targets the extension symbol, add one hop:
extensions of the type → their `.baseOf` occurrences; either way the data is in the index).
P2 — a `Codable`-style typealias conformance returns either the typealias USR or the underlying
protocols'; both are acceptable downstream (all nonisolated), just record which.

## 2. A root-cause suspect cheaper than the doc's whole ranked list — and it's visible in the doc's own samples

The task doc's H-local reasoning *presumes* the protocol's own declaration entry carries
`.usr == "syntactic:NotificationsListViewInput"` — byte-identical to the reference placeholder in
`needs=`. But the doc's own captured corpus shows `DeclarationExtractor`'s placeholder scheme is
richer than bare names: `syntactic:ImageCompressionServiceImpl.compressionStep#626`,
`syntactic:OrdersListViewController.needsLoad#8261` — qualified paths plus `#offset` suffixes.
`usrRewriteMap` is keyed by `declaration.usr`; `rewritten(_:)` looks up the *reference-side*
bare-name placeholder. **If a top-level protocol's declaration placeholder ever carries
qualification or a suffix under any real-scale condition** — nesting (including SE-0404 nested
protocols inside namespace enums, a common VIPER shape), declaration inside an extension, or any
collision-dedup logic that appends `#offset` when two same-named declarations exist anywhere in
the corpus — **then map key ≠ lookup key as plain strings, linking fails deterministically for
exactly those protocols, and no location or disambiguation logic is ever even reached.** Small
fixtures with unique, top-level, unnested names would never show it.

This check costs a grep: for the traced `NotificationsListViewInput`, print the protocol
declaration's own `.usr` next to the failing `needs=` string and compare bytes. Do it *before*
the path-form diff the task doc ranks first — it is strictly cheaper and, unlike every suspect in
the doc's list, it has corroborating evidence already sitting in the doc's own examples. If it
hits, note the blast radius before patching: other consumers of placeholder USRs may be relying
on the same identity assumption.

## 3. Three corpus observations with consequences

**a. The `needs=` lists ride on *member* declarations — which means the 28134 is inflated by
per-member duplication.** `NotificationsListViewController(im)tableView:cellForRowAtIndexPath:
needs=syntactic:UITableViewDataSource,…` — a *method* doesn't conform to protocols; these needs
originate from an extension's inheritance clause and are recorded on (or propagated to) each
member. That means the same unresolved clause is being counted — and, today, live-queried — once
per member of the extension. **Pre-registered P3: the number of *distinct* (nominal type,
unresolved need) pairs is far below 28134** — plausibly by an order of magnitude on a VIPER-style
codebase. Deduplicating by that pair before any resolution (index query or oracle) is a
one-line-shaped change with a large multiplier, and it belongs in the fix regardless of
everything else. It also sharpens DoD #3's metric: report distinct pairs, not raw trigger counts.

**b. The corpus's left column contains `s:10Kingfisher…` and `s:9Alamofire…` declaration USRs —
`SyntaxAnalysis` is extracting CocoaPods *source* checkouts as project files.** That is a real,
so-far-implicit scope decision: it inflates the declaration count (toward the 46010) and
generates needs (`Publisher`, `CustomNSError`) whose resolution benefits the analysis of *the
dependency's* internals, not the app's. This is the user's call, not the researcher's — but it
should become a deliberate, documented decision (analyze Pods sources: yes/no/flag), with the
diagnostic re-run once with Pods excluded to put a real number on what share of the residue they
contribute. Note the interaction: if Pods sources stay in scope, the §1 relation query handles
their needs identically — the index covers them since they build in the same workspace.

**c. `needs=syntactic:@unchecked Sendable` — a malformed placeholder carrying an attribute.**
The extractor is embedding the `@unchecked` modifier into the placeholder name; that string can
never match anything in any resolution scheme. Strip attribute/modifier prefixes when forming
clause placeholders (`Sendable` is a marker protocol and irrelevant to isolation inference, but
the placeholder should be well-formed so it can be *recognized* and skipped cheaply rather than
live-queried). A two-line fix visible only because the corpus was captured verbatim — worth
landing with the rest.

## 4. Suggested execution order (trace first, per the project's own discipline)

0. Re-add the env-gated diagnostic (the task doc preserves its shape) — the before/after
   instrument throughout.
1. Trace `NotificationsListViewInput` end-to-end, **starting with §2's placeholder-identity
   byte-compare**, then the doc's path-form diff, then the candidates/disambiguate logging.
   Whatever it reveals, fix the linker's own bug — knowing the true cause matters beyond this
   task even though §3 changes what is load-bearing.
2. Land the §1 relation-query pass for surviving `syntactic:` needs (both H's), with P1/P2
   verified on the real store, plus §3a's dedup and §3c's placeholder hygiene.
3. Decide and document the §3b Pods-source scope question, with the diagnostic run both ways.
4. Measured DoD runs: distinct-pair residue near zero (DoD #3, sharpened per §3a), the full
   honest wall-clock number (DoD #4), 207/207 release tests, decision record with real
   before/after numbers.

Nothing here touches `IsolationInferenceEngine`, the risk heuristic, the report schema, or the
bulk machinery; the one new mechanism is an index-store relation query — the same source of
truth the linker already trusts, asked a question it can answer directly instead of one it can
only answer by coincidence of locations and strings.
