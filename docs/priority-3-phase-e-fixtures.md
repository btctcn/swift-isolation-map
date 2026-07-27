# Priority 3, Phase E — golden fixture matrix (decision record)

Per the implementation plan's Phase E. `Tests/Fixtures/compiled-dependency/` — a real, purpose-
built out-of-tree compiled dependency (`ExternalDep`, built fresh by the test itself, never
pre-built/committed) plus the analyzed project (`Consumer`), covering the whole matrix the
research thread proved out. This phase found several real, load-bearing bugs no amount of design
review or unit testing in isolation would have caught — only running the whole pipeline together,
for real, against a real fixture did.

## Fixture design

- `ExternalDep/Sources/ExternalDepCore/` (no `-enable-library-evolution`, genuine case 4, zero
  `.swiftinterface` confirmed by the test itself): `IsolatedRoot`/`InferredChild` (attribute-less
  inheritance), `DivergentIsolation` (member/type divergence), `PlainNonisolated` (negative
  control).
- `ExternalDep/Sources/ExternalDepDefault/` (separate target, `-default-isolation MainActor`):
  `ModuleDefaultIsolated`.
- Mechanism A and B deliberately do **not** use a synthetic dependency — `Consumer` subclasses
  real SDK types directly (`AppKit.NSCell`, `SwiftUI.View`), matching the research spike's own
  approach and avoiding reinventing what real Apple frameworks already provide as ground truth.
- `Consumer/Package.swift` wires to `ExternalDep`'s build output via `unsafeFlags`, with absolute
  paths computed from the manifest's own `#filePath` (a relative path would resolve against
  whatever working directory happens to invoke the build, not reliably this file's location).

## A real, structural bug found only by running the whole pipeline together

