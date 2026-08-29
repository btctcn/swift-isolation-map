# Extern Objective-C constant / `NS_SWIFT_NAME`-bridged static member USR mismatch — research brief

Written for someone picking this up fresh, with no prior context on this specific investigation. If
you're new to this codebase, skim `docs/isolation-rules.md` and `docs/architecture.md` §1.5 first;
this file assumes you already know what `ExternalIsolationBackfill`, `BulkSymbolGraphExtractor`, and
`SourceKitDClient`/`USRMatching` each do. It also assumes familiarity with
`docs/task-external-property-accessor-usr-mismatch.md` (PR #82, merged) — this is a **sibling**
problem, same family (a Swift-side vs. Clang-side USR divergence for one real declaration), but a
different concrete shape, found afterward, on the same corpus, once PR #82's own fix was already
measured and confirmed working.

## 1. The problem, precisely

After PR #82/#83/#84 all shipped and measured, a fresh, real, line-by-line audit of the residual
`isUnknown` edges on Project Iris (a real ~2200-file Xcode workspace) found a second,
independent, large cluster: **1007 real edges** (out of ~5060 residual `isUnknown` edges post-#84)
whose `calleeUSR` is a `static var` on `NSAttributedString.Key`:

```
362  s:So21NSAttributedStringKeya5UIKitE4kernABvgZ            (.kern)
351  s:So21NSAttributedStringKeya5UIKitE14paragraphStyleABvgZ (.paragraphStyle)
124  s:So21NSAttributedStringKeya5UIKitE4fontABvgZ            (.font)
122  s:So21NSAttributedStringKeya5UIKitE15foregroundColorABvgZ(.foregroundColor)
  7  ...strikethroughStyle, .link, .baselineOffset, .strikethroughColor,
     .underlineStyle, .backgroundColor, .underlineColor, .strokeColor,
     .strokeWidth, .ligature, .shadow, several accessibility-speech keys, ...
```

Every one of these resolves to `calleeIsolation: "unspecified"` (not `"nonisolated"`, not any other
fallback value) — meaning `IsolationInferenceEngine.declarations[usr]` was **never populated at all**
for these USRs, on either the bulk-cache path or the live-query path. `.unspecified` is the "this USR
has zero entry in `declarations`" signal, distinct from a resolved-but-uncertain value — see
`IsolationInferenceEngine.resolveIsolation(for usr:)`'s own `guard let declaration = declarations[usr]
else { return .unspecified }`.

## 2. Confirmed root cause — real `sourcekitd` output, not a guess

`ExternalIsolationBackfill.query(...)` (`Sources/swift-isolation-map/ExternalIsolationBackfill.swift:912`)
is the one place a `.unspecified` outcome like this can come from for an edge-level trigger: the bulk
cache misses (confirmed separately — `NSAttributedString.Key`'s classic static members are **absent
entirely** from a real `swift symbolgraph-extract -module-name UIKit -minimum-access-level public`
dump on this machine, including the `UIKit@Foundation.symbols.json` sibling file where a
cross-module extension member would normally show up; only the modern `AttributeScopes`/
`AttributedString` API surface is present), so the live `cursorinfo` fallback runs — and it returns
the wrong USR.

Direct, real debug instrumentation (temporarily added to `query()`, reverted after — see §6 for the
exact method if you need to reproduce) against the real, chosen representative call site for
`s:So21NSAttributedStringKeya5UIKitE4fontABvgZ` (`.font`, canonical-lowest-location selection per
`collectEdgeLevelWorkItems`'s own rule — landed in
`Pods/SkyFloatingLabelTextField/Sources/SkyFloatingLabelTextField.swift:117:91`) produced:

```
primary.usr = c:@NSFontAttributeName
secondary.usrs = []
```

The **expected** `targetUSR` (what the real compiler's own `IndexStoreDB`-derived call graph recorded
for the exact same call site, i.e. the value `ExternalIsolationBackfill` is trying to match) is
`s:So21NSAttributedStringKeya5UIKitE4fontABvgZ`. `USRMatching.select(from:targetUSR:)`
(`Sources/SourceKitDIntegration/USRMatching.swift:26-28`) requires exact string equality between
`targetUSR` and some candidate's `.usr` (`result.all = [primary] + secondary`, strict-equality-or-
`::SYNTHESIZED::`-prefix only, by design — no substring/fuzzy matching, see that file's own doc
comment). `c:@NSFontAttributeName` ≠ `s:So21NSAttributedStringKeya5UIKitE4fontABvgZ`, no match in
`secondary` either (empty) → `select` returns `nil` → `query()` returns `.unknown` → per
`applyEdgeLevelOutcomes` (`ExternalIsolationBackfill.swift:333-349`), nothing gets added to
`backfilled` for this USR → `declarations[usr]` stays absent even after merge → every edge referencing
it resolves to `calleeIsolation: "unspecified"` downstream, and the edge is flagged `isUnknown`.

### Why two different USRs exist for one real declaration

`.font`/`.kern`/`.foregroundColor`/`.paragraphStyle`/etc. on `NSAttributedString.Key` are not
hand-written Swift declarations. They're the Swift projection of classic Objective-C `extern NSString
* const` global constants (`NSFontAttributeName`, `NSKernAttributeName`,
`NSForegroundColorAttributeName`, `NSParagraphStyleAttributeName`, ...), declared in `NSAttributedString.h`
and re-surfaced as "static member of the RawRepresentable wrapper type" via `NS_SWIFT_NAME` (the same
Apple-SDK convention that turns `UIViewNoIntrinsicMetric`-style bare constants into
`UIView.noIntrinsicMetric`, or an ObjC "Notification.Name" constant family into `Notification.Name.foo`).

This produces the same seam PR #82 found for property accessors, but in a different shape:
- **The real Swift compiler**, doing full ClangImporter interop resolution while building the actual
  project, records a genuine Swift-mangled USR for the *bridged* static-member view
  (`s:So21NSAttributedStringKeya5UIKitE4fontABvgZ`) in `IndexStoreDB`'s own call-graph data — this is
  what `linked.callGraph`'s `calleeUSR` carries, and therefore what every downstream lookup in this
  tool is keyed by.
- **`sourcekitd`'s `cursorinfo`**, hovering the *same* real call site, resolves through the underlying
  Clang AST node directly and returns the **plain, unbridged Clang extern-constant USR**
  (`c:@NSFontAttributeName`) — no Swift-side mangling, no `NS_SWIFT_NAME` renaming reflected at all.

Neither tool is "wrong" in isolation — they're both accurately describing the same real declaration
from two different levels of the same interop machinery. The mismatch is a real seam between them,
exactly like PR #82's property-accessor case, but the *specific* divergence (bridged static-member
Swift name vs. raw Clang extern-constant name) is a different mechanism than PR #82's
(`.accessorOf`-relation getter/setter-vs-property split), so PR #82's fix (`owningPropertyUSR`) does
**not** cover this — confirmed directly: this cluster is entirely on `ExternalIsolationBackfill`'s
edge-level live-query path (`query()`), never touches `RawIndexStoreClient.owningPropertyUSR` at all.

## 3. Scope — confirmed vs. not yet confirmed

**Confirmed, with real `sourcekitd` output (§2):** the `NSAttributedString.Key` static-member family
specifically — 1007 real edges on this one corpus, ~20% of the entire residual `isUnknown` bucket
after PR #84.

**Not yet confirmed — a real, observed, but unverified lead, do not treat as the same root cause
without checking:** several *other* USR families in the same report show the identical downstream
symptom (`calleeIsolation: "unspecified"`, same failure signature) on real edges in this corpus:

```
272  UIControlState.normal (and other cases)         s:So14UIControlStateV6normalABvgZ
170  UIControlEvents.touchUpInside (and other cases)  s:So15UIControlEventsV13touchUpInsideABvgZ
 48  UILayoutPriority.required (and other cases)      s:So16UILayoutPrioritya8requiredABvgZ
 41  UIResponder.keyboardWillShowNotification (etc.)  s:So11UIResponderC28keyboardWillShowNotificationSo18NSNotificationNameavgZ
 29  UIViewAutoresizing.flexibleWidth (and others)     s:So18UIViewAutoresizingV13flexibleWidthABvgZ
 25  CACornerMask.layerMinXMinYCorner (and others)     s:So12CACornerMaskV19layerMinXMinYCornerABvgZ
 12  UIBackgroundTaskIdentifier.invalid                s:So26UIBackgroundTaskIdentifiera7invalidABvgZ
  8  CALayerCornerCurve.continuous                     s:So18CALayerCornerCurvea10continuousABvgZ
```

**Do not assume these share §2's exact mechanism without re-running the same real-`sourcekitd`-output
check for each.** `UIControlState`/`CACornerMask` in particular are modern Swift `OptionSet`/enum
declarations in UIKit's own Swift overlay, not `NS_SWIFT_NAME`-bridged ObjC extern constants like
`NSAttributedString.Key` — the *symptom* is identical (same `.unspecified`, same "absent from
`declarations` entirely" shape), but the underlying cause could plausibly be the exact same
Swift-side/Clang-side USR divergence, or could be something else entirely (a different bulk-cache gap,
a different live-query failure mode) that merely produces the same downstream symptom. This project's
own discipline (see `docs/task-external-property-accessor-usr-mismatch.md`'s own history of getting
this exact kind of generalization wrong on the first pass) is: verify each family's own real
`sourcekitd` response before generalizing a fix to it. Combined, these unconfirmed families are
another ~605 edges (~12% of the residual bucket) — a real incentive to check, not a reason to assume.

## 4. What this is *not*

- Not the duplicate-orphaned-file bug (`" 2.swift"`-style stale files colliding with real project
  declarations, causing whole-USR `unknown` propagation via `containingTypeUSR`) — that's a separate,
  already-diagnosed-and-partially-fixed-by-deletion issue, unrelated to this one (confirmed: none of
  the `NSAttributedString.Key` edges' callers are declarations affected by that bug).
- Not covered by PR #82's `owningPropertyUSR` fix (different mechanism, different code path — §2).
- Not a bulk-cache coverage gap in the sense PR #84 fixed (class-bound-protocol conformance
  incorrectly propagating a class's global actor) — this is a live-query USR-matching failure, not an
  isolation-inference-rule failure.

## 5. Possible fix directions — not evaluated, this task is research/scoping only

Sketched, **not designed or vetted** — whoever picks this up should treat these as starting hypotheses,
not a decided plan, per this project's own 7-step workflow (hypothesis → spike → doc → code → tests →
results → PR):

1. **Teach `USRMatching`/`query()` to also try a raw-Clang-USR candidate** when the Swift-mangled
   target isn't found — e.g., if `targetUSR` has the `s:So<N><Name>a...` "ObjC-bridged static member"
   shape, derive/accept the corresponding `c:@<CONSTANT_NAME>` form as an alternate match. Risk: same
   category of risk PR #82's rejected "string-transform `setXxx:` → `xxx`" direction had — a naive
   name transform can be confidently wrong; needs a *reliable*, verifiable derivation (e.g. checking
   `sourcekitd`'s own bridging tables, not guessing at Apple's constant-naming convention).
2. **Extend `BulkSymbolGraphExtractor` to cover this family at the bulk-cache layer** — investigate why
   `symbolgraph-extract` omits these from its UIKit dump at all (an access-level artifact? a
   genuinely-different underlying module these constants are declared in, invisible to a plain
   `-module-name UIKit` extract?) before assuming this is fixable this way.
3. **A general "if the live query returns a Clang USR whose declaration is a plain `extern` constant,
   look up its Swift-bridged name via a targeted secondary query"** — more complex, likely only worth
   it if direction 1's derivation turns out unreliable.

Whichever direction is chosen, verify end to end against this real corpus the same way PR #82/#84 were
verified (before/after edge counts, `swift test`, no regression on the golden fixtures) before
proposing a PR.

## 6. Reproducing the real `sourcekitd` evidence in §2

The debug instrumentation used to get the real output in §2 was temporary and has been reverted (not
shipped). To reproduce:

1. **Must run with `--oracle-workers 1` (or omit the flag).** Proven, not assumed (see
   `project_oracle_worker_stderr_discarded` if you have access to this project's own memory notes, or
   just read `Sources/swift-isolation-map/OracleWorker.swift`/`Sources/ProjectResolution/
   ProcessRunning.swift` directly): with `--oracle-workers > 1`, live queries run inside a real child
   process (`OracleWorker.run`, spawned via `LiveProcessRunner`), whose `stderr` is captured into an
   in-memory `Pipe` and then never read/forwarded by `OracleWorker.runWorker` — any `eprint`/debug
   output inside a worker is silently discarded, not "probably lost," provably discarded by the code as
   written.
2. Add a temporary debug print inside `ExternalIsolationBackfill.query(...)`
   (`Sources/swift-isolation-map/ExternalIsolationBackfill.swift:912`), gated by an env var, right
   after the `sourceKitD.cursorInfo(...)` call succeeds:
   ```swift
   if ProcessInfo.processInfo.environment["SIM_DEBUG_UNKNOWN_USR"] == targetUSR {
       eprint("DEBUG query \(targetUSR) at \(file):\(line):\(utf8Column) primary.usr=\(result.primary.usr) secondary.usrs=\(result.secondary.map { $0.usr })")
   }
   ```
3. Build release, run with `SIM_DEBUG_UNKNOWN_USR='s:So21NSAttributedStringKeya5UIKitE4fontABvgZ'`
   (or any other USR from §1/§3's lists) set, `--oracle-workers 1 --severity high`, against a real
   checkout of the corpus. Revert the debug print before committing anything else.

## 7. Reviewer notes (external review, added 2026-08-14 — analysis only, not run against a real corpus)

These notes are a reviewer pass over §§1–6, in the same spirit as the amendments recorded for
PR #82's doc. Nothing below has been checked against real `sourcekitd` output or this corpus — treat
7.1 as the actual next action; 7.2–7.4 are downstream of what that check finds.

### 7.1 Before evaluating directions 1–3: dump the raw `cursorinfo` response, not just the typed fields — DONE (2026-08-14), hypothesis refuted

The §6 debug print only logs `result.primary.usr` and `result.secondary.map { $0.usr }` — fields
already parsed into `USRMatching`'s typed wrapper. Real `cursorinfo` responses from sourcekitd can
carry additional keys beyond primary/secondary symbol info that this typed wrapper may not currently
surface. For a synthesized static-member projection like this one, it's plausible — not confirmed —
that the correct swift-mangled USR is already present in an unparsed field of the same response,
silently dropped by the current parsing rather than genuinely absent from sourcekitd's output.

Recommended first step: re-run the §6 reproduction, but log the complete raw response dictionary for
the `cursorinfo` call (before it's mapped into `result.primary`/`result.secondary`), for at least
`s:So21NSAttributedStringKeya5UIKitE4fontABvgZ`. Two outcomes:
- If the swift-mangled USR (or something derivable from it without guessing) is present in an
  unparsed field → this becomes a parsing-coverage fix, not a new matching mechanism.
- If it's genuinely absent from the response → this rules out the cheapest fix and justifies moving
  to 7.3/7.4 below.

10–15 minutes to confirm or rule out, before designing anything new.

**Done — see §8 for the real dump and the answer: genuinely absent, not a parsing gap.**

### 7.2 Direction 2 (bulk-cache) — worth a parallel, low-priority check, not the primary bet

Cross-module extension members of externally-imported ObjC types (particularly `NS_SWIFT_NAME`-bridged
extern constants) are a known gap category for `swift symbolgraph-extract` more broadly, not specific
to this project's setup. Confirming whether a different flag or target module changes anything is
worth the cheap check the doc already proposes, but shouldn't be the default assumption for how this
gets closed — if it's an upstream toolchain limitation, direction 2 dead-ends regardless of effort
spent on it.

### 7.3 Direction 1 — ground the derivation in something the compiler asserts, not a name pattern

The doc's own risk callout for direction 1 (a naive string transform can be "confidently wrong," same
category as PR #82's rejected `setXxx:` → `xxx` transform) is correct, and worth extending: even a
"reliable" derivation is still guessing if it infers the `NS_SWIFT_NAME` target from the Clang
constant's spelling. The reliable source of truth is the generated interface (`.swiftinterface`, or
`source.request.editor.open.interface`) for the wrapper type itself (`NSAttributedString.Key`,
`UIControlState`, etc.) — built by the same compiler pass that produced the swift-mangled USR
`IndexStoreDB` recorded, so a name→USR map built from it reads the compiler's own resolved output
rather than inferring Apple's naming convention.

Concretely, this reframes direction 3 from "a secondary query per unmatched USR" into "one query per
wrapper type, cached": open the generated interface for `NSAttributedString.Key` once, enumerate its
static members via sourcekitd, and build a `Clang extern-constant name → swift-mangled USR` table from
that single response — reusable across all ~1007 edges in this family, and potentially across the
sibling families in §3 that share the same wrapper-type shape. This depends on the generated-interface
response actually linking each static member back to its underlying Clang symbol (not yet confirmed).
If it doesn't, direction 1's string-transform — gated behind the same conservative
accept-list-not-guess pattern used elsewhere in this project — is the fallback, not the default.

### 7.4 On §3's unconfirmed families — plausible shared root cause, still needs per-family verification

Structurally, most of the unconfirmed families look like they'd hit the same `NS_SWIFT_NAME`/extern-
constant bridging seam as §2, via a different ObjC macro:
- `UIControlState`, `UIControlEvents`, `UIViewAutoresizing`, `CACornerMask` — `NS_OPTIONS`-backed
  extern constants promoted to static members of an `OptionSet` wrapper; same shape as §2's
  `NS_SWIFT_NAME`-on-a-plain-constant case, one macro layer removed.
- `UIResponder.keyboardWillShowNotification` — an `extern NSNotificationName` constant, same
  `NS_SWIFT_NAME` mechanism as `NSAttributedString.Key`'s members directly.
- `UILayoutPriority.required`, `UIBackgroundTaskIdentifier.invalid`, `CALayerCornerCurve.continuous` —
  same general shape (single wrapped extern constant).

This is plausible, not confirmed. Given this project's own documented history of over-generalizing
incorrectly on the first pass (the property-accessor case referenced in the doc itself), the right
next step is still to run the §6 reproduction against one or two representative call sites per family
before assuming the eventual fix covers all eight automatically. It's cheap — same debug scaffold,
different `SIM_DEBUG_UNKNOWN_USR` value — and turns "another ~605 edges, a real incentive to check"
into either a confirmed extension of the same fix, or a flagged set of exceptions.

## 8. §7.1 verified (2026-08-14) — real raw `cursorinfo` dump, hypothesis refuted, one new lead

Reproduced via a temporary debug print in `SourceKitDClient.cursorInfo`
(`Sources/SourceKitDIntegration/SourceKitDClient.swift`, right after `let value =
raw.responseGetValue(response)`), calling the already-existing diagnostic
`RawSourceKitD.dumpVariant(_:)` (`Sources/SourceKitDIntegration/RawSourceKitD.swift:143-145` — a full,
literal recursive dump of a response variant, already built for exactly this kind of "not-yet-
understood response shape" investigation, not something added new for this task) on the full response
value, gated by `SIM_DEBUG_DUMP_CURSORINFO_FILE`/`SIM_DEBUG_DUMP_CURSORINFO_OFFSET` env vars matching
the file/offset. Reverted after use, not shipped — same temporary-instrumentation discipline as §6.

Run with `--oracle-workers 8` and the newly-shipped `SWIFT_ISOLATION_MAP_WORKER_STDERR=1` (PR #85,
merged) — this reproduction doubled as a live confirmation that PR #85's worker-stderr forwarding
actually works: the dump appeared prefixed `[worker 2 stderr] ...`, correctly attributed to the
specific worker subprocess that ran the query, in the root process's own log.

**The real, complete raw response** for `s:So21NSAttributedStringKeya5UIKitE4fontABvgZ`'s
representative call site (`SkyFloatingLabelTextField.swift:117:91`, byte offset 4018), every top-level
key:

```
key.column: 42
key.symbol_graph: {"symbols":[{"kind":{"identifier":"swift.type.property",...},
  "identifier":{"precise":"c:@NSFontAttributeName","interfaceLanguage":"swift"},
  "pathComponents":["NSAttributedString","Key","font"],
  "swiftExtension":{"extendedModule":"Foundation","typeKind":"swift.struct"},
  "declarationFragments":[...,{"kind":"typeIdentifier","spelling":"NSAttributedString",
    "preciseIdentifier":"c:objc(cs)NSAttributedString"},{"kind":"text","spelling":"."},
    {"kind":"typeIdentifier","spelling":"Key","preciseIdentifier":"c:@T@NSAttributedStringKey"}],
  ...}],
  "relationships":[{"kind":"memberOf","source":"c:@NSFontAttributeName",
    "target":"c:@T@NSAttributedStringKey","targetFallback":"Foundation.NSAttributedString.Key"}]}
key.fully_annotated_decl: <decl.var.static>static let <decl.name>font</decl.name>: NSAttributedString.Key</decl.var.static>
key.doc_comment: "********************** Attributes ***********************"
key.containertypeusr: "$sSo21NSAttributedStringKeyamD"
key.annotated_decl: <Declaration>static let font: NSAttributedString.Key</Declaration>
key.is_system: true
key.line: 25
key.modulename: "UIKit.NSAttributedString"
key.decl_lang: source.lang.objc
key.kind: source.lang.swift.ref.var.static
key.offset: 864
key.doc.full_as_xml: <Variable ...><Name>NSFontAttributeName</Name><USR>c:@NSFontAttributeName</USR>...</Variable>
key.usr: "c:@NSFontAttributeName"
key.typeusr: "$sSo21NSAttributedStringKeyaD"
key.typename: "NSAttributedString.Key"
key.filepath: ".../UIKit.framework/Headers/NSAttributedString.h"
key.name: "font"
key.referenced_symbols: [
  { key.usr: "c:objc(cs)NSAttributedString", key.modulename: "Foundation.NSAttributedString", ... },
  { key.usr: "c:@T@NSAttributedStringKey", key.modulename: "Foundation.NSAttributedString", ... }
]
key.parent_contexts: [
  { key.kind: "swift.class", key.usr: "c:objc(cs)NSAttributedString", key.name: "NSAttributedString" },
  { key.kind: "swift.struct", key.usr: "c:@T@NSAttributedStringKey", key.name: "Key" },
  { key.kind: "swift.type.property", key.usr: "c:@NSFontAttributeName", key.name: "font" }
]
key.length: 19
```

**§7.1's hypothesis is refuted, not confirmed.** Every single symbol-identifying field in this entire
response — `key.usr`, `key.typeusr`, the `identifier.precise` inside `key.symbol_graph`'s own JSON,
every `key.usr` inside `key.referenced_symbols` and `key.parent_contexts` — is a plain Clang USR
(`c:@NSFontAttributeName`, `c:@T@NSAttributedStringKey`, `c:objc(cs)NSAttributedString`). There is no
field anywhere carrying `s:So21NSAttributedStringKeya5UIKitE4fontABvgZ` or any other `s:`-prefixed
Swift-mangled identifier for the member itself. This is not a parsing gap in `SourceKitDClient`'s
typed wrapper (§7.1's optimistic branch) — `sourcekitd`'s own `cursorinfo` genuinely never resolves
this specific declaration to its Swift-bridged identity at all when queried this way. Direction "cheap
parsing-coverage fix" is closed.

**One new, real lead this dump surfaces, not previously known:** `key.containertypeusr:
"$sSo21NSAttributedStringKeyamD"` — `sourcekitd` *does* know the Swift-mangled identity of the
*container type* (`NSAttributedString.Key`) even though it has no Swift-mangled identity for the
*member* (`.font`) at this call site. This is concrete, real support for reviewer §7.3's "generated
interface" direction: since `sourcekitd` already resolves the wrapper type's own Swift-side identity,
a targeted `editor.open.interface`/generated-interface query *for that type* is a plausible way to
enumerate its members with their real Swift-mangled USRs attached — still not confirmed (§7.3's own
caveat: "depends on the generated-interface response actually linking each static member back to its
underlying Clang symbol"), but no longer purely speculative — the type-level half of that link is now
directly observed, not assumed.

**Also worth noting for whoever designs the eventual fix:** `key.modulename: "UIKit.NSAttributedString"`
and `key.filepath` pointing at `UIKit.framework/Headers/NSAttributedString.h` — the live per-file
`cursorinfo` query resolves this fine, in full project context (real compiler arguments, real imports).
This is consistent with §2's separate finding that a *bulk*, standalone `swift symbolgraph-extract
-module-name UIKit` dump misses this symbol entirely: the bulk extraction and the live per-call-site
query are resolving different projections of this same header (`swiftExtension.extendedModule:
"Foundation"` in the symbol-graph fragment above confirms `.font` is understood as living in an
extension *of a Foundation type*, physically declared in a header shipped inside `UIKit.framework` —
a real, if unusual, SDK layering detail, not a project-side artifact).

## 9. Next spike — plan (not yet run)

Follows directly from §8's real findings, not a new hypothesis: `key.decl_lang: source.lang.objc`
in §8's dump is the direct explanation for why `cursorinfo` returned the Clang USR — the query
resolved to the *original* ObjC declaration (the real `extern NSString *const NSFontAttributeName`
in `NSAttributedString.h`), not the synthesized Swift-side wrapper. If a query instead targets the
Swift-side text of the same declaration (`static var font: NSAttributedString.Key { get }`, wherever
that text actually lives from sourcekitd's point of view), the expected response should carry
`key.decl_lang: source.lang.swift` and the correct `s:`-prefixed USR.

### 9.1 Plan

1. **Get the real Swift-side text.** `source.request.editor.open.interface` for `UIKit` (and, given
   §8's own `key.modulename: "UIKit.NSAttributedString"` oddity, also try `Foundation` — don't assume
   which module actually owns the generated-interface entry for this extension). Look for
   `extension NSAttributedString.Key` / the `struct Key` declaration in the returned interface text,
   the same way §2 looked for the classic static members in the bulk `symbolgraph-extract` dump —
   just via `editor.open.interface` instead.
2. **Same dump discipline as §8.** Reuse `RawSourceKitD.dumpVariant(_:)`
   (`Sources/SourceKitDIntegration/RawSourceKitD.swift:143-145`) on the full `editor.open.interface`
   response, gated by a temporary env var, reverted after use. Read the real keys returned
   (`key.substructure`, entity-level `key.usr`/`key.name`/`key.offset`, or whatever actually comes
   back) — don't assume the shape from memory of sourcekitd's general response format.
3. **Decision points:**
   - An entity with `key.name == "font"` inside `NSAttributedString.Key`, whose `key.usr` is
     genuinely `s:So21NSAttributedStringKeya5UIKitE4fontABvgZ` → hypothesis confirmed; direction 3
     (reframed in §7.3 as "one cached query per wrapper type") becomes the design; move to
     doc → code per the 7-step workflow.
   - The extension/member simply absent from the `editor.open.interface` response → same coverage
     gap as `symbolgraph-extract` (§2) hits this path too — a real negative result, not a dead end to
     hide. In that case the only remaining non-guess-based option is constructing the `s:`-USR
     programmatically via the same mangling algorithm the compiler uses (deterministic from the
     known container USR + member name + kind), not via any `editor.open.interface` lookup.
   - Multiple entities matching `"font"` across different extension blocks → hard-stop on ambiguity,
     not `.first` — same pattern as everywhere else in this project.
4. **Parallel, independent of 1–3.** §7.2's bulk-cache check (why `symbolgraph-extract` omits this
   family at all) doesn't depend on the interface-query outcome — can run at the same time.

Still spike-stage, not a fix design — §5 explicitly frames all of this as "not designed or vetted,"
and nothing in §9 changes that; this is the next testable hypothesis derived from §8's real data, not
a new guess.

## 10. §9.1 run (2026-08-14) — real result, and one genuinely open thread (dump was cut short)

Reproduced with the same temporary-instrumentation discipline as §8: a new private
`SourceKitDClient.debugDumpSwiftTypeInterface(typeUSR:moduleName:compilerArguments:)`, sending a raw
`source.request.editor.open.interface.swifttype` request (confirmed real via `strings -a`, same as
`.editor.open.interface`/`.editor.open.interface.header` — three related, distinct request kinds exist
in the real binary), called for both `moduleName` "UIKit" and "Foundation" right after §8's cursorinfo
dump fires, gated by the same env vars. Reverted after use, not shipped.

**Getting the request shape right took three real, evidence-based attempts, not guesses:**
1. `key.typeusr` alone, set to `$sSo21NSAttributedStringKeyamD` (§8's own `key.containertypeusr`
   value) → `ERROR: missing 'key.usr'`. The request genuinely requires `key.usr`, a fact learned from
   the real error text, not assumed.
2. Added `key.usr` set to the same `...amD` value (alongside `key.typeusr`) → `ERROR: cannot find
   declaration of type.` Wrong *value*, not wrong *key* this time.
3. Switched the value to `$sSo21NSAttributedStringKeyaD` — §8's own `key.typeusr` (the property's
   declared-type USR; note *no* `m` before the final `D`, unlike `containertypeusr`) — **succeeded**,
   for both module names.

**The real, substantive finding:** `.font` genuinely appears in the returned interface's own
`key.substructure`, as a real entity — `key.kind: source.lang.swift.decl.var.static`, `key.name:
"font"`, `key.typename: "NSAttributedString.Key"`, real offsets into the generated text
(`key.nameoffset: 2857`, `key.namelength: 4`) — confirming the *declaration* is genuinely resolvable
this way. **But that entity, and every other entity in both dumps, carries no `key.usr` field at all**
— confirmed by grepping the complete captured output for `key.usr`: all 9 occurrences across the whole
combined log are from §8's earlier cursorinfo dump; zero in either `editor.open.interface.swifttype`
response. `editor.open.interface`'s structure-outline format is a genuinely different response shape
than `cursorinfo`'s — offsets/names/kinds, not USRs — this isn't a coverage gap in the same sense as
`symbolgraph-extract` omitting the symbol entirely (§2); the member *is* found, just not USR-tagged in
this response shape.

**Important caveat, found only while writing this section up, not swept under the rug:** the captured
dump for *both* modules cuts off mid-entry, at the *identical* structural position
(`...key.offset: 4333 (int64)\n      key.is_syst`) — a clear sign the debug process was killed
mid-write (right after `grep` found the `"font"` entity, before either dump's own writer had flushed
the rest), not a real response boundary. **This means §9.1's decision points (§9's own point 3) were
answered on an incomplete read of the actual response — the "no `key.usr` anywhere" conclusion above is
solid (everything *captured* genuinely has none), but whether a `key.sourcetext` or `key.buffer_name`
field exists *after* the truncation point is still unknown, not ruled out.** `strings -a` on the same
`sourcekitdInProc` binary confirms `key.sourcetext`, `key.buffer_name`, and `key.buffer_text` all exist
as real keys in this sourcekitd build — plausible candidates for what comes after the truncated tail,
not confirmed.

### 10.1 The one concrete, real next step this leaves open

Re-run the identical §9.1/§10 spike, but let the process **run to completion** (or at minimum capture
past the current truncation point) for at least one module, and check specifically for `key.sourcetext`
/ `key.buffer_name` at the response's true top level. If a buffer name (or equivalent identifier) is
present, the natural follow-up — not yet attempted — is a **second, ordinary `cursorinfo` request
targeting that buffer's own synthesized Swift text at the known real offset** (`key.nameoffset: 2857`
for `.font` specifically), the same mechanism §8 already used successfully, just pointed at the
interface's generated Swift source instead of the original call site. If *that* query's `key.decl_lang`
comes back `source.lang.swift` (not `source.lang.objc`, as §8's original query got), its `key.usr`
should be the real answer this whole investigation has been chasing.

If the tail genuinely has nothing usable (confirmed by a full, non-truncated capture), that closes this
specific avenue for real, and `§9`'s own second decision point applies: deterministic `s:`-USR
construction from the known container USR + member name + kind becomes the only remaining
non-guess-based option — not attempted in this session.

**Rerun completed (2026-08-14), no truncation this time (a completion marker was added and waited for
before the process was ever killed):** `key.sourcetext` is real and present — 6668 characters, not
`nil` — confirming §10's own worry (truncation before seeing it) was justified: the field exists,
it was just never reached before. **But `key.buffer_name`/`key.buffer_text` are genuinely `nil`** — a
real, complete-capture-confirmed negative, not another truncation artifact. `editor.open.interface
.swifttype` hands back generated text with no addressable name of its own; it's a one-shot "give me the
text" request, not a "register this as a referenceable document" one.

## 11. §10.1 continued (2026-08-14) — the full chain, real error, and where this leaves the investigation

Continuing empirically rather than falling back to a guessed/constructed USR (explicit user
instruction): register the retrieved `key.sourcetext` as an addressable virtual document via a
separate `source.request.editor.open` call (confirmed real via `strings -a`, along with `key.name`) —
sourcekitd lets a caller *choose* the buffer's name via `key.name` on `editor.open`, unlike
`editor.open.interface.swifttype`'s own response, which never echoes one back. Then hover the known
real offset of `.font` (2857) inside that named buffer via an ordinary `cursorinfo` call, and close the
document afterward via `source.request.editor.close` (also confirmed real).

**Real result, in order:**
1. `editor.open` for the virtual document (`key.name: "swift-isolation-map-debug-interface.swift"`,
   `key.sourcetext: <the real 6668-char text>`) — **succeeded.**
2. The follow-up `cursorinfo` against that same name at offset 2857, reusing the exact same real
   `compilerArguments` §8's own successful query used — **failed**, with a specific, real sourcekitd
   error, not a timeout or malformed response:
   ```
   sourcekit: [1:getCursorInfo:11267: 0.0000] error creating ASTInvocation:
   'swift-isolation-map-debug-interface.swift' is not part of the input files
   ```

**Why, precisely:** the `compilerArguments` reused here are the *real* project build's own frontend
arguments for compiling `Ls_net_ru` — which include an explicit, closed list of every real input
`.swift` file in that target. `cursorinfo`'s AST-invocation construction validates the requested
`key.sourcefile` against that closed list and rejects anything not on it — `editor.open` registering a
buffer under an arbitrary chosen name doesn't add that name to the *compiler invocation's own* input-file
list, which is a separate, independent piece of state. Registering the buffer and being allowed to
build an AST against it inside a specific compilation context are two different sourcekitd concerns.

This is a real, specific, terminal result for *this exact approach* (full project-scoped
`compilerArguments`, reused verbatim) — not a dead end for the whole investigation. Per explicit
instruction, continuing in order rather than switching to guessed-USR construction:

- **(A) `source.request.editor.find_usr`** (confirmed real via `strings -a`, not yet tried at all) —
  named directly for this problem; unknown request/response shape, to be discovered empirically the
  same way `editor.open.interface.swifttype`'s actual required keys were (§10's own trial-and-error
  against real error messages, not guessed from memory).
- **(B) A minimal, standalone `compilerArguments` set for the virtual document** (e.g. just `-sdk
  <path> -target <triple>`, no project-wide input-file list) instead of reusing the real project
  file's own full argument list — since the virtual buffer was never really part of that compilation
  unit to begin with, asking `cursorinfo` to treat it as a free-standing single-file compile (the
  no-file-list way `editor.open.interface.swifttype` presumably already type-checks the type in the
  first place) may sidestep the closed-input-file-list rejection entirely.
- **(C) Deterministic `s:`-USR construction** from the known container USR (`$sSo21NSAttributedString
  KeyaD`) + member name (`"font"`) + kind (`static var`/`swift.type.property`), via the same mangling
  algorithm the real compiler uses — the fallback `§9` always kept open, not attempted in this session,
  genuinely a last resort per this project's own standing rule against naive name-pattern derivation
  (§5's own risk callout, §7.3's extension of it) unless the construction can itself be *verified*
  against real compiler output rather than trusted on the strength of the algorithm alone.

Not yet run: (A) is next per explicit instruction to proceed in order.

## 12. Options A, B, B-variant run to completion (2026-08-14) — real requests, real errors, final conclusion for this empirical avenue

Per explicit instruction ("двигайся по порядку - А, Б, В"), all three were run in order, each reverted
before the next began, `swift build -c release` + `swift test` (353/353) confirmed clean after each.
**Operational note, not a finding:** every run in this section needed `--force-reindex` — the tool
detected the on-disk index as stale (75 changed files) partway through this session and refused to
proceed without it; this recurred on nearly every subsequent run too, adding real wall-clock time
(15-20+ min per `--force-reindex` run) but is unrelated to the sourcekitd investigation itself.

### 12.1 Option A — `source.request.editor.find_usr`

Real request built and sent:
```
key.request = source.request.editor.find_usr
key.name = "font"
key.sourcefile = <the real SkyFloatingLabelTextField.swift path>
key.compilerargs = <the real, full project compiler arguments>
```
**Real result:**
```
DEBUG find_usr(font) ERROR: missing 'key.usr'
```
**Reading:** the request's own error names the missing key precisely, the same way §10's first
`editor.open.interface.swifttype` attempt did. `find_usr` requires a `key.usr` as *input* — meaning its
real purpose is closer to "resolve/validate a given USR" (or find its declaration) than "find the USR
of a given name." Since the whole point of this investigation is *not having* the target USR in the
first place, this request kind cannot serve that role without already possessing the answer. Closed,
not further pursued.

### 12.2 Option B — minimal, standalone `compilerArguments` (no positional file)

Chain: `editor.open.interface.swifttype` (full args, unchanged, confirmed still working) → extract
`key.sourcetext` (real, 6668 chars, same as §11) → `editor.open` with `key.name` = a chosen virtual
document name + `key.sourcetext` → follow-up `cursorinfo` at offset 2857, this time with a *minimal*
argument set extracted from the real full list (only `-sdk`/`-target` pairs kept, everything else
dropped):
```
DEBUG minimal-args: ["-sdk", "/Applications/.../iPhoneSimulator26.4.sdk", "-target", "arm64-apple-ios15.6-simulator"]
DEBUG chain-minimal: got sourcetext, 6668 chars
DEBUG chain-minimal: editor.open succeeded for swift-isolation-map-debug-interface-minimal.swift
DEBUG chain-minimal: followup cursorinfo(swift-isolation-map-debug-interface-minimal.swift, offset=2857) ERROR: error: no input files
```
**Reading:** `key.sourcefile` alone is not treated as a positional compiler input by the underlying
frontend invocation `cursorinfo` builds — with only `-sdk`/`-target` and no file argument anywhere in
`key.compilerargs`, the invocation has *zero* input files, full stop, regardless of `key.sourcefile`
naming a real, already-`editor.open`-registered buffer. Different failure mode than §11's original
attempt (that one had files, just not *this* one on the list; this one has none at all). Closed for
this exact shape, motivated the next variant directly.

### 12.3 Option B, positional-file variant — real success shape, wrong module identity

Same chain, but the virtual document's own chosen name is appended as a genuine **positional**
argument (the way a real `swiftc <file> -sdk ... -target ...` invocation names its input), not just
referenced via `key.sourcefile`:
```
DEBUG minimal-args-positional: ["-sdk", "/Applications/.../iPhoneSimulator26.4.sdk", "-target",
  "x86_64-apple-ios15.6-simulator", "swift-isolation-map-debug-interface-minimal-pos.swift"]
DEBUG chain-minimal-pos: got sourcetext, 6668 chars
DEBUG chain-minimal-pos: editor.open succeeded for swift-isolation-map-debug-interface-minimal-pos.swift
DEBUG chain-minimal-pos: followup cursorinfo(swift-isolation-map-debug-interface-minimal-pos.swift, offset=2857) dump:
```
**This one produced a real, complete, error-free response** — the first of the whole §7-§12
investigation to do so for this specific follow-up call. Full real response (top-level keys, values
elided only where truncated for length):
```
key.column: 23
key.symbol_graph: {"metadata":{...},"module":{"name":"main","platform":{"architecture":"x86_64",
  "environment":"simulator","vendor":"apple","operatingSystem":{"name":"ios","minimumVersion":
  {"major":15,"minor":6}}}},"symbols":[{"kind":{"identifier":"swift.type.property",...},
  "identifier":{"precise":"s:4main3KeyV4fontXevpZ","interfaceLanguage":"swift"},
  "pathComponents":["Key","font"],
  "names":{"title":"font","subHeading":[{"kind":"keyword","spelling":"static"},...,
    {"kind":"text","spelling":": NSAttributedString"},{"kind":"text","spelling":".Key"}]},
  "docComment":{"uri":"file://swift-isolation-map-debug-interface-minimal-pos.swift", "module":"main",...},
  "declarationFragments":[...,{"kind":"text","spelling":": NSAttributedString"},
    {"kind":"text","spelling":".Key"}],
  "accessLevel":"public","availability":[{"domain":"iOS","introduced":{"major":6,"minor":0}}],
  "location":{"uri":"file://swift-isolation-map-debug-interface-minimal-pos.swift",
    "position":{"line":83,"character":22}}}],
  "relationships":[{"kind":"memberOf","source":"s:4main3KeyV4fontXevpZ","target":"s:4main3KeyV"}]}
key.fully_annotated_decl: <decl.var.static>public static let <decl.name>font</decl.name>: NSAttributedString.Key</decl.var.static>
key.doc_comment: "********************** Attributes ***********************"
key.annotated_decl: <Declaration>public static let font: NSAttributedString.Key</Declaration>
key.line: 84
key.modulename: "main"
key.decl_lang: source.lang.swift
key.kind: source.lang.swift.decl.var.static
key.offset: 2857
key.doc.full_as_xml: <Other file="swift-isolation-map-debug-interface-minimal-pos.swift" line="84"
  column="23"><Name>font</Name><USR>s:4main3KeyV4fontXevpZ</USR><Declaration>@available(iOS 6.0, *)
  public static let font: NSAttributedString.Key</Declaration>...</Other>
key.usr: "s:4main3KeyV4fontXevpZ"
key.typeusr: "$sXeD"
key.typename: "_"
key.filepath: "swift-isolation-map-debug-interface-minimal-pos.swift"
key.name: "font"
key.parent_contexts: [
  { key.kind: "swift.struct", key.usr: "s:4main3KeyV", key.name: "Key" },
  { key.kind: "swift.type.property", key.usr: "s:4main3KeyV4fontXevpZ", key.name: "font" }
]
key.length: 4
```

**The good part:** `key.decl_lang: source.lang.swift` (not `.objc`, unlike every prior real query in
this whole investigation) — the query genuinely resolved through Swift-side type-checking this time,
and `key.usr` is a real, well-formed `s:`-prefixed Swift-mangled USR, not a Clang one.

**The real, definitive problem:** `key.modulename: "main"`, and the USR itself —
`s:4main3KeyV4fontXevpZ` — is mangled under a synthetic module named **`"main"`**, with `Key` as a
*freshly-declared* top-level struct in that module (`key.parent_contexts`: `{key.usr: "s:4main3KeyV",
key.name: "Key"}`), not `UIKit`/`Foundation`'s real `NSAttributedString.Key`. This does **not** match,
and structurally *cannot* be made to match, the real, expected
`s:So21NSAttributedStringKeya5UIKitE4fontABvgZ` (module `UIKit`, `So`-prefixed ObjC-bridged typealias
`NSAttributedStringKey`, extension member).

**Why this is a structural dead end, not a missing flag:** `editor.open.interface.swifttype`'s own
`key.sourcetext` is a *textual re-rendering* of the declaration for human/tooling display — real Swift
syntax, but disconnected from the actual Clang header / ObjC module linkage that produces the real
bridged USR shape. Compiling that text standalone (regardless of `-sdk`/`-target`/`-module-name`
tuning) makes the frontend synthesize a **brand-new**, first-party `struct Key` from scratch in
whatever module the invocation is told it belongs to — it can never reconstruct the *real* `So`-prefixed,
ObjC-interop-derived identity, because that identity depends on genuinely importing and type-checking
against the real `NSAttributedString.h`/`UIKit` module graph, which a disconnected, regenerated text
buffer is definitionally not part of. No further compiler-argument tuning of this specific chain
(`editor.open.interface.swifttype` → `editor.open` → `cursorinfo`) can fix this — the input to the
final `cursorinfo` call would need to *be* the real header or a real project file that imports the real
module, not a re-synthesized standalone text buffer.

### 12.4 Where this leaves the investigation (§7-§12), plainly

Four real, distinct, empirically-executed attempts across §10-§12 (`editor.open.interface.swifttype`'s
structure dump directly; `editor.find_usr`; minimal-args `cursorinfo` without a positional file;
minimal-args `cursorinfo` with one) — **zero of them produced the real, expected
`s:So21NSAttributedStringKeya5UIKitE4fontABvgZ` USR.** Three failed outright with distinct, understood,
real sourcekitd errors (`missing 'key.usr'`; `no input files`); one succeeded mechanically but returned
a USR for the wrong, synthetic module, for a structural reason (§12.3's own explanation) that no further
variation of *this specific request chain* can route around.

This is a real, strong signal — not proof, but strong — that **no combination of `sourcekitd` requests
this project's own binding design already restricts itself to (real compiler queries only, never
text/substring inference) can recover this specific USR**, because the only sourcekitd-visible
representation of `.font` that carries a real Swift-side USR at all (the regenerated interface text) is
inherently disconnected from the real ObjC module linkage that produces the *correct* one. The
`cursorinfo` query that *does* see the correct module linkage (§8's own original query, at the real call
site) only ever sees the Clang-side declaration, never the Swift-bridged one.

**Remaining real options, not decided here:**
- **(C) Deterministic `s:`-USR construction** (§9/§11's own standing fallback) — no longer just "the
  last resort nobody's tried yet"; §12's negative results make it closer to "the only remaining
  non-guess-based option left," since every live-query avenue this project's own binding design permits
  has now been tried and closed. Still requires the same discipline as always: the constructed USR must
  be *verified* against something real (e.g. checking it against a live UIKit bulk-symbolgraph
  extraction, or a real IndexStoreDB lookup) before being trusted, not accepted on the strength of the
  mangling algorithm alone.
- **Accept the gap as a documented, real, unfixable-via-USR-matching limitation** for this specific
  symbol family, and pursue a *different* fix layer entirely instead of chasing the USR match — e.g.
  recognizing the `c:@NSFontAttributeName`-shaped Clang USR pattern directly (a real, stable,
  `NS*AttributeName`-style naming convention, confirmed via §2's real symbol-graph data) and mapping it
  to a *known-safe* isolation answer (`.nonisolated`, confirmed correct for this whole family via the
  original real corpus data) **without** ever needing the Swift-side USR to match at all — sidestepping
  the whole matching problem rather than solving it. Not designed here; flagged as a real alternative
  worth weighing against (C).

## 13. External-reviewer critique (2026-08-14) accepted, two untried avenues run: real `libIndexStore`
relation records, and why `symbolgraph-extract` skips this family everywhere

A reviewer pass over §§2-§12 correctly identified two real, concrete, never-attempted avenues that
every prior attempt (§2, §8, §10, §11, §12.1-12.3) had missed by construction — all eight of those were
live queries *through sourcekitd* (`cursorinfo`, `editor.open.interface[.swifttype]`, `editor.find_usr`);
none of them ever inspected the real relation records `RawIndexStoreClient` reads directly from
`libIndexStore`'s own C API, the exact mechanism PR #82's sibling fix (`owningPropertyUSR`) was built
on. Prioritized (per the reviewer's own ordering, accepted as-is): (1) real relation records first —
cheapest, reuses existing, working infrastructure, directly analogous to the PR #82 precedent; (3) in
parallel — independent, doesn't block anything. (2) (a module-scoped `editor.open.interface`, called
with the *real* project `compilerArguments` instead of the type-scoped `.swifttype` variant §10 actually
used) and (4)/(5) were left for after (1)/(3), per the reviewer's own explicit ordering — not run this
session.

### 13.1 Option 1 — real relation records via `RawIndexStoreClient`, both directions, every real role

Much cheaper than every prior spike in this document: no sourcekitd, no `--force-reindex`, no full
pipeline run at all. `RawIndexStoreClient(storePath:)` builds its entire in-memory relation index once,
synchronously, directly from the already-on-disk `lsboutique` index store
(`~/Library/Developer/Xcode/DerivedData/lsboutique-.../Index.noindex/DataStore`) — a temporary Swift
Testing test constructing it directly and calling a temporary `debugAllRelations(forUSR:)` (mirroring
the exact name/shape of the PR #82 spike's own temporary method, per its own doc-comment reference)
ran in **10.5 seconds**, versus 15-20+ minutes per attempt for every prior sourcekitd-based spike in
this document.

`debugAllRelations` dumped **both** directions (`relationsBySymbolUSR[usr]` — what `usr` relates to,
and `relatedToUSR[usr]` — what relates to `usr`) with **zero role filtering**, decoded against the real,
complete `indexstore_symbol_role_t` enum (fetched from the actual vendored header,
`.build/checkouts/indexstore-db/.../indexstore_functions.h` — 19 real role bits, not the 7 this
project's own `CIndexStoreRaw.h` had already copied for its narrower production needs) — an unrecognized
bit would have printed as a raw hex value, not been silently dropped, so this is a genuinely exhaustive
read of everything the index stores for these USRs.

**Real results, four USRs checked:**
- `s:So21NSAttributedStringKeya5UIKitE4fontABvgZ` (`.font`, the Swift-bridged USR):
  `relationsBySymbolUSR` has 166 real relations, **every one** `REL_CALLEDBY` (a real project caller)
  combined with `REL_CONTAINEDBY` (`1 << 16`, decoded from the real header — this bit had shown as
  `UNKNOWN(0x10000)` against this project's own narrower 7-constant copy) — i.e. exactly the real
  call-graph edges this whole investigation already knew about, nothing else. `relatedToUSR` — **empty**.
- `c:@NSFontAttributeName` (the Clang constant USR): same 166-caller shape, but with a *different* role
  combination (`REL_CONTAINEDBY` alone, no `REL_CALLEDBY`) — a real, meaningful difference, but still
  only ever pointing at the same real callers, never at the Swift-bridged USR. `relatedToUSR` — **empty**.
- `c:@T@NSAttributedStringKey` (the container type's own Clang USR): ~940 real relation entries, all but
  one `REL_CALLEDBY`/`REL_CONTAINEDBY` shaped exactly like the above; **one** real `REL_EXTENDEDBY`
  relation found — but it points to `s:e:s:So21NSAttributedStringKeya9LayoutKitE13ctRunDelegate...`, a
  real project *third-party dependency's* own extension (`LayoutKit` adding `ctRunDelegate`, an
  unrelated member) — confirming `.extendedBy` relations genuinely exist and are indexed for real,
  project-visible extensions of this type, just never for UIKit's own SDK-internal extension containing
  `.font`/`.kern`/etc. `relatedToUSR` — **empty**.
- `s:So21NSAttributedStringKeya5UIKitE4kernABvgZ` (`.kern`, checked as a second real data point, not
  just `.font` alone): identical shape to `.font` — 166+ `REL_CALLEDBY`/`REL_CONTAINEDBY` relations,
  `relatedToUSR` empty.

**Conclusion, exhaustive within what this index stores:** no relation of any real, known kind
(`.accessorOf`, `.baseOf`, `.childOf`, `.overrideOf`, `.receivedBy`, `.extendedBy`,
`.ibTypeOf`, `.specializationOf`) connects `s:So21NSAttributedStringKeya5UIKitE4fontABvgZ` to
`c:@NSFontAttributeName` (or vice versa) anywhere in this real, on-disk index store. Unlike PR #82's
sibling case (a real `.accessorOf` relation genuinely existed in the index, just needed the right
lookup path), **this specific USR pair's connection is never recorded by `libIndexStore` at all** — not
a lookup-path gap this project's own code could close, a genuine absence of data. Confirmed, not
inferred: every relation for both USRs was read and inspected, not just the ones a hypothesis predicted
would be there.

**Separate, unrelated finding surfaced along the way, worth its own tracking item:**
`Sources/CIndexStoreRaw/include/CIndexStoreRaw.h` copies only 7 of the real `indexstore_symbol_role_t`
enum's 19 bits (`.build/checkouts/indexstore-db/.../indexstore_functions.h`'s own real, complete
definition) — deliberately, per that file's own comment ("only the 7 this project actually needs").
`INDEXSTORE_SYMBOL_ROLE_REL_CONTAINEDBY` (`1 << 16`) is one of the twelve *not* copied, and is a real,
commonly-set bit in practice — every single relation this section's `.font`/`.kern` real data collected
carries it. Confirmed **not currently an active bug**: `Sources/CIndexStoreRaw/shim.c`'s own
`indexstore_shim_occurrence_get_roles`/`indexstore_shim_symbol_relation_get_roles` pass the real, full,
untruncated bitmask value straight through from `libIndexStore` (nothing is lost at the C layer), and
every current production consumer (`owningPropertyUSR`, `baseTypeUSRs`, `containingExtensionUSR`,
`extendedTypeUSR` — all of `RawIndexStoreClient.swift`) only ever tests via masked `role & KNOWN_CONSTANT
!= 0` checks against the 7 bits it does name, never an exact-equality comparison against the whole
value — so an unnamed bit being set alongside a named one it cares about doesn't change any of today's
real answers. The real risk is latent, not active: any *future* code added to this project that (a)
checks for `.REL_CONTAINEDBY` specifically (not done today), or (b) decodes/logs a raw role value
assuming this header's 7 constants are the complete real picture (exactly the mistake this section's
own first debug-decode draft made, before switching to the real, complete header), would get a silently
wrong or incomplete answer. Worth its own follow-up item to either copy the remaining 12 constants now
(cheap, matches the file's own "copied verbatim from the real header" precedent) or explicitly document
the 7-of-19 scoping decision more prominently where the constants are declared — not otherwise in scope
for this document's own task.

### 13.2 Option 3 — confirmed omitted from *both* plausible owning modules' bulk extraction

§2 already established `.font` is absent from a bulk `swift symbolgraph-extract -module-name UIKit`
dump. Real §8 evidence (`swiftExtension.extendedModule: "Foundation"` inside the live-queried symbol
graph) raised the obvious follow-up: is it present in a bulk `-module-name Foundation` extraction
instead — the module the live query itself says actually owns the type? Run directly (no pipeline, no
sourcekitd, just the same real `swift symbolgraph-extract` binary): a full `-module-name Foundation
-minimum-access-level public` extraction against the same real SDK produced 16827 real symbols across
its primary file and every sibling cross-module file (`Foundation@CoreFoundation`, `@Dispatch`,
`@ObjectiveC`, `@Swift`, `@System`, `@_Concurrency`, `@_DarwinFoundation1`, `@_StringProcessing`,
`@Darwin`) — **no `Foundation@UIKit` sibling file exists at all**, and a direct search of every one of
those 16827 symbols for `.font`/`NSFontAttributeName` found **zero matches**.

**Real, confirmed negative, not just "still worth checking":** `.font` (and, by the same shared
mechanism, the rest of this whole symbol family) is omitted from bulk `symbolgraph-extract` under
*both* of its two plausible owning modules — not a wrong-module guess in §2's original investigation,
a genuine gap in what bulk `symbolgraph-extract` enumerates for this declaration shape, regardless of
which module is asked. This strengthens (does not yet fully root-cause *why*, at the compiler-internals
level) the read that this is a structural `SymbolGraphGen` limitation for `NS_SWIFT_NAME`-bridged extern
constants specifically — consistent with §11/§12's own finding that only a *live*, full-project-context
`cursorinfo` query (never a bulk, standalone extraction) ever resolves this declaration's true identity
at all, and even that live query only sees it from the Clang side, never the Swift-bridged one.

### 13.3 Where this leaves the investigation, updated

Combined with §12.4: **six** real, distinct, empirically-executed avenues now closed (`editor.open
.interface.swifttype`'s own structure dump; `editor.find_usr`; minimal-args `cursorinfo` without/with a
positional file; real relation records in both directions against every known role; bulk
`symbolgraph-extract` under both plausible modules) — **zero** produced the real, expected
`s:So21NSAttributedStringKeya5UIKitE4fontABvgZ` USR anywhere it could be matched against. Every
sourcekitd/libIndexStore mechanism this project's own binding design permits (real compiler queries
only, never text/substring inference) has now been tried.

**Not yet run, per the reviewer's own explicit ordering** (only worth attempting if closing the
remaining live-query avenue is still wanted before moving to (4)/(5)):
- **(2)** — a *module*-scoped `editor.open.interface` (not the `.swifttype` variant), called with the
  real project `compilerArguments` (the same ones §8's own successful original query used, not §10-§12's
  narrower/minimal ones) — the reviewer's own reasoning: §12.3's structural failure (disconnected
  synthetic `"main"` module) came specifically from `.swifttype`'s own text-regeneration-then-standalone-
  recompile shape; a module-scoped open, given the *real* project context UIKit is actually imported
  into, might resolve within the real module graph instead of a synthetic one. Not attempted this
  session.

**Remaining, not yet decided:** (4) deterministic USR construction, (5) pattern-match on the Clang USR
shape and skip matching entirely (§12.4's own two options) — both still open, now with six real closed
avenues behind them instead of four.

## 14. Option 2 — module-scoped `editor.open.interface` with real project `compilerArguments`

Attempted per explicit instruction ("пробуй 2, 4, 5"). Same temporary-instrumentation discipline as
§8-§13: a new `debugModuleInterfaceThenHoverFont`, calling `source.request.editor.open.interface`
(the *module*-scoped request, not `.swifttype`) with `key.modulename: "UIKit"` and the real, full
project `compilerArguments` (the same ones §8's own original successful query used) — then locating
`.font`'s real offset inside the returned module-wide interface text itself (searching for `extension
NSAttributedString.Key` / `struct Key`, then the first `let font:`/`var font:` within that region --
not assuming §10-§12's own offset 2857, which was specific to the much smaller, type-scoped text those
sections retrieved), then the same `editor.open` → `cursorinfo` → `editor.close` chain as §11/§12.

**Real result:** the module-scoped request succeeded and returned real, substantial content — `key
.sourcetext`, **232319 characters**, the entire UIKit module's generated Swift interface, not a
type-scoped fragment. But a direct search of that complete text for `"extension NSAttributedString
.Key"` or `"struct Key"` found **neither anywhere in it**:
```
DEBUG module-interface: got sourcetext, 232319 chars
DEBUG module-interface: could not find "NSAttributedString.Key" / "struct Key" anywhere in the 232319-char interface text
```
Chain stopped here (by design — no member offset to hover without first finding the type), never
reached the `editor.open`/`cursorinfo` steps this time.

**Reading:** even UIKit's own complete, real, module-scoped generated interface — retrieved with the
real project's own compiler arguments, the exact context this option was designed to test — never
mentions `NSAttributedString.Key` at all, let alone `.font`/`.kern`/etc. This is a stronger, more
direct confirmation of §13.2's finding than that section's own bulk `symbolgraph-extract` check: not
just "bulk symbol *graph* extraction omits this," but "the *generated interface text itself* — the same
kind of artifact `.swifttype` retrieves a narrower slice of — never surfaces this declaration for UIKit,
module-wide, under any request shape tried." Whatever real compiler/index mechanism actually resolves
`.font`'s existence when queried live *at a real call site* (§8's own original, successful query) is
evidently something none of the "ask for a textual interface" family of requests (`.swifttype`, whole-
module) ever draws on, regardless of scope or compiler-argument realism. Option 2 closed, negative,
real.

## 15. Options 4 and 5, verified and synthesized into one concrete design (not yet implemented)

Both attempted per explicit instruction. Real verification, not guesswork, led to a synthesis stronger
than either option alone -- see §15.3.

### 15.1 Option 4 — deterministic USR construction, verified against all 22 real family members

**Important reframing before attempting this, found while doing it:** `ExternalIsolationBackfill.query
(targetUSR:...)` already *has* the real, correct, expected Swift-mangled USR as an input parameter --
the whole problem is matching a live `cursorinfo` candidate *against* it, never constructing it from
scratch (nothing in the real pipeline needs a USR nobody already has). So "deterministic construction"
is actually most useful as a **verified parser for `targetUSR`'s own real structure** -- extracting the
member name it encodes -- used to *recognize* a live candidate as the same declaration, not to fabricate
a new value.

**The real Swift mangling shape, confirmed against every one of the 22 real family members found in
§1/§3** (not just `.font`):
```
s:So21NSAttributedStringKeya5UIKitE<N><member-name>ABvgZ
```
where `<N>` is the member name's own UTF-8 length as a decimal literal (Swift's real length-prefixed
mangling convention). Verified programmatically against all 22 real USRs from the original report data
(`attachment`, `strokeColor`, `strokeWidth`, `baselineOffset`, `paragraphStyle`, `underlineColor`,
`underlineStyle`, `backgroundColor`, `foregroundColor`, `strikethroughColor`, `strikethroughStyle`,
`accessibilitySpeechPitch`, `accessibilitySpeechLanguage`, `accessibilityTextHeadingLevel`,
`accessibilitySpeechIPANotation`, `accessibilitySpeechPunctuation`,
`accessibilitySpeechQueueAnnouncement`, `font`, `kern`, `link`, `shadow`, `ligature`) —
**22 of 22 real, ground-truth USRs reconstructed exactly**, zero mismatches, by parsing/reconstructing
`prefix + String(name.utf8.count) + name + suffix` for the fixed `prefix = "s:So21NSAttributedStringKeya5UIKitE"` /
`suffix = "ABvgZ"` pair.

