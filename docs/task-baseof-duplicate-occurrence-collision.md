# Real-world audit against Project Iris: a genuine `DeclarationLinker` bug, and a known closure-attribution gap

A full, real, end-to-end run against Project Iris (see `docs/reference-project-corpora.md`) — real
`xcodebuild`, real index store, real external oracle, full report — surfaced 576 high-risk
cross-isolation boundaries. Manually auditing them against real source and the real compiler (per
this project's own "never trust a finding without verifying it" discipline) found two distinct,
real things: one confirmed bug in this tool, now fixed; one confirmed, documented limitation, not
yet fixed.

## Finding 1 (fixed): a duplicate `.baseOf` occurrence was treated as a false ambiguity

**Symptom**: `SomeViewController: UIViewController` (a real, direct SDK subclass in Project Iris)
resolved as `nonisolated` — including its own `override func viewDidLoad()` — instead of inheriting
`@MainActor` from `UIViewController`, unlike other, structurally similar subclasses in the same
project (e.g. one extending `UITabBarController`) which resolved correctly.

**Root cause, confirmed against the real index store** (not guessed): `IndexStoreClient.baseTypeUSRs(forUSR:)`
can report one real base type *twice*, with the exact same USR both times —
confirmed via a direct query against Project Iris's own real index store, which returned
`[(usr: "c:objc(cs)UIViewController", name: "UIViewController"), (usr: "c:objc(cs)UIViewController", name: "UIViewController")]`
for this exact class. `DeclarationLinker.resolveInheritanceViaBaseOfRelation`'s
`baseTypeNames(forNominal:)` (Gap B Phase I2, `docs/task-gap-b-implementation-plan.md`) treated any
*repeated name* as a same-bare-name collision (its original, correct purpose: distinguishing two
genuinely different real types that happen to share a bare name, e.g. `ModuleA.Foo`/`ModuleB.Foo`) —
without checking whether the USR backing the repeated name was actually different. A harmless,
verbatim-identical duplicate occurrence was silently treated the same as a genuine ambiguity, and
the whole name was dropped rather than resolved.

**Fix** (`Sources/IndexStoreIntegration/DeclarationLinker.swift`): a collision is now only recorded
when the same name maps to two *different* USRs:

```swift
for candidate in indexStore.baseTypeUSRs(forUSR: nominalUSR) {
    if let existingUSR = byName[candidate.name] {
        if existingUSR != candidate.usr {
            collidedNames.insert(candidate.name)
        }
    } else {
        byName[candidate.name] = candidate.usr
    }
}
```

**Verification**:
- New unit test, `baseOfResolutionDedupesIdenticalDuplicateEntry`
  (`Tests/IndexStoreIntegrationTests/DeclarationLinkerUnitTests.swift`) — a canned duplicate
  `(name, USR)` pair now resolves; the existing genuine-collision test
  (`baseOfResolutionSkipsSameBareNameCollision`, two *different* USRs sharing a name) still
  correctly skips, confirming the fix didn't loosen the real ambiguity guard.
- Live re-verification against Project Iris's own real index store and real source file (a cheap,
  throwaway probe: real `DeclarationExtractor` + real `DeclarationLinker` against the already-built
  index store, no full rebuild) — before the fix: `superclassUSR` stayed an unresolved
  `syntactic:UIViewController` placeholder; after the fix: resolves to the real
  `c:objc(cs)UIViewController` USR, and (with `UIViewController`'s own known-correct `@MainActor`
  resolution injected the way `ExternalIsolationBackfill` would) both the class and its
  `viewDidLoad` correctly resolve to `globalActor(MainActor)`.
- Full `swift test -c release`: 248/248 passing.

**Severity note**: this bug caused *silent under-reporting*, not over-reporting — an affected class
never appears as a "high-risk boundary" caller at all (it's misclassified as safely `nonisolated`),
so real risk was being hidden, not falsely flagged. The scope of how many other Project Iris
declarations were affected by this exact duplicate-occurrence shape wasn't separately measured; a
re-run after this fix lands would be the way to quantify it. **Still not quantified as of
2026-08-29** -- no later document appears to have run that measurement.

## Finding 2 (known limitation at the time -- since fixed by issue #33/PR #43): closure-level re-isolation isn't tracked

**Update (2026-08-29): this limitation was fixed two days after this document was written.**
`docs/task-closure-isolation-attribution.md`'s Rule A (issue #33, merged as
[#43](https://github.com/btctcn/swift-isolation-map/pull/43), 2026-08-05) recognizes exactly this
shape -- a call physically inside `Task { @MainActor in ... }` is now attributed to the closure's
own isolation, not the enclosing method's. Left below unedited as the original finding.

**Symptom**: `Cart.updateCartCounter()` (project-local, genuinely `nonisolated`) was flagged as a
high-risk caller into `CartFinalizeView.show()` (`@MainActor`). Reading the real source showed the
call is physically inside `Task { @MainActor in ... }` — a real, safe MainActor hop. Confirmed
empirically: a faithful reduction of this exact shape produces **zero diagnostics** under both
`-swift-version 6` and `-swift-version 5 -strict-concurrency=complete`.

**Root cause**: `IndexStoreDB`'s `.calledBy` relation attributes a call site to the nearest
*named* enclosing declaration — anonymous closures (`Task { @MainActor in ... }`) have no index
symbol of their own, so the call graph edge's caller is `updateCartCounter` itself, with no way to
see that this particular call is protected by an inner, explicitly-isolated closure. This is a
structural limitation of the index data this tool consumes, not a logic bug in
`IsolationInferenceEngine`.

**Not fixed here**: detecting this pattern would need real `SwiftSyntax`-level tracking of isolated
closure literals (`Task { @MainActor in }`, `MainActor.run { }`, and similar) and re-attributing
call sites textually inside them — a real feature, not a one-line fix, out of scope for this pass.
Left as a known, documented false-positive source: any `nonisolated` caller wrapping a call in an
isolated closure will show up as a high-risk boundary that isn't actually one.

## What this means for reading Project Iris's own high-risk-boundary count

Of the 247 high-risk edges in Project Iris's own app code (excluding vendored Pods and test
targets): the dominant pattern (~250 edges, e.g. router/handler methods calling
`UINavigationController.pushController` or similar `@MainActor`-inherited UIKit methods directly,
synchronously, no `Task`/`await`) was spot-checked against the real compiler and **confirmed real** —
these would genuinely fail to compile under Swift 6 strict concurrency, exactly the migration risk
this tool exists to surface. Finding 2's closure-attribution gap means some smaller, not yet fully
quantified fraction of the remainder are false positives of that specific shape. Finding 1's fix
means the *true* count, after a fresh re-run, is expected to go *up*, not down — some real risk
that was being silently hidden should now surface.
