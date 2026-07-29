# Research response: external-type extension isolation — a relation-chain variant, and a sibling bug of the worse class

**Status: remote analysis of `task-external-type-extension-isolation.md`, with pre-registered
verification points per thread discipline. Eleventh document of the compiled-dependency-isolation
thread.** The task's end-to-end mechanism trace is complete and convincing, and its scope claim —
this shape can only ever *over*-report risk, never mask it — is verified logic worth keeping in
the record verbatim. Three contributions follow: an internal tension in hypothesis 1 that its own
Definition of done exposes, a cheaper variant that dissolves the tension using the query family
Gap B already landed, and an adjacent bug of the *opposite and worse* failure class that the same
session should check while it has the relevant code open.

## 1. Hypothesis 1 contradicts the task's own DoD 2 — and the tension points at a better shape

Hypothesis 1 queries a `.reference`-role occurrence "at the exact `(file, line, column)` of an
extension's own `node.extendedType` token." But the task's own mechanism trace establishes that
this location is recorded **nowhere**: the placeholder `DeclarationInfo` for
`"syntactic:UIViewController"` has `location == nil`, and nothing else captures the
extended-type token position. So hypothesis 1 as stated requires `DeclarationExtractor` to start
recording that location — a `SyntaxAnalysis` change — while DoD 2 explicitly requires the fix to
work "without needing `SyntaxAnalysis` to change at all." The hypothesis and the DoD cannot both
hold as written.

**Variant 1a (recommended): derive the extended type's real USR from the *member's* already-real
USR via index relations — no locations, no syntax changes.** The task's own captured finding
shows the crucial fact: extension *members* link fine
(`callerUSR: s:So16UIViewControllerC9Ls_net_ruE12setCartCount…` is a real, compiler-assigned
USR). From any one such member:

1. `occurrences(ofUSR: memberUSR, roles: .definition)` → read the definition occurrence's
   `relations` for the containment entry (`.childOf`) → the containing **extension symbol's**
   USR.
2. `occurrences(relatedToUSR: extensionUSR, roles: .extendedBy)` → the returned occurrence's
   `symbol.usr` is the **extended type's real USR** — for `UIViewController`, its clang USR.

Both hops use the exact query family this project already landed and direction-verified for
Gap A (`.accessorOf`) and Gap B (`.baseOf`/`.extendedBy` — the task doc itself notes
`baseTypeUSRs(forUSR:)` already touches `.extendedBy`, so half of this chain has an in-repo
precedent). Zero `SyntaxAnalysis` changes, satisfying DoD 2 as written; and because the chain
starts from a member's real USR rather than from a name or a location, it resolves the task's
second scope note (project-local type whose primary declaration isn't in the analyzed file set)
by the identical mechanism, closing the `DeclarationLinker` header comment's documented
limitation as the side effect the task hoped for.

**Pre-registered verification points for the fixture (per the task's own verify-first mandate):**
- V1: an extension member's definition occurrence carries `.childOf` to the **extension symbol**
  (not directly to the nominal) — if it points at the nominal directly, the chain shortens to one
  hop; either outcome is fine, the fixture decides.
- V2: `.extendedBy` direction — `occurrences(relatedToUSR: extensionUSR, roles: .extendedBy)`
  returns the *type's* occurrence; invert if the store says otherwise (Gap B's own wording:
  same cost either way).
- V3: for an extension of an ObjC-imported type, the returned USR is the **clang USR**
  (`c:objc(cs)UIViewController`) — which is exactly how `BulkSymbolGraphExtractor`'s UIKit
  entries are keyed (`identifier.precise` for ObjC symbols is the clang USR). This is a happy
  consequence of asking the index instead of deriving from strings: mangling-parsing the member
  USR (a tempting shortcut, since `So16UIViewControllerC` sits right there in it) would produce
  the *Swift-mangled* spelling and silently miss the bulk cache — the task's hypothesis 3
  warning about name-vs-USR shape mismatches, in a subtler costume. Do not take the mangling
  shortcut.
- V4: nested extended types (`extension Foo.Bar`) and extensions of generic types resolve
  through the same chain — shapes where any name- or location-based scheme frays, and relations
  don't.

## 2. Resolution must be per-extension, not per-bare-name

The placeholder `"syntactic:UIViewController"` is a single shared dictionary entry that every
extension of anything *named* `UIViewController` points at. Variant 1a produces a per-member
(hence per-extension) answer. Rewrite `containingTypeUSR` per member from its own chain's
answer; update the shared placeholder entry only when every resolving chain agrees, and on
divergence (two same-named types from different modules both extended in-project — rare, but the
bare-name scheme cannot exclude it) split rather than share, with the same never-guess floor as
`disambiguate`. Resolving once per bare name and fanning out would bake the collision in
silently.

## 3. The sibling bug to check in the same session: extension-level isolation attributes — the mirror image, and the worse failure class

This task's bug makes extension members *less* isolated than reality — false positives only, as
the scope note proves. But the same `ExtensionDeclSyntax` handling has a mirror-image neighbor:
**an extension can carry its own isolation annotations** — `@MainActor extension SomeType { … }`
and `nonisolated extension SomeType { … }` are both legal, common Swift. If
`DeclarationExtractor`'s extension handling reads only member-level attributes and never
`ExtensionDeclSyntax.attributes`/modifiers, then a member of `@MainActor extension
SomeNonisolatedType` is classified `.nonisolated` — and a call from genuinely nonisolated code
into it is reported as safe when it is not. That is a **false negative**: the one failure class
this tool's whole value proposition cannot tolerate, strictly worse than the false positive this
task documents. Check while the extension-handling code is open: does extension-level
`@MainActor`/`nonisolated` propagate to members' extracted isolation today? If yes, one
regression fixture documents it; if no, it is a small extraction-side fix (the attribute is
right there on the node) plus a fixture of both polarities — and it belongs in this session's
scope precisely because it touches the same few lines, even though the task as filed doesn't
name it.

## 4. A cheap pre-measure for DoD 4, before any code

DoD 4 asks how many of the current 129 `highRiskBoundaries` are this false-positive shape — that
number is estimable *now*, from the already-produced JSON, with a grep-level pass: count findings
whose `callerUSR` is an extension-member mangling over an external type (the `s:So…C<module>E…`
shape of the captured example, plus the non-ObjC `s:<len><Module>…E…` extension marker for
Swift-native external types) and whose `callerIsolation` is `nonisolated`. Pre-registering that
count before the fix turns DoD 4's after-measurement into a genuine prediction check rather than
a post-hoc explanation — the thread's standing discipline, applied to its own acceptance
criterion.

## 5. Suggested order

0. The grep pre-measure (§4) against the existing 129-finding JSON — five minutes, zero code.
1. The verification fixture: one small package extending a real SDK `@MainActor` type (the
   task's own DoD 1 vehicle), asserting V1–V4, plus the §3 attribute-propagation check in both
   polarities.
2. Implement variant 1a in the linking/backfill layer: chain → real type USR → existing
   bulk-first oracle path unchanged (`UIViewController` = free UIKit bulk hit) →
   `containingTypeUSR` rewritten per §2 → `resolveInheritedIsolation` picks it up with, as the
   task correctly insists, zero engine changes.
3. The task's DoD 3–7 exactly as written, with §4's pre-measure as the before-side of DoD 4.

Everything stays inside the established invariants: engine untouched, risk heuristic untouched,
one narrow verified-first index query pattern extended by one more link in an already-trusted
chain, and every isolation fact still originating from the compiler through the same bulk/live
oracle the previous ten documents built and hardened.
