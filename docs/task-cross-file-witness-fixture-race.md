# Issue #148: DeclarationLinkerTests/RawIndexStoreClientModuleScopingTests race on the shared `cross-file-witness` fixture's `.build`

**Status: FIXED.**

## Background

Filed as a side effect of investigating issue #142's oracle-query non-determinism (a different,
production-code mechanism -- see `docs/task-swiftpm-compiler-args-retry-threshold.md` and
`docs/task-swiftfin-oracle-nondeterminism-reconfirmation.md`), confirmed 100% pre-existing on
unmodified `main` via `git stash` before being filed separately as its own issue.

`Tests/Fixtures/cross-file-witness` is shared, on disk, by multiple test files. Some of those files
already carry a real fix for this exact problem: `RawIndexStoreClientModuleScopingTests.swift` and
`ExternalIsolationBackfillTests.swift` (both touched most recently in PR #128, which predates this
issue's filing) copy the fixture to a private, per-test, `realpath(3)`-resolved temp directory before
building, rather than building directly into the shared fixture root -- their own doc comments already
name this exact race as the reason. `DeclarationLinkerTests.swift` itself already has *part* of the
same fix: a helper, `copiedCrossFileWitnessFixture()`, used by three of its six tests
(`extensionChainResolvesExternalNestedAndGenericExtendedTypes`,
`linkRewritesExtensionMemberContainingTypeUSR`,
`linkMergesRealCrossFileTypeAndExtensionRegardlessOfOrder`).

The remaining three tests in that same file --
`crossFileProtocolWitnessResolvesCorrectly`, `owningPropertyUSRMapsRealAccessorToItsProperty`, and
`baseTypeUSRsResolvesRealSupertypesIncludingExtensionDeclared` -- did not use it: each built directly
into the shared `Fixtures/cross-file-witness` root, first deleting that shared directory's own
`.build` (`try? FileManager.default.removeItem(atPath: fixtureRoot.appendingPathComponent(".build").path)`).
Under Swift Testing's default parallel execution, this collided with any other test (in this file or
`RawIndexStoreClientModuleScopingTests.swift`) concurrently building or reading the same shared
`.build` -- exactly the two real failure shapes issue #148 reports (a `swift build` exit code 1 racing
a concurrent `rm -rf .build`, and a Clang module-cache `.pcm.lock` file disappearing mid-read).

Confirmed by checking `ConcurrentIssuanceSpike.swift` and `CapstoneCLITests.swift` (the only other
files referencing `cross-file-witness`, per an exhaustive grep): the former only reads source text
from the fixture (no `swift build`, no `.build` access at all), and the latter builds a completely
different, non-shared fixture (`Fixtures/simple-actor`). Neither needed any change.

## Fix

Converted the three remaining unsafe tests in `DeclarationLinkerTests.swift` to use the
already-existing `copiedCrossFileWitnessFixture()` helper, exactly mirroring the other three tests in
the same file and the precedent already shipped in `RawIndexStoreClientModuleScopingTests.swift`/
`ExternalIsolationBackfillTests.swift`. Each of the three also got its own index-store path suffixed
with a fresh `UUID()` (matching the helper's own already-existing tests), removing the last
`try? FileManager.default.removeItem(atPath: fixtureRoot.appendingPathComponent(".build").path)` calls
against the shared fixture root. No production code changed -- this is purely test-infrastructure, per
the issue's own "why open, not fixed here" scoping note.

After this change, **no test in the repository builds directly into
`Tests/Fixtures/cross-file-witness/.build` any more** -- every test that needs a real build of this
fixture now works against its own private, `realpath`-resolved copy.

## Verification

Ran the exact repro command from the issue, `swift test -c release --filter
"DeclarationLinkerTests|RawIndexStoreClientModuleScopingTests"`, three times in a row (fixed code, not
`git stash`'d): all three runs passed 10/10 tests, zero failures, zero flakes (140s / 178s / 64s wall
time -- the middle run's slower time is explained by unrelated heavy concurrent system load at the
time, not a hang: `swift-frontend` processes were confirmed actively compiling throughout via `ps`).
The exact original failure shapes from the issue (`exitCode == 1`, `.storeCreateFailed`, the
`.pcm.lock` `NSCocoaErrorDomain` error) did not reproduce in any of the three runs.

Not re-verified against the "before" state again in this pass -- issue #148's own filing already did
that (`git stash` + repeated runs on pristine `main`), and re-doing it wasn't needed to confirm the fix
itself works.

## Incidental cleanup

While investigating, found ~3866 leftover `swift-isolation-map-*` temp directories accumulated under
`NSTemporaryDirectory()` from previous test runs across this project's history (every
`copiedCrossFileWitnessFixture()`-style helper creates a fresh `UUID()`-named copy per test run and
never removes it after the test finishes, so this accumulates over time and, left unchecked, can
contribute to real disk-space exhaustion -- consistent with the same ENOSPC crisis hit earlier in this
project's own investigation history). Manually removed as routine hygiene; not fixed in code, since
adding cleanup logic to every test's build helper was out of scope for this issue and none of this
project's existing per-test-copy helpers do it today.
