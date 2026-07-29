# Research task: should `Pods`/`Carthage` sources stay in scope?

**Status: research task, not a decision. Deferred out of Gap B by explicit user instruction
("Пока оставь как есть. Оформи на это задачу на исследование") — recorded here as its own,
separate, small note per that instruction, not blocking Gap B and not a Gap B fix.**

## Background

`Sources/swift-isolation-map/StalenessOrchestration.swift`'s `swiftFiles(under:fileSystem:)`
recursively walks the project root looking for `.swift` files, skipping only
`skippedDirectoryNames = [".build", ".swiftpm", ".git", "DerivedData"]`. `Pods` and `Carthage` are
**not** in this list — confirmed by direct reading, not assumed. This is a real, pre-existing,
deliberate "safe-by-default (over-inclusive)" design choice (see the function's own doc comment),
not an oversight, and it predates the Gap B work entirely.

Confirmed, real consequence on `Project Iris` (2209 Swift files, 46007 linked declarations): the corpus
visibly includes CocoaPods source checkouts as project files — e.g. declaration USRs with
`s:10Kingfisher…`/`s:9Alamofire…` prefixes appear directly in the extracted/linked declaration set,
alongside the app's own `Ls_net_ru`-prefixed module. This inflates:

- The total declaration count (`46007`, not just the app's own code).
- The declaration-level oracle-trigger corpus, since Pods sources have their own inheritance
  clauses (superclass/protocol references) that go through the exact same Gap B resolution path as
  the app's own code.

## Why this wasn't decided as part of Gap B

Gap B's own fixes (Phase I1-I3: placeholder normalization, `.baseOf`-relation-based USR
resolution, per-member dedup) apply uniformly regardless of whether a declaration's source file is
under `Pods/` or the app's own directory — the fix is correct either way, and does not depend on
resolving this scope question. Whether analyzing Pods/Carthage source *should* happen at all is a
product decision (does the user want isolation analysis of their dependencies' internals, or only
their own app code depending on already-known dependency facts?), not a correctness bug — hence
explicitly deferred, not bundled into Gap B's Definition of Done.

## What would decide this, one way or the other

1. **Re-run the same diagnostic instrumentation this project already uses** (env-gated
   short-circuit + hit/miss counters in `ExternalIsolationBackfill`'s two trigger loops) against
   `Project Iris` twice: once as-is (Pods in scope, today's default) and once with a temporary
   `Pods`/`Carthage` exclusion added to `skippedDirectoryNames`, to put a real, measured number on:
   - How much of the 46007 declaration count Pods/Carthage sources contribute.
   - How much of the declaration-level oracle-trigger volume (currently ~3388 triggers / ~3262
     distinct (nominal, protocol) pairs post-Gap-B, see `docs/task-gap-b-implementation-plan.md`)
     they contribute.
   - Whether excluding them changes any `highRiskBoundaries`/`crossIsolationEdges` results for the
     *app's own* code (it shouldn't, if Pods' declarations were never load-bearing for the app's
     own isolation facts — but this should be verified, not assumed).
2. **Decide, explicitly, with the user**: analyze Pods/Carthage sources (yes/no/flag), based on
   what the measured numbers above show and what the user actually wants out of this tool for a
   CocoaPods-based project. A `--skip-pods`/`--include-pods` flag is one plausible shape if the
   answer turns out to be "it depends on the invocation," but that's an implementation detail to
   decide only after the scope question itself is settled.

## Explicitly out of scope for this note

- Implementing any exclusion logic — this note only frames the question and how to measure it.
- Any change to `StalenessOrchestration.swiftFiles` or `skippedDirectoryNames` — today's inclusive
  default stays exactly as-is until a decision is made.