The very first end-to-end run against this fixture failed **every single query** with
`sourcekit: error creating ASTInvocation: error: unknown argument: '-frontend'` (and a dozen
further flags). Root cause: `sourcekitd`'s `key.compilerargs` must be **driver**-level (`swiftc`)
arguments; `ProjectResolution.CompilerArgsLogParser`'s real, faithful capture of `swift build -v`
output is a **frontend**-level (`swift-frontend -frontend -c -primary-file ...`) invocation --
correct and faithful to what the real build actually ran (that was always the intent, per Phase
A's decision record), but never valid input for `key.compilerargs` directly. Phase A's own unit
tests validated the parser's extraction in isolation; Phase B's own unit tests validated the
`sourcekitd` client against hand-constructed, already-driver-style simple arguments; neither ever
exercised the two *together* until this phase's real fixture did. **This is exactly the kind of
integration gap unit tests in isolation cannot catch, regardless of how thorough each one is.**

Fixed by `Sources/SourceKitDIntegration/CompilerArgumentsSanitizing.swift`: an empirically-derived
(from the real error message, not guessed from documentation) denylist of frontend-only flags,
applied once, right before a cursor-info request is built (`ExternalIsolationBackfill.query`).
`-primary-file <file>` is handled specially -- the flag is dropped but its value is kept as a bare
positional, since real captured output shows every *sibling* file already listed the same way,
turning the line into exactly what a plain driver-level `swiftc file1.swift file2.swift ...
-flags` invocation looks like. After this fix, the same fixture resolved 8 of ~10 edges correctly
on the first subsequent run, with the remainder correctly `unknown` (see below), not silently
wrong.

## Ground-truth check corrections, found by re-running paired proofs and not accepting a first
## surprising result at face value

Two proofs failed on the first attempt, for real, distinct, instructive reasons -- not because the
tool was wrong, but because the *proof itself* needed correcting, per this project's own
established "verify empirically, don't assume" discipline applied to the test code, not just the
tool:

1. **Mechanism A's proof initially expected a hard compile error; the real ground truth is a
   warning.** `xcrun swiftc -typecheck` on a nonisolated call into an `NSCell`-inherited
   `@MainActor` method exits `0` (not an error) under both `-swift-version 5` and `6`. Root cause,
   confirmed against the same `TypeCheckConcurrency.cpp` source read during the earlier research
   thread: `addAttributesForActorIsolation`'s `GlobalActor` case calls
   `markAsPreconcurrencyIfApplicable` when the inferred isolation is itself preconcurrency-tagged
   -- Apple's own UIKit/AppKit `@MainActor` adoption is treated leniently (warnings, not errors)
   for migration compatibility with the vast amount of pre-Swift-6 SDK-consuming code, even under
   complete/Swift 6 checking. **This does not mean the isolation is fake** -- the tool's `high`
   risk classification for this edge is correct, matching the real, inferred isolation the
   compiler itself reports (`"main actor isolation inferred from inheritance from class
   'NSCell'"`, present in the real warning text) -- only the *enforcement severity* differs from
   the pure-Swift cases. Fixed by checking for the specific diagnostic text at exit code `0`,
   not asserting a nonzero exit code.
2. **Mechanism B's proof initially tested construction (`GroundTruthView()`); the real isolated
   requirement is `.body`, not the initializer.** Already known and correctly handled in the
   fixture's own comments (`MechanismB.swift`) from when this was first discovered while writing
   it -- a plain struct's synthesized memberwise initializer does not itself inherit the `View`
   protocol's `@MainActor` isolation -- but the *ground-truth proof* in the test file repeated the
   same mistake independently before being caught. Fixed by testing `.body` access instead
   (confirmed to produce a real error: `"non-Sendable type 'some View' of property 'body' cannot
   exit main actor-isolated context"` -- a Sendable-crossing error, not literally "main actor-
   isolated", but still definitive proof the property is MainActor-isolated).

Both corrections are real findings about Swift's actual concurrency-checking behavior, not test
authoring mistakes to shrug off -- documented here so a future session doesn't re-litigate them
from scratch.

## A real, second integration bug: mangled-USR substring matching is not reliable

The first passing-but-fragile version of this test matched edges by checking whether a human-
readable type name (e.g. `"ModuleDefaultIsolated"`) appeared as a literal substring of the edge's
(mangled) USR. This silently failed for `ModuleDefaultIsolated` specifically: Swift's name-
mangling compression reuses substrings shared with the enclosing module name
(`ExternalDepDefault` already contains `"Default"`), so the mangled USR
(`s:18ExternalDepDefault06ModuleC8IsolatedCACycfc`) does **not** contain the literal substring
`"ModuleDefaultIsolated"` contiguously, even though the demangled name is exactly that. Every
*other* type in this fixture happened not to share a substring with its own module name, so this
bug was invisible until this one specific case. Fixed by looking up each USR robustly via the
report's own `nodes` list (matched by the human-readable `name` field, which the tool already
reports correctly) rather than ever guessing at mangled-name substrings -- the durable lesson:
**never match a Swift USR by substring search; always resolve it through a real lookup.**

## `unknown`, confirmed real and naturally-occurring, not contrived

`cell.title = "x"` (an ObjC-bridged property set) resolves to a genuinely `unknown` edge: cursor-
info at that position resolves to the *property*'s own USR, not the synthesized
`setTitle:`-selector setter's distinct USR the call graph tracks -- the same class of granularity
mismatch `docs/priority-3-phase-c-oracle-triggers.md` already found and documented for
`Counter.value`'s accessors. Confirmed `risk == .medium` (not `.high`) here specifically, because
an unknown endpoint always resolves through `.unspecified`, which the *existing*, unmodified risk
formula's `.high` branch structurally excludes (`isIsolated(.unspecified) == false`) -- meaning
the plan's originally-envisioned "deliberately broken oracle, edge excluded from
`highRiskBoundaries`" scenario is not naturally reproducible via an edge-level failure in this
fixture at all. The formula-level guarantee (an edge whose *raw* risk would read `.high` is still
excluded from `highRiskBoundaries` when `isUnknown`) is instead verified directly, with hand-
constructed data modeling the declaration-level-trigger-failure case specifically (where the
affected USR *does* still resolve to a real, non-`.unspecified` isolation via the engine's own
existing fallback), in `AnalysisReportBuilderTests.swift`.

## Status

Full suite green (183/183, `swift test -c release`), verified non-flaky across three consecutive
runs. `ExternalDep/build/` gitignored (built fresh every test run, binary artifacts vary by
toolchain). Not yet exercised: a real synthesized-extension member (the `"::SYNTHESIZED::"`
USR-suffix rule) -- the pure-logic `USRMatching` unit test (Phase B) covers the string rule in
isolation, but no real cursor-info query in this fixture has hit a genuine synthesized-extension
member. Deferred as a known, documented, low-risk limitation, per this project's "close what's
closable, document the rest" discipline -- revisit if Phase F's real-world re-run surfaces one.
