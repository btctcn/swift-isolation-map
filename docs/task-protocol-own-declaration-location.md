# A protocol's own type-level declaration gets `location: nil`

Tracks [issue #57](https://github.com/btctcn/swift-isolation-map/issues/57). Found continuing
#55's Step 6 (`docs/task-implicit-synthesized-declarations.md`) -- a third, distinct mechanism
behind the "361 remaining declarations" thread (itself following #53, itself following #51).

**Status: shipped.**

## Step 1 — Hypothesis

Of the 361 declarations still missing after #51/#52/#53's fixes, 57 demangled to bare
protocol/type names -- the protocol itself, not one of its members. Checked `protocol Disposable`
(`lsboutique/Redesign/ToolKit/Disposable/Disposable.swift`) first: only one file in the whole
project declares it, which rules out a #53-style cross-file byte-offset collision outright. Going
in, the hypothesis was "some other IndexStoreDB-load-dependent gap, like #51's own root cause."

## Step 2 — Spike

An isolated single-file extraction of `Disposable.swift` (same "extract this one file, look at the
raw `[DeclarationInfo]`" methodology used throughout #51/#53's own investigations) showed
`Disposable`'s own `DeclarationInfo` has `location: nil` -- *before* any linking against
`IndexStoreDB` even happens. This immediately ruled out #51's mechanism (that was always about the
bulk index *linking* step silently dropping something that extraction got right) -- the bug is
entirely inside `SyntaxAnalysis`, at extraction time.

Read `Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `TypeIndexBuilder.Visitor` (the first
pass, building `typeIndex`, which the main pass's `emitTypeDeclarationIfNeeded` reads
`entry.location` from): its own `visit(_ node: ProtocolDeclSyntax)` only does
`protocolGlobalActorNames[node.name.text] = actorName` -- unlike its `ActorDeclSyntax`/
`ClassDeclSyntax`/`StructDeclSyntax`/`EnumDeclSyntax` handlers, it never calls
`recordPrimaryDeclaration`, the one function that sets `TypeIndexEntry.location`. This is the same
underlying fact #53 already established ("`protocol` never enters `DeclarationVisitor`'s type-scope
stack the way class/struct/enum/actor do") -- but #53 fixed a *different* consequence of it (a
member's placeholder USR discriminator), not this one.

`Disposable.swift`'s real source:

```swift
public protocol Disposable {
    func dispose()
}

extension Disposable {
    public func disposed(by bag: DisposeBag) {
        bag.addDisposable(self)
    }
}
```

The same-file `extension Disposable { ... }` is what actually creates `typeIndex["Disposable"]` --
`visit(_ node: ExtensionDeclSyntax)` does `index[extendedName] ?? TypeIndexEntry()`, entirely
independent of whatever `visit(ProtocolDeclSyntax)` did or didn't do. That stub entry's `.location`
stays at `TypeIndexEntry`'s own default (`nil`), since nothing else ever sets it. Later, while
emitting `disposed(by:)` (the extension member -- the extension correctly pushes `"Disposable"`
onto the main visitor's `path`), `emitTypeDeclarationIfNeeded(qualifiedName: "Disposable")` finds
this stub entry present (`guard ... let entry = typeIndex[qualifiedName] else { return }` only
bails when the entry is *missing*, not when its `location` is `nil`) and emits a `DeclarationInfo`
for `Disposable` anyway -- with `location: entry.location`, i.e. `nil`.

Protocol + same-file default-implementation extension is a common, idiomatic Swift shape, not a
one-off -- explaining why 57 (not a handful) of the remaining 361 are this exact shape.

## Step 3 — Documentation (this document)

## Step 4 — Code

`Sources/SyntaxAnalysis/DeclarationExtractor.swift`'s `TypeIndexBuilder.Visitor.visit(_ node:
ProtocolDeclSyntax)` now also calls `recordPrimaryDeclaration`, mirroring the existing struct/enum
handlers:

```swift
override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
    if let actorName = recognizedGlobalActorAttribute(in: node.attributes, known: fileWideNames.globalActorNames) {
        protocolGlobalActorNames[node.name.text] = actorName
    }
    recordPrimaryDeclaration(nameToken: node.name, isActor: false, isClass: false, attributes: node.attributes, modifiers: node.modifiers, inheritance: node.inheritanceClause)
    return .visitChildren
}
```

No `path` push/pop needed, unlike the class/struct/enum/actor handlers: Swift doesn't allow nesting
a protocol declaration inside another type, so a protocol's own qualified name is always just its
own name -- there's no enclosing scope to track. `isActor: false, isClass: false` routes
`applyInheritance` to treat every inherited name as a conformance (`entry.conformedProtocolNames`),
which is exactly correct for `protocol Foo: Bar` -- protocol inheritance *is* conformance for this
project's purposes, never a superclass relationship.

This is a strictly additive fix: it only changes what happens when a `typeIndex` entry didn't
already exist with a real location (the previous code path already merges into an existing entry
via `index[qualifiedName] ?? TypeIndexEntry()`, so a protocol whose extension is processed *before*
its own declaration in file order, or vice versa, both converge on the same, now-correct, entry).

## Step 5 — Tests

`Tests/SyntaxAnalysisTests/DeclarationExtractorTests.swift`:
`protocolOwnDeclarationHasARealLocation` -- reproduces `Disposable.swift`'s exact shape (protocol +
same-file default-implementation extension) and asserts the protocol's own `DeclarationInfo.location`
is non-nil. Confirmed to fail without the fix (`git stash` on just the source file -- `location`
was `nil`) and pass with it.

Full `swift test -c release`: 298/298 passing (one transient failure on a live-toolchain-dependent
test observed on a single run, not reproduced on immediate re-run -- consistent with #49's
already-documented `IndexStoreDB`/`sourcekitd` non-determinism under load, not this change).

## Step 6 — Documenting results

This fix gives `Disposable`-shaped protocols (protocol + same-file extension, no other file
referencing the protocol name first) a real location, which is a *precondition* for either
resolution path (bulk `usrRewriteMap` or the #51/#52 live fallback) to even attempt resolving them
-- it does not, by itself, guarantee every one of the 57 bare-protocol-name cases now resolves
(some may still fail bulk resolution and require the live fallback; a few may have a different root
cause not yet checked individually). Confirmed directly: `Disposable`'s own node now carries its
real location (`Disposable.swift:1`) instead of `nil`. Re-run against Project Iris, before vs.
after (both after #51/#52/#53's fixes already shipped, so directly comparable):

| | before | after |
|---|---|---|
| Missing app-module declarations (#51's follow-up, most recently "361 remaining") | 361 | **335 (-26)** |
| `highRiskBoundaries` | 933 | **1167 (+234)** |
| `crossActorBoundaries` | 24616 | 24852 (+236) |
| `unspecifiedIsolation` | 1501 | 1501 (unchanged) |
| Total nodes | 51195 | 51095 |

Not every one of the 57 candidates resolved (335 still missing, not 361-57=304) -- consistent with
the note above that some bare-protocol-name cases likely need the live fallback on top of this fix,
or have a distinct root cause not yet individually checked.

**Re-checked 2026-08-29**: no later document in `docs/` mentions this specific 31-declaration
residual (335 vs. the 304 expected) by name or number, and no later PR's own before/after table
references it. Reproducing today's exact figure would require redoing the original methodology in
full (demangle every currently-missing app-module USR, categorize by shape, cross-check each
bare-protocol-name candidate against real source) -- not done as part of this pass, since the
corpus and the tool have both changed substantially since 2026-08-07 (dozens of unrelated
declaration/USR-matching fixes have landed since) and a cheap proxy check isn't available in the
standard JSON output. Left as a genuinely unquantified, low-priority residual -- not reopened as an
issue, since there's no confirmed-current number to point at, only an honest "not reverified."
The `highRiskBoundaries` jump (+234) is
disproportionately large relative to the 26 additional resolved declarations, and that's expected,
not a red flag: a protocol's own identity feeds every conformance/isolation-propagation check for
every type that conforms to it (and every witness that satisfies one of its requirements), so
correctly resolving one protocol the same way it's already used to give one class or struct a real
`highRiskBoundaries` boost (#44's own comparable-shape finding) ripples across every conformer, not
just the protocol's own single node. Same fail-safe direction as every other fix this cycle:
previously-hidden real risk surfacing, not manufactured noise.

## Step 7 — PR

Merged as [#58](https://github.com/btctcn/swift-isolation-map/pull/58).
