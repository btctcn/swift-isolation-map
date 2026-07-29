# Cross-file type-entry collision: a type's own extension in a *different* file can silently overwrite its primary declaration's own facts

**Status: CLOSED this session.** Implemented, tested (235/235 `swift test -c release`), and
measured against the real `Project Iris` corpus -- see section 4 for the real before/after numbers. Found
while manually explaining one specific `Project Iris` high-risk finding to the user
(`AppDelegate.swift:69`, `docs/task-external-type-extension-isolation.md`'s PR), not something
either that fix or Gap B set out to find. Confirmed **pre-existing** (the exact mechanism has been
in `DeclarationLinker.link(_:)` since Priority 2 Phase 3, unrelated to this session's Gap B or
extension-of-external-type work) and **real** (reproduced and explained on a real, in-the-wild
case, not hypothesized).

## 1. The real, motivating example

`Project Iris/AppDelegate.swift`:

```swift
@UIApplicationMain
class AppDelegate: MindboxAppDelegate, InAppMessagesDelegate {
    ...
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?)
    -> Bool {
        super.application(application, didFinishLaunchingWithOptions: launchOptions)
        ...
    }
}
```

A real `Project Iris` analysis run (post extension-of-external-type fix) reports `AppDelegate.swift:69`
(the `super.application(...)` call) as a confirmed high-risk edge: `AppDelegate`'s own method
resolves `.nonisolated`, calling into `MindboxAppDelegate`'s (a real, Pods-source, `@MainActor`-
resolving) same method. But `AppDelegate: MindboxAppDelegate` is a **direct superclass
relationship** -- per SE-0316, `AppDelegate` should inherit `MainActor` from its own superclass,
exactly the mechanism Gap B's `.baseOf`-relation fix already closed for this exact shape. The
report's own `nodes` array shows why it didn't:

```json
{"isolation": "nonisolated", "location": {"file": "", "line": 0}, "name": "AppDelegate", "usr": "c:@M@Ls_net_ru@objc(cs)AppDelegate"}
```

**`AppDelegate`'s own node has an empty location.** `AppDelegate`'s real primary declaration is a
normal, ordinary top-level class in a normal file -- an empty location can only mean the *real*,
richly-populated `DeclarationInfo` for this class (superclass `MindboxAppDelegate`, its real file/
line, its own conformances) was silently replaced by an empty, synthetic-looking one somewhere in
linking, before the isolation engine ever saw it.

## 2. The confirmed mechanism (traced directly, not guessed)

`grep -rn "extension AppDelegate" Project Iris` finds **two** extensions of `AppDelegate`, in two
different files:

```
Project Iris/AppDelegate.swift:364:extension AppDelegate: ProductNotificationSchedulerDelegate {
Project Iris's test target/AppDelegateGiftCertificateEdgeCasesTests.swift:258:extension AppDelegate {
```

The second one is in a **different file** from `AppDelegate`'s own primary declaration. This is
the exact shape that exposes the bug:

1. **`SyntaxAnalysis/DeclarationExtractor.swift` runs per-file, independently.** For
   `AppDelegate.swift` itself, `TypeIndexBuilder`'s per-file pass merges the primary declaration
   *and* the same-file `extension AppDelegate: ProductNotificationSchedulerDelegate` into one
   `TypeIndexEntry` (this same-file merge already works correctly -- confirmed by reading
   `TypeIndexBuilder`'s `ExtensionDeclSyntax` handling, which reuses the *same* per-file
   dictionary key). The resulting `DeclarationInfo` for `"AppDelegate"` has a real location
   (`hasPrimaryDeclarationInFile: true`), `superclassUSR` pointing at `MindboxAppDelegate`'s own
   placeholder, and conformances including `ProductNotificationSchedulerDelegate`.
   For `AppDelegateGiftCertificateEdgeCasesTests.swift`, a **separate, independent** call to
   `DeclarationExtractor.extractWithContext` sees only `extension AppDelegate { ... }` -- its own
   `TypeIndexBuilder` pass, knowing nothing about the other file, produces its **own**,
   **separate** `DeclarationInfo` for `"AppDelegate"`: `hasPrimaryDeclarationInFile: false`,
   `location: nil`, `superclassUSR: nil`, empty conformances (this specific extension adds no
   inheritance clause of its own).