**Explicitly checked whether this generalizes to §3's unconfirmed families before trusting it further —
it does not, confirming that section's own caution was warranted, not just prudent:**
`UIControlState`'s four real USRs (`s:So14UIControlStateV6normalABvgZ`,
`s:So14UIControlStateV8selectedABvgZ`, `s:So14UIControlStateV8disabledABvgZ`,
`s:So14UIControlStateV11highlightedABvgZ`) use a **structurally different** shape —
`s:So14UIControlStateV<N><name>ABvgZ`, with `V` (a real Swift `struct`, declared natively, no
`NS_SWIFT_NAME`-bridged typealias) where `NSAttributedString.Key`'s own shape has `a` (typealias
marker) + a separate `5UIKitE` (cross-module extension marker). Confirms these are two genuinely
different declaration shapes (native Swift `OptionSet` struct vs. `NS_SWIFT_NAME`-bridged ObjC extern
constant), not the same pattern with a different type name substituted — any real fix must recognize
the specific mangling grammar per shape, never assume one universal template covers every family in §3.

### 15.2 Option 5 — why the Clang-side candidate is safely `.nonisolated`, grounded in real dumps already collected

Not a new guess -- the evidence is already sitting in every real `cursorinfo` dump this document
collected (§8, §12.3): the live query's `primary` result for `.font` (and, by the same real, observed
shape, the rest of this family) is `key.kind: source.lang.swift.ref.var.static`,
`key.decl_lang: source.lang.objc` -- a plain static member reference with **zero** isolation-attribute
declaration fragment anywhere in any dump collected across this whole investigation. This is not an
absence-of-evidence problem: `SymbolGraphIsolationParser`'s own doc comment (already part of this
project, predating this investigation) documents that for a *live, per-declaration* `cursorinfo` query
specifically (as opposed to a *bulk* `symbolgraph-extract` dump, where absence is genuinely ambiguous --
see that same file's own extended reasoning), "no attribute fragment at all" **is** the compiler's real,
positive `.nonisolated` signal, not a gap. `ExternalIsolationBackfill.query`
(`Sources/swift-isolation-map/ExternalIsolationBackfill.swift:912`) already calls exactly this parser
correctly, on every USR it successfully matches — the mechanism that would derive the *correct* answer
here already exists and is already used elsewhere in this exact function. It's specifically gated behind
`USRMatching.select`'s exact-string-equality requirement (`Sources/SourceKitDIntegration/USRMatching.swift:16-24`),
which fails for this whole family before that already-correct downstream logic ever gets a chance to
run.

### 15.3 Synthesis — a concrete, narrow, verifiable matching criterion (design only, not implemented)

Combining both: don't fabricate a `.nonisolated` answer for this family via a hardcoded name-pattern
special case (§12.4's original framing of option 5, which this document's own standing discipline
against unverified name-pattern derivation would otherwise have to reject, same as PR #82's rejected
`setXxx:` → `xxx` transform). Instead, **extend `USRMatching.select`'s acceptance criterion** for
exactly this shape, so the existing, already-correct isolation-parsing pipeline runs on a genuine match
instead of returning `.unknown` before ever looking at the candidate's own real fragments:

1. Recognize `targetUSR` as shaped `s:So<N><TypeName>a<M><ModuleName>E<N2><MemberName>ABvgZ` (§15.1's
   confirmed grammar) and parse out `<TypeName>` and `<MemberName>` (a real, verified operation — not
   guessed, §15.1's own 22/22 confirmation of this exact grammar).
2. Accept a candidate (from `result.all`) as a match when **all** of:
   - its own `key.name` (already correctly returned by the live query, confirmed in every real dump
     collected) equals the parsed `<MemberName>`;
   - its `key.decl_lang` is `source.lang.objc` (i.e. this is genuinely the Clang-side presentation, not
     some unrelated Swift declaration that happens to share a name);
   - its `.usr` starts with `c:@` (a plain Clang top-level/extern-constant USR shape, not e.g. an
     Objective-C method selector `c:objc(cs)...(im)...` — deliberately narrow, not "any Clang USR");
   - **its own `key.containertypeusr` equals the reconstructed `"$s" + "So" + <N> + <TypeName> + "a" + "mD"`**,
     built from the *same* `<TypeName>`/`<N>` just parsed out of `targetUSR` — a fourth, independent
     leg, not present in the first draft of this criterion. Closes a real gap a reviewer pass over this
     section found: without it, the criterion never actually confirms the candidate belongs to the
     *right container type*, only that some Clang-side declaration happens to share a member name and
     shape. Relying on "the call site's own `targetUSR` already pins the type by construction" is true
     for how `query()` is invoked today, but checking it directly is nearly free (the field is already
     present in the same response) and turns an implicit assumption into an explicit, falsifiable
     check — the same unanimous-match-not-partial discipline this project already applies elsewhere
     (`resolvedOwningPropertyUSR`'s own unanimous-agreement requirement; the closure-isolation
     accept-list's own exact-match design). **`key.containertypeusr`, not `key.typeusr`, deliberately**:
     a second reviewer pass caught that the first draft checked `key.typeusr` (the *member's own value
     type*, which for this `static var x: Self`-shaped family happens to equal its container) instead
     of `key.containertypeusr` (the field that actually, semantically means "what type is this a member
     *of*") — an implicit-assumption-disguised-as-a-check the document had just finished arguing against
     for the criterion as a whole. Switched immediately rather than deferred to "if this is ever
     extended beyond this family," since the cost is identical (the field is already present in the
     same response) and the dependency on a same-family coincidence was exactly the kind of implicit
     assumption §15.3 exists to eliminate. Confirmed by direct computation:
     `key.containertypeusr` in §8's own `.font` dump is `"$sSo21NSAttributedStringKeyamD"`, and
     `"$s" + "So" + "21" + "NSAttributedStringKey" + "a" + "mD"` reproduces it exactly. **Now confirmed
     against a second, independent real example too — see §15.4.**
3. On a match by this criterion, run the **existing, unmodified** `SymbolGraphIsolationParser`/
   `FullyAnnotatedDeclParser` path exactly as today — no new hardcoded `.nonisolated` special case is
   needed; the real declaration fragments already say so, correctly, once actually read.

This is narrower and more conservative than §12.4's original option 5 framing (a blanket "map the whole
`c:@NS*AttributeName` shape to `.nonisolated`" rule) — it doesn't trust the *name convention*
(`NS*AttributeName`) at all, only the *declaration's own returned facts* (name match + decl-lang +
USR-prefix shape + container-type match), cross-checked against a real, 22/22-verified parse of the
already-known-correct target. **Not implemented or tested this session** — a real design synthesis from
real verification, at the "doc" stage of this project's own 7-step workflow (hypothesis → spike → doc →
code → tests → results → PR), ready for someone to move to "code" with a clear, falsifiable, four-part
acceptance criterion rather than a vague direction.

### 15.4 Fourth leg cross-checked against a second real example (`.kern`) — confirmed

Per a reviewer's own follow-up ("не откладывал бы... а прогнал на .kern"), reproduced with the same
temporary-instrumentation discipline as every prior spike, gated on `key.name == "kern"` rather than a
specific file/offset this time. **First attempt targeted the wrong file** — a real, useful mistake
worth recording: `DeliveryInfoCell.swift:202` is a genuine real-project call site for `.kern`, but the
edge-level oracle trigger only ever queries the *canonical representative* location for a given
`calleeUSR` — the lexicographically-smallest `(file, line, column)` among *every* real edge referencing
it project-wide (`ExternalIsolationBackfill.collectEdgeLevelWorkItems`'s own documented rule) — every
other real call site is backfilled from that one answer, never queried live itself. For `.kern`'s real
edge set, the lexicographically-smallest file is `/Users/ab/ios/Pods/SwiftRichString/Sources/
SwiftRichString/Attributes/FontData.swift` (`Pods/...` sorts before `lsboutique/...` — uppercase `P`
precedes lowercase `l` in a plain byte-wise string comparison) — confirmed by recomputing the real sort
directly against the report's own edge list, not guessed. Retargeting the debug gate to that file
found the real dump on the first subsequent attempt.

**Real result, `.kern`'s own live `cursorinfo` dump** (`FontData.swift:9171`, the file's own canonical
representative location):
```
key.usr: "c:@NSKernAttributeName"
key.decl_lang: source.lang.objc
key.kind: source.lang.swift.ref.var.static
key.name: "kern"
key.typeusr: "$sSo21NSAttributedStringKeyaD"
key.containertypeusr: "$sSo21NSAttributedStringKeyamD"
key.typename: "NSAttributedString.Key"
```
Every field matches the pattern `.font` established, byte-for-byte where the two members' own shapes
should agree: `key.decl_lang`, `key.typeusr`, and `key.containertypeusr` are **identical** to `.font`'s
own real values (both members share the same container, exactly as expected), `key.usr` follows the
same `c:@NS<CamelCaseName>AttributeName` real Clang naming convention (`NSKernAttributeName`, alongside
`NSFontAttributeName`), and `key.name` correctly matches the member being parsed out of `targetUSR`
(`"kern"`, matching `s:So21NSAttributedStringKeya5UIKitE4kernABvgZ`'s own encoded member name per
§15.1's grammar).

**§15.3's four-part criterion is now confirmed against two real, independent members, not one.** Every
sub-check in §15.3 — member-name match, `decl_lang`, USR-prefix shape, and the `key.containertypeusr`
reconstruction — holds exactly for both `.font` and `.kern`. Combined with §15.1's own 22/22 confirmation
of the member-name grammar itself, this design synthesis is now verified as thoroughly as this
project's own 7-step workflow's "spike" stage calls for, ready to move to "code" without further
spiking — implementation and its own real test suite (per this project's own established discipline:
a synthetic disagreement-case test the way `resolvedOwningPropertyUSR`'s own tests already cover, plus
a real end-to-end regression check against this same `lsboutique` corpus, matching how PR #82/#84 were
each verified before/after) are the natural next step, not attempted in this session.

## 16. Minimal, third-party-independent reproduction — confirms the mechanism is general, not UIKit-specific

Everything in §§1-15 was diagnosed against real Apple SDK headers (`UIKit`/`Foundation`). A real,
standing concern (raised explicitly during this investigation): does the same bug hit an arbitrary
*third-party* Objective-C library using the identical `NS_SWIFT_NAME`-bridged-extern-constant pattern,
or is this somehow specific to how Apple's own SDK is built/indexed? Answered here with a minimal,
fully self-authored, from-scratch reproduction — no Apple framework involved at all.

### 16.1 The mini package

A tiny two-target SwiftPM package (`Sources/CMiniAttrs` — a plain C target; `Sources/MiniAttrsUser` — a
Swift target depending on it), mirroring the real `NSAttributedString.h` pattern
(`typedef NSString * NSAttributedStringKey NS_EXTENSIBLE_STRING_ENUM; ... NSFontAttributeName
NS_SWIFT_NAME(NSAttributedString.Key.font);`) exactly, one-to-one:

```c
// CMiniAttrs.h
typedef NSString *MiniAttrKey NS_EXTENSIBLE_STRING_ENUM;
FOUNDATION_EXPORT MiniAttrKey const MiniFontAttributeName NS_SWIFT_NAME(MiniAttrKey.font);
```
```objc
// CMiniAttrs.m
MiniAttrKey const MiniFontAttributeName = @"MiniFont";
```
```swift
// MiniAttrsUser.swift
import CMiniAttrs
public func realCallSite() -> MiniAttrKey {
    MiniAttrKey.font
}
```
`NS_EXTENSIBLE_STRING_ENUM` is the same real Foundation macro that makes ClangImporter auto-synthesize
a Swift `RawRepresentable` struct from the typedef — no hand-written Swift wrapper anywhere, exactly
matching how `NSAttributedString.Key` itself is synthesized, not hand-authored.

### 16.2 Real, end-to-end confirmation via the actual tool

Ran the *real* `swift-isolation-map` binary directly against this package (`--scheme MiniAttrsUser`,
`--force-reindex`) — no Xcode, no CocoaPods, no `--force-reindex`-staleness cost the rest of this
document kept paying: the whole run, clean build included, completes in a few seconds. **Real report,
1/1 cross-isolation edge, unresolved:**
```json
{
  "calleeIsolation": "unspecified",
  "calleeUSR": "s:So11MiniAttrKeya4fontABvgZ",
  "callerIsolation": "nonisolated",
  "isUnknown": true,
  "risk": "medium"
}
```
The real call graph records `s:So11MiniAttrKeya4fontABvgZ` — the same mangling grammar as
`NSAttributedString.Key.font`, just missing the `5UIKitE` cross-module-extension component §15.1's
grammar includes, because here the constant and its wrapper type live in the *same* module (no
cross-module extension needed) — a real, informative confirmation that that component is specifically
about cross-module placement, not a fixed part of the grammar. The bug reproduces identically: `isUnknown:
true`, `calleeIsolation: "unspecified"`.

### 16.3 Real `cursorinfo` dump confirms the identical Clang/Swift split

Same temporary-instrumentation approach as §8 onward, pointed at this package's own real call site. One
operational note worth recording: the *first* attempt (reusing a `.build` directory already built by a
plain `swift build` beforehand) produced `argumentsNotFound` for every USR — `LiveSwiftPMCompilerArgumentsProvider`
runs `swift build -v` and parses real per-file compile lines from it, and an *incremental* build (nothing
to recompile) emits none, the same "stale build gives zero usable invocations" failure mode
`StalenessOrchestration`/`XcodeBuildLogCompilerArgumentsProvider` already guard against for Xcode
containers — `LiveSwiftPMCompilerArgumentsProvider` has no equivalent clean-rebuild retry. Not a new bug
in the sense of a regression (nothing here claims this needs fixing), but a real, concretely reproduced
edge case worth being aware of if this class of tool is ever pointed at an *already-built* SwiftPM
package. Deleting `.build` and re-running once more (`--force-reindex`, a genuinely clean build) resolved
it.

**Real `cursorinfo` response for `.font`, live query, this package's own real compiler context:**
```
key.usr: "c:@MiniFontAttributeName"
key.decl_lang: source.lang.objc
key.typeusr: "$sSo11MiniAttrKeyaD"
key.containertypeusr: "$sSo11MiniAttrKeyamD"
key.typename: "MiniAttrKey"
key.name: "font"
```
The exact same split as every real Apple-SDK case in this document: the live query resolves to the
Clang-side `c:@MiniFontAttributeName`, never the Swift-bridged `s:So11MiniAttrKeya4fontABvgZ` the real
call graph actually uses.

**§15.3's `key.containertypeusr` formula holds on this third, fully independent example too:**
`"$s" + "So" + "11" + "MiniAttrKey" + "a" + "mD"` reproduces `"$sSo11MiniAttrKeyamD"` exactly — the same
formula, unmodified, now verified against `NSAttributedString.Key.font`, `NSAttributedString.Key.kern`,
and this from-scratch `MiniAttrKey.font`, spanning two real Apple SDK modules plus one fully
self-authored, non-Apple package.

### 16.4 What this settles

**The mechanism this whole document investigates is real, general, and not an Apple-SDK quirk of any
kind** — any Objective-C library (system or third-party) using `NS_EXTENSIBLE_STRING_ENUM`/
`NS_TYPED_EXTENSIBLE_ENUM` + `NS_SWIFT_NAME` to expose extern constants as Swift static members hits the
identical USR-mismatch shape, confirmed end to end: real build → real call graph → real live query →
real mismatch → real `isUnknown` in the tool's own actual report. §15.3's fix design, verified against
three independent real examples now (not two, not just Apple's own types), is not a narrow patch for one
SDK peculiarity — it is a general fix for a real, reproducible ClangImporter/sourcekitd interop seam.
This mini package (kept at `/Users/ab/.claude/jobs/eb8b802b/tmp/MiniUSRRepro/` for now, not yet added to
this repository's own fixtures) is also a **far cheaper regression-test candidate** than the real
`lsboutique` corpus §§1-14 relied on — a real end-to-end assertion against it (build, run
`swift-isolation-map`, assert the edge resolves once §15.3 ships) would run in seconds, not the
15-30-minute `--force-reindex` cycles this whole investigation had to repeatedly pay.

## 17. Shipped — DONE

§15.3's design implemented exactly as specified, no deviation: `Sources/SourceKitDIntegration/
BridgedExternConstantMatching.swift` (the grammar parser + four-part matching criterion, both pure and
directly unit-tested — `Tests/SourceKitDIntegrationTests/BridgedExternConstantMatchingTests.swift`, 15
tests, including all 22 real `NSAttributedString.Key` members from §15.1 and the real `MiniAttrKey`
shape from §16), wired into `ExternalIsolationBackfill.query()` as a fallback tried only after
`USRMatching.select`'s own strict equality has already returned `nil` — `USRMatching` itself is
untouched, per its own binding "strict equality only" design. Two new integration tests in
`ExternalIsolationBackfillTests.swift` cover the real motivating case (`.font`, resolves via the
fallback) and the negative case (wrong container type, correctly rejected, stays `unknown`). Full suite:
368/368 passing (was 353; +15).

**Real, measured impact against the same `lsboutique` corpus this whole investigation used:**
- **The `NSAttributedString.Key` family's own `isUnknown` count: 1007 → 0.** Every real member this
  document confirmed (§1's full 22-member list) now resolves correctly — spot-checked directly:
  `.font`/`.kern` both now show `"isolation": "nonisolated"` in the real report, a correct, real fact
  (a plain Clang extern constant genuinely carries no isolation attribute), not a fabricated answer —
  resolved through the same, unmodified `SymbolGraphIsolationParser` path a strict USR match would have
  used.
- The report's other aggregate numbers (`typesAnalyzed`, `crossActorBoundaries`, etc.) shifted by more
  than this fix alone would explain — real, visible build errors in a `Pods` dependency
  (`SwiftRichString`, present in every run this whole session, not new) make this corpus's own build
  state non-fully-deterministic run to run. The family-specific count above is the one number directly,
  unambiguously attributable to this change; the aggregate deltas are not claimed as a clean
  before/after here for that reason.

PR: [#86](https://github.com/btctcn/swift-isolation-map/pull/86).
