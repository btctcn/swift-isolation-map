# Solution design: resolving compiled-dependency isolation via the symbol graph oracle

**Status: proposed solution, grounded in Swift compiler sources (swiftlang/swift `main`,
read 2026-07-26), pending on-machine empirical validation.** This document answers the task
spec in `task-compiled-dependency-isolation.md`. It was produced *without* access to a macOS
toolchain, so instead of the spike the spec asked for, it does the next-strongest thing: it
verifies, in the compiler's own source code, exactly what each candidate oracle can and cannot
emit — and then hands over a ready-to-run spike script (section 6) whose expected outcomes are
now predictions derived from source, not guesses. If the spike contradicts a prediction, the
relevant source citation below is the first place to look for what changed.

## 1. The recommendation, in one paragraph

Use **`swift symbolgraph-extract`** (a standard driver subcommand of every modern toolchain,
backed by the compiler's own `lib/SymbolGraphGen`) as the external isolation oracle. For each
external module the analyzed project actually references, run it once per
(module, SDK, target-triple, toolchain-version) tuple, cache the JSON, and parse it into the
same `DeclarationInfo`-shaped facts the tool already produces for project sources: per-symbol
isolation attributes **plus** `inheritsFrom`/`conformsTo` relationships, keyed by USR. Backfill
these facts at the `DeclarationLinker` layer (the project's existing precedent for exactly this
shape), so `IsolationInferenceEngine` stays untouched and walks external inheritance chains with
the same logic it already applies to internal ones. `sourcekitd` cursor-info (and its
sourcekit-lsp wrapper) is demoted to a *validation/spot-check* oracle — section 3 explains the
structural reason it cannot be the primary one. Any USR still unresolved after backfill must
surface as an explicit `unknown` isolation state, never as the current silent `.nonisolated` —
that closes the epistemic half of the bug independently of coverage.

## 2. Why symbol graphs are the right shape (evidence from compiler sources)

The task's hard requirement is resolving isolation "matching what swiftc itself would enforce,
not an approximation." Symbol graph extraction runs the real compiler frontend — ClangImporter
for ObjC modules, module loading for Swift ones — and then serializes the *typechecked AST*.
Four facts, each verified directly in `swiftlang/swift` sources:

**Fact 1 — ClangImporter attaches `@MainActor` from `NS_SWIFT_UI_ACTOR` as a NON-implicit
attribute.** `lib/ClangImporter/ImportDecl.cpp`, `importSwiftAttrAttributes`: for
`isMainActorAttr(swiftAttr)` it calls
`CustomAttr::create(SwiftContext, SourceLoc(), typeExpr, /*owner*/ MappedDecl)` — and
`include/swift/AST/Attr.h` shows that overload's trailing parameter is `bool implicit = false`.
The imported `@MainActor` is therefore an ordinary explicit attribute on the imported decl.
This single fact is what makes mechanism A (UIKit/AppKit/WatchKit) visible to every
printer-based oracle at all.

**Fact 2 — Symbol graph declaration fragments print attributes, including custom ones.**
`lib/SymbolGraphGen/SymbolGraph.cpp`, `getDeclarationFragmentsPrintOptions()`: sets
`Opts.SkipAttributes = false`, and its `ExcludeAttrList` names only `Available`, `Inline`,
`Inlinable`, `Prefix`, `Postfix`, `Infix`, `AccessControl`, `SetterAccess` —
`DeclAttrKind::Custom` (which is what `@MainActor` is) is **not** excluded.
`Opts.PrintImplicitAttrs = false` is harmless per Fact 1. And
`lib/SymbolGraphGen/DeclarationFragmentPrinter.h/.cpp` define a dedicated
`FragmentKind::Attribute` serialized as `"kind": "attribute"` — so detecting isolation in the
JSON is a structured check on fragment kind + spelling (and, for global actors, the fragment's
`preciseIdentifier` USR), not substring matching on prose.

**Fact 3 — Symbol graphs carry the relationship edges the engine needs.**
`lib/SymbolGraphGen/Edge.h` defines `inheritsFrom`, `conformsTo`, `memberOf` (and more)
relationship kinds; symbol identifiers are USRs (`"precise"`), i.e. the same identifier space
the tool already uses for `declarations[superclassUSR]` lookups and IndexStoreDB linking. A
parsed symbol graph is, almost literally, an externally computed extension of the tool's
existing declarations table.

**Fact 4 — Printed declarations never contain *inferred* isolation, only attached attributes.**
`lib/AST/ASTPrinter.cpp` and the attribute-printing path in `lib/AST/Attr.cpp` contain no code
that synthesizes isolation output from semantic `ActorIsolation`; the only isolation ever
printed on a decl is an attribute physically attached to it (the inheritance-clause printer
handles `@MainActor protocol P` conformance spellings, but nothing consults
`getActorIsolation`). This fact cuts both ways and drives the whole design — see section 3.

## 3. The inferred-isolation trap: why per-symbol hover/cursor-info cannot be the primary oracle

The task spec's leading candidate was sourcekit-lsp hover. Both hover and the underlying
`sourcekitd` cursor-info build their answer with
`PrintOptions::printQuickHelpDeclaration()` (`tools/SourceKit/lib/SwiftLang/
SwiftSourceDocInfo.cpp`, `printAnnotatedDeclaration` / `printFullyAnnotatedDeclaration`), which
by Fact 4 prints only *attached* attributes. Consequences:

- `UITableViewCell` → shows `@MainActor` (attr attached by ClangImporter, Fact 1). ✅
- `SwiftUI.View` → shows `@MainActor` (attr explicit in the module). ✅
- **`SomeThirdPartyView` from a binary framework, declared as `class SomeThirdPartyView:
  UIView` with no explicit attribute** → its MainActor-ness is *inferred* by the compiler from
  the superclass; no attribute is attached; the printed declaration shows **nothing**. ❌

So a per-symbol textual oracle answers correctly only for symbols that happen to carry the
attribute themselves. To be correct in general it must *walk the external inheritance/
conformance chain* — and once relationships are required anyway, the symbol graph provides
declarations + relationships in one batch JSON per module, while cursor-info would require one
synthetic positioned document per queried symbol plus recursive re-querying, re-implementing
the walk badly. The correct division of labor: **the oracle supplies external facts
(attributes + edges); the tool's own, already-tested `IsolationInferenceEngine` performs the
inference over them** — identical to how it already treats project-internal declarations. This
also means external resolution automatically inherits every rule the engine already gets right
(protocol-conformance-beats-default ordering, extension tiers, etc.).

The same trap, for the record, applies to parsing `.swiftinterface` files (mechanism B "by
hand"): interfaces omit inferable isolation because the consumer re-infers it, so a
text-only interface parse has the identical hole — one more reason the original plan to reuse
`DeclarationExtractor` on `.swiftinterface` text is a dead end as a *primary* mechanism.

## 4. Known residual gap the design must handle explicitly: module-default isolation

A dependency compiled with SE-0466/SE-0478 default `MainActor` isolation may contain types whose
isolation comes from *neither* an attached attribute *nor* an isolated root of an inheritance
chain — it comes from the module-wide default. Symbol graphs will show no attribute and no
telling edge (Fact 4 again: the default is inference, not attribute). Handling: the module's
default isolation is recoverable from its `.swiftinterface` header flags
(`// swift-module-flags:` includes `-default-isolation MainActor` when set — verify the exact
spelling in the spike; `-enable-experimental-feature`-era spellings may differ by toolchain),
and the tool's engine already models module-default isolation for project code, so this becomes
one extra per-module input fed into existing logic. For binary-only modules with no interface
(case 4) where the flag can't be read, the module's symbols that resolve to "no attribute, no
isolated ancestor" must stay `unknown`, not `nonisolated` — documented limitation, engine
mechanism already exists.

## 5. Integration design (maps to the spec's Definition of done, point by point)

1. **Import capture.** Extend syntax collection to record each file's `import` statements as
   structured data (spec already points at `FileWideNameCollector` as the likely home). The
   union of imported modules across analyzed files, minus the project's own targets, is the
   candidate external-module set. Only modules that actually *own* an unresolved
   superclass/protocol USR need extraction — resolve USR→module either from the USR itself
   (ObjC USRs like `c:objc(cs)UITableViewCell` need the import set; Swift USRs embed the module
   name in the mangling) or by extracting for each imported module lazily until the USR is found.
2. **SDK/triple resolution.** New, small: resolve `SDKROOT` + target triple (from the scheme's
   build settings via `xcodebuild -showBuildSettings`, with `xcrun --show-sdk-path` fallback) —
   the spec already flags this as new work in `SwiftVersionDetection`'s neighborhood.
3. **Extraction + cache.** `xcrun swift symbolgraph-extract -module-name M -sdk S -target T
   -output-dir D` once per (M, SDK build version, T, toolchain version); content-addressed cache
   directory, consistent with the project's existing content-hash staleness discipline. UIKit's
   graph is large; parse streamed/filtered — the consumer only needs symbols reachable from the
   unresolved-USR frontier plus their ancestor closure, and `memberOf` targets can be dropped
   entirely at parse time.
4. **Backfill at `DeclarationLinker`.** Convert filtered graph facts into the existing
   declaration-table shape: isolation attribute (global actor USR or nonisolated),
   superclass USR, conformed-protocol USRs, plus per-module default-isolation (section 4).
   Inject before inference. `IsolationInferenceEngine` remains untouched — preserving the
   project's standing invariant — and resolves external chains with existing logic.
5. **`unknown` as a first-class outcome.** Any referenced external USR not resolved after
   backfill produces `unknown`, which `AnalysisReportBuilder.riskLevel` must treat as its own
   category (surfaced, counted, never silently promoted to a `high` cross-isolation edge).
   This is the falsifiability guarantee: the tool can no longer *manufacture* confidence.
6. **Golden fixtures** (spec DoD #3): one fixture subclassing `UITableViewCell` (mechanism A),
   one conforming to `SwiftUI.View` (mechanism B), one subclassing a class from a purpose-built
   `.swiftmodule`-only dependency (case 4) whose own superclass chain reaches an isolated root
   *without* the leaf carrying an attribute — that last fixture is the regression test for the
   section-3 trap specifically. Each paired with a `swiftc -typecheck` compile-proof exactly like
   the task spec's `repro2.swift`.
7. **Real-world diff** (spec DoD #4): re-run `Project Iris` (Project Iris's scheme) and `~/SQLumen`
   (scheme `SQLumen`) with `--output json`; diff high-risk findings before/after; every finding
   that disappears must be attributable to a newly resolved external chain, every survivor to a
   genuinely project-internal edge or an explicit `unknown`.

**Case 4 verdict (spec DoD #1/#5):** `symbolgraph-extract` deserializes binary `.swiftmodule`s
directly — that is its normal operating mode when no interface exists — so case 4 is expected
to be *solvable*, with one honest, documentable constraint: binary swiftmodules are only
guaranteed readable by the same toolchain version that produced them. That constraint is
inherited from `swiftc` itself — if the project can build against the dependency, the same
toolchain's extractor can read it — so it is not a new limitation of this tool. The spike must
confirm this on a synthetic no-interface package before the verdict is written into docs.

## 6. The spike, ready to run on the Mac (expected outcomes are predictions from section 2)

```bash
#!/bin/zsh
set -euo pipefail
OUT=/tmp/isolation-oracle-spike; rm -rf $OUT; mkdir -p $OUT

# --- Spike 0: the tool exists in this toolchain (swift-ide-test famously doesn't) ---
xcrun swift symbolgraph-extract --help > /dev/null && echo "OK: symbolgraph-extract present"

# --- Spike A: mechanism A (ObjC-bridged UIKit) ---
xcrun swift symbolgraph-extract -module-name UIKit \
  -target arm64-apple-ios17.0-simulator \
  -sdk "$(xcrun --show-sdk-path --sdk iphonesimulator)" \
  -output-dir $OUT/uikit -pretty-print
python3 - "$OUT/uikit" UITableViewCell <<'PY'
import json, sys, glob
outdir, name = sys.argv[1], sys.argv[2]
for f in glob.glob(outdir + "/*.symbols.json"):
    g = json.load(open(f))
    for s in g.get("symbols", []):
        if s["names"]["title"] == name:
            frags = s.get("declarationFragments", [])
            attrs = [x["spelling"] for x in frags if x["kind"] == "attribute"]
            print(f, s["identifier"]["precise"], "attrs:", attrs)
    for r in g.get("relationships", []):
        if r["kind"] == "inheritsFrom" and name in r["source"]:
            print("edge:", r["source"], "->", r["target"])
PY
# EXPECTED: attrs contains "@MainActor"; inheritsFrom edge to c:objc(cs)UIView.

# --- Spike B: mechanism B (pure-Swift SwiftUI) ---
xcrun swift symbolgraph-extract -module-name SwiftUI \
  -target arm64-apple-macos14.0 \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -output-dir $OUT/swiftui -pretty-print
# Re-run the python filter with module dir $OUT/swiftui and name View.
# EXPECTED: protocol View carries an "@MainActor" attribute fragment.

# --- Spike C: case 4 (.swiftmodule-only, no interface, PLUS the inferred-isolation trap) ---
mkdir -p $OUT/dep/Sources/Dep && cd $OUT/dep
cat > Package.swift <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Dep", products: [.library(name: "Dep", targets: ["Dep"])],
                      targets: [.target(name: "Dep")])
EOF
cat > Sources/Dep/Dep.swift <<'EOF'
@MainActor open class IsolatedRoot { public init() {} }
open class InferredChild: IsolatedRoot {}   // NO attribute; isolation is inferred
EOF
swift build   # no -enable-library-evolution => no .swiftinterface is emitted
MOD=$(find .build -name 'Dep.swiftmodule' -type f | head -1)
xcrun swift symbolgraph-extract -module-name Dep \
  -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -I "$(dirname $MOD)" -output-dir $OUT/dep-sg -pretty-print
# EXPECTED: extraction succeeds from the binary swiftmodule alone (case 4 = solvable);
# IsolatedRoot shows "@MainActor" fragment; InferredChild shows NO isolation attribute but
# an inheritsFrom edge to IsolatedRoot — proving the engine-side walk is what closes the trap.

# --- Spike D (validation oracle only): sourcekit-lsp/sourcekitd hover sanity check ---
# hover on `let c: UITableViewCell` in a scratch iOS file: expect "@MainActor class
# UITableViewCell"; hover on a use of InferredChild: expect NO @MainActor in the printed decl —
# empirically confirming section 3's trap and cursor-info's demotion to spot-check duty.
```

Also verify during the spike: (a) the exact `swift-module-flags` spelling for default
isolation in a `-default-isolation MainActor` build's `.swiftinterface` (section 4);
(b) extraction wall-time and graph size for UIKit on this machine, to size the cache/filter
design; (c) whether ObjC categories' conformances land in `UIKit@X.symbols.json` extension
files and are picked up by the parser.

## 7. Risks and open questions, honestly

- Sources read are `main`-branch; the Xcode 26.4 toolchain may differ in detail. Every claim in
  section 2 is spelled with its source location so drift is checkable in minutes.
- UIKit-scale graphs are large; if extraction time is unacceptable per-run, the cache design
  (step 3) carries the load; a first run on a large project pays a one-time cost per SDK.
- `-minimum-access-level` default is `public`; anything a project can subclass/conform to is
  visible, but `@_spi`/`package` edges should be checked once in the spike if relevant deps use
  them.
- Isolation applied to an external type *via an extension in a third module* is representable
  (extension symbol files) but should get its own fixture before being claimed as covered.
- If any spike expectation fails, fall back to the layered plan: symbol graph for structure +
  sourcekitd cursor-info for leaf attributes — but no such failure is currently predicted.