2. **Both placeholders are the exact same string, `"syntactic:AppDelegate"`** (top-level, bare
   name, `SyntacticIdentity.typeUSR(_:)`'s output for a one-element path) -- `DeclarationExtractor`
   has no notion of other files, so it cannot know these two per-file entries describe the same
   real type.
3. **`DeclarationLinker.buildUSRRewriteMap`'s location-based matching correctly resolves both to
   the same real USR** (`c:@M@Ls_net_ru@objc(cs)AppDelegate`) -- the primary file's entry has a
   real location to match against; the test file's entry, though it has no location of its own,
   shares the identical placeholder *string* as its dictionary key, so `usrRewriteMap
   ["syntactic:AppDelegate"]` is populated once (from the primary file's successful match) and
   `rewritten(_:)` returns that same real USR for *both* entries when each is separately looked up.
4. **`DeclarationLinker.link(_:)`'s main `byUSR` construction loop is a plain overwrite, not a
   merge** (`Sources/IndexStoreIntegration/DeclarationLinker.swift`, confirmed by direct reading):
   ```swift
   var byUSR: [String: DeclarationInfo] = [:]
   for declaration in allDeclarations {
       let linked = DeclarationInfo(usr: rewritten(declaration.usr), /* ...fields from `declaration`... */)
       byUSR[linked.usr] = linked
   }
   ```
   Both the primary file's rich `AppDelegate` entry and the test file's empty one get rewritten to
   the identical real key `c:@M@Ls_net_ru@objc(cs)AppDelegate` and inserted into the same
   dictionary under that key -- **whichever is processed last in `allDeclarations` (order
   determined by file-processing order, not by which entry is more complete) silently wins**,
   discarding the other's facts entirely. When the empty one wins, `AppDelegate` loses its own
   `superclassUSR` (`MindboxAppDelegate`), its conformances, and its location -- exactly the
   symptom observed.

**This is a distinct bug from the "known, documented limitation" `DeclarationLinker.swift`'s own
header comment already describes.** That comment covers a type with *no* primary declaration
among the linked files at all (multiple extension-only fragments overwriting each other, all
equally uninformative -- a real but lower-stakes case, since none of them had anything to lose).
Here, the primary declaration *is* among the linked files, and the collision can overwrite its
*rich* entry with an *empty* one from an unrelated file -- corrupting an otherwise fully-resolvable
type's own isolation resolution, not just failing to improve an already-unresolvable one.

**Confirmed pre-existing, not introduced this session**: `byUSR[linked.usr] = linked` has been the
construction shape since Priority 2 Phase 3 (`DeclarationLinker`'s original creation); Gap B and
the extension-of-external-type fix both added *new passes that run after* this loop, neither
touches this loop itself. Also explains an observed oddity from that fix's own before/after diff:
one specific edge in `AppDelegateGiftCertificateEdgeCasesTests.swift` (line 262 in one run) was
"fixed" while a *different* line in the same file later showed up elsewhere across runs --
consistent with `allDeclarations`' file-processing order (hence which entry "wins" the collision)
not being perfectly stable run to run, rather than a real difference in behavior.

## 3. Scope: how much of the real corpus is affected?

**Measured, real, before any fix existed.** Any project-local type with **both** a primary
declaration **and** at least one extension in a **different file** is a candidate -- a common,
ordinary Swift pattern (splitting a type's protocol-conformance implementations into separate
files by concern, exactly what `AppDelegate.swift`/`ProductNotificationSchedulerDelegate` and the
test target's own extension both do). A precise query against the already-captured real `Project Iris`
report (project-local USR prefix, empty `location`, and `name != usr` -- the last condition rules
out `ExternalIsolationBackfill`'s own, unrelated synthetic entries, which always set `name` equal
to the USR string itself) found **13 real project-local types** losing their own rich entry to an
empty one from an unrelated file, including `AppDelegate` (`MindboxAppDelegate` superclass link
lost) and `NotificationsListViewController` (a type this same session's earlier Gap A/B work also
touched, coincidentally). This is the pre-registered baseline the fix (section 5) is checked
against.

## 4. Fix design

The right shape is a **merge**, not the current overwrite, applied only when two entries
collide on the same real (already-rewritten) USR key -- normal, non-colliding entries are
unaffected. Field-by-field, informed by what can *actually* differ between two per-file
`DeclarationInfo`s describing the same type (confirmed by reading `DeclarationExtractor.swift`'s
own construction of each field, not guessed):

- `usr`, `name`: identical by construction (same key, same type).
- `explicitIsolation`: at most one file's entry can ever carry this in practice (an explicit
  attribute lives on one physical declaration); prefer whichever is non-nil.
- `isActorType`: only `recordPrimaryDeclaration` (the primary file) ever sets this true; prefer
  `true` if either side has it.
- `containingTypeUSR`, `isNestedType`: only meaningful for nested types, and determined by the
  type's own qualified path, which is identical regardless of which file computed it; prefer
  whichever is non-nil (nested-ness can't disagree between two entries of the same type).
- `isStaticMember`: always `false` for a type-level entry on both sides.
- `superclassUSR`: only a primary declaration can state one (`applyInheritance` runs only from
  `recordPrimaryDeclaration`) -- at most one side is ever non-nil; prefer whichever is.
- `conformances`: **concatenate, don't pick one side** -- a real, materially different fact set can
  exist on each side (that's the entire bug: `ProductNotificationSchedulerDelegate` from one file,
  something else from another), and each `ProtocolConformance` already carries its own correctly-
  computed-per-file `declaredInSameFileAsPrimaryDefinition`/`declaredInSameContextAsWitness` flags
  (Rule 7/8 inputs) -- concatenation preserves both without needing to recompute anything.
- `isEligibleForModuleDefaultIsolation`: conservative AND (ineligible if *either* side says so) --
  each side only ever sees its *own* conformances when computing this, so a `Sendable`/
  `SendableMetatype` conformance declared in the *other* file wouldn't be visible to the side that
  didn't see it; ANDing keeps the real SE-0466 exclusion correct regardless of which file the
  disqualifying conformance came from.
- `enclosingExtensionIsolation`: never set on a type-level entry (member-only field); nil on both
  sides by construction, nothing to merge.
- `location`: only the primary file's entry has one; prefer whichever is non-nil.

Implementation shape: after the existing `byUSR` construction loop (or folded into it), detect a
collision (`byUSR[linked.usr]` already exists) and merge into the existing entry via a dedicated
`merged(_:_:)` function encoding the rules above, instead of unconditionally overwriting. Order-
independent by construction (merging is commutative/associative for every field rule above), which
also directly fixes the run-to-run instability noted in section 2.

## 5. Definition of done

1. **Done.** Fixed via `DeclarationLinker.merged(_:_:)` (field-by-field rules per section 4),
   applied on collision in `link(_:)`'s main `byUSR` construction loop instead of the old plain
   overwrite. Verified two ways: a fake-based unit test suite
   (`DeclarationLinkerUnitTests.swift`: `merged(_:_:)`'s own field rules -- non-nil preference,
   conformance concatenation, conservative-AND eligibility -- plus a fake-index integration test
   asserting the merge holds regardless of feeding order) and a real, committed fixture addition
   (`Tests/Fixtures/cross-file-witness/Sources/CrossFileWitness/MultiFileType.swift` +
   `MultiFileTypeExtension.swift`, mirroring the real `AppDelegate`/`MindboxAppDelegate` shape) with
   a live test (`DeclarationLinkerTests.swift`'s
   `linkMergesRealCrossFileTypeAndExtensionRegardlessOfOrder`) confirming `DeclarationLinker.link(_:)`
   produces one merged entry carrying *both* files' facts (superclass, both conformances, and the
   real location) against a real index store, regardless of extraction order.
2. **Done, confirmed by name.** A real `Project Iris` run shows `AppDelegate`'s own node with a real
   (non-empty) location (`AppDelegate.swift:8`), and its own isolation correctly resolves to
   `globalActor(MainActor)` (inherited from `MindboxAppDelegate`). The specific edges at
   `AppDelegate.swift:69,77,100,104` (calls into `MindboxAppDelegate`'s own same-named methods)
   no longer appear as cross-isolation edges at all -- both sides now correctly resolve to the
   same actor, exactly as `IsolationInferenceEngine.crossIsolationEdges()`'s own same-actor filter
   is supposed to do. Lines 76/130/215 still appear, now correctly downgraded from a confident
   false-positive-high-risk to an honest `medium`/`isUnknown: true` (the *callee* side of those
   specific calls remains genuinely unresolved for an unrelated reason -- reported honestly as
   "don't know," not silently assumed safe).
3. **Done, real, measured.** The pre-registered baseline (section 3) was 13 real project-local
   types. After the fix: **0 remaining** (the identical query against the after-fix real report
   finds zero project-local, empty-location, real-named nodes) -- all 13 named cases, including
   `AppDelegate` and `NotificationsListViewController`, confirmed individually resolved with real
   locations and correct isolation. Confirmed high-risk boundaries went from 253 to 289 (net +36:
   17 resolved as genuinely same-actor now, 53 newly surfaced as real, previously-masked risk on
   types whose real superclass/conformance link had been silently destroyed) -- consistent with
   and explained by the exact same mechanism as the extension-of-external-type fix's own
   before/after shape (restoring a lost isolation fact reveals both false positives *and*
   previously-invisible true positives at once).
4. **Done.** Full `swift test -c release`: 235/235 (230 pre-fix + 5 new: 3 pure `merged(_:_:)`
   unit tests, 1 fake-index order-independence integration test, 1 real fixture live test).
5. **Done.** Decision record in `docs/priority-3-compiled-dependency-isolation.md`'s "Cross-file
   type-entry collision fix" section.

## 6. Relevant existing architecture

- `Sources/IndexStoreIntegration/DeclarationLinker.swift` -- `link(_:)`'s main `byUSR`
  construction loop (the exact overwrite to fix), its own header comment's "known, documented
  limitation" (a related but distinct, narrower case, already described, not to be confused with
  this one).
- `Sources/SyntaxAnalysis/DeclarationExtractor.swift` -- `TypeIndexBuilder`'s per-file merge
  (already correct *within* one file; confirms the gap is specifically cross-file), `applyInheritance`
  (confirms only a primary declaration ever sets `superclassCandidateName`), `emitTypeDeclarationIfNeeded`
  (confirms exactly which fields come from where).
- `Tests/Fixtures/cross-file-witness/` -- this project's established real-fixture precedent for
  cross-file linking behavior (Gap A/B, extension-of-external-type all used it); the natural home
  for this fix's own verification fixture too.
- `docs/task-gap-b-implementation-plan.md`, `docs/task-external-type-extension-isolation.md` --
  read for the verify-before-trust discipline and documentation shape this task should follow.

## 7. Explicitly out of scope

- Re-touching Gap A, Gap B, or the extension-of-external-type fix -- all closed, correct,
  unrelated causes.
- The `IsolationInferenceEngine` -- once given one correctly-merged entry per type, it already
  works correctly; this is purely a linking-layer merge gap.
- Any change to `SyntaxAnalysis`'s own per-file extraction -- correct and necessary as-is (it
  cannot know about other files by design); the fix belongs entirely in the cross-file linking
  layer, mirroring Gap B's and the extension-of-external-type fix's own "route through the linking
  layer, not the extractor" precedent.
