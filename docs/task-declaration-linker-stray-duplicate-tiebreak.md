# Investigation: issue #123 — `DeclarationLinker`'s same-USR merge has no tie-break defense

**Status: fixed at the root cause.** `DeclarationLinker.merged(_:_:)` now prefers whichever
candidate's file has real indexed symbols when choosing the merged declaration's `location`,
instead of an unconditional `existing.location ?? incoming.location` that silently depended on
file-processing order.

## The gap, as documented before this fix

`docs/task-own-module-declaration-gaps.md` §4 found a real, confirmed Project Iris case: a stray
Finder-duplicate file (`SubscriptionNotifCell 2.swift`) alongside the real
`SubscriptionNotifCell.swift`. `SyntaxAnalysis.DeclarationVisitor` runs once per file independently,
so *both* contribute a `DeclarationInfo` for the same type, and `DeclarationLinker`'s merge-by-USR
step combines them into one entry. The merged entry's `location` ended up pointing at whichever file
happened to be processed first -- in practice, a plain lexical file-path sort, where
`"SubscriptionNotifCell 2.swift"`'s own leading space (`0x20`) sorts before `.swift`'s `.` (`0x2E`).
A live oracle query against that location then failed with `argumentsNotFound` (the stray file was
never part of any real build target), and `applyDeclarationLevelOutcomes`'s `.unknown` branch swept
in every member whose `containingTypeUSR` matched -- including ones that would otherwise resolve
correctly. That doc's own conclusion: fixing this would need to "prefer a merge candidate location
whose file `compilerArguments` can actually resolve," not attempted at the time since `
DeclarationLinker` has no dependency on `CompilerArgumentsProviding` at all -- adding one would be a
real architectural change, and a live per-candidate resolvability check changes this module's
current zero-query cost model.

## The fix: reuse `filesWithIndexedSymbols`, already computed for an analogous purpose

`DeclarationLinker.link(_:)` already computes `filesWithIndexedSymbols` -- "every file the real
index actually has *any* symbol for" -- for an unrelated guard (`rewrittenReference`'s own defense
against a same-named-but-unrelated type in an uncompiled sibling-platform file, the Swiftfin
`GestureView`/tvOS shape). A stray, never-compiled duplicate file has, by construction, zero real
indexed symbols -- exactly the same signal the doc's own proposed fix wanted from a live
compiler-arguments lookup, already available with no new dependency and no live query at all.

`merged(_:_:filesWithIndexedSymbols:)` (new optional parameter, default `[]` so the many existing
unit tests that only exercise unrelated fields need no changes) now resolves the `location` tie via
a new `preferredLocation` helper: if exactly one candidate's file is in `filesWithIndexedSymbols`,
that one wins, regardless of which side is `existing`/`incoming`. If both or neither side is
indexed, falls back to the original, unconditional `existing.location ?? incoming.location` --
covering both the legitimate cross-file case (`docs/task-cross-file-type-entry-collision.md`: a
primary declaration in one file, an extension in another; only one side ever really has a location
there per that fix's own doc comment) and the degenerate case of two stray files coincidentally
sharing a USR (indexing can't distinguish them either -- no worse than before this fix).

## Verification

Three new tests added to `Tests/IndexStoreIntegrationTests/DeclarationLinkerUnitTests.swift`:
- `mergedPrefersIndexedLocationOverUnindexed`: direct `merged(_:_:filesWithIndexedSymbols:)` check,
  both `(stray, real)` and `(real, stray)` orderings.
- `mergedFallsBackToExistingWhenIndexingStatusMatches`: confirms the fallback-to-`existing` behavior
  is unchanged when indexing status doesn't distinguish the two sides (both indexed, or neither).
- `linkPrefersIndexedFileOverStrayDuplicate`: a full `link(_:)` integration test reproducing the real
  Project Iris shape directly (`SubscriptionNotifCell.swift`/`SubscriptionNotifCell 2.swift`, stray
  file listed *first* in `ExtractionResult.declarations` to confirm the fix isn't itself order-
  dependent in the other direction).

`swift test`: 596/596 passing (593 pre-existing + 3 new). No full Project Iris before/after run --
the 22 real stray files that originally exposed this gap were already removed from the corpus as
data hygiene (`docs/task-own-module-declaration-gaps.md` §4/§5), so the live corpus no longer
contains an instance of the triggering condition to observe a live before/after against; this fix is
a defense against *future* stray files, verified directly via a unit test reproducing the exact
historical shape instead.
