# Priority 3, Phase A — real per-file compiler arguments (decision record)

Per `docs/task-compiled-dependency-isolation-integration.md`'s Phase A and the implementation
plan's explicit instruction to make this decision in writing, not inherit it implicitly. Three
candidates were on the table: (a) parse a real `xcodebuild build` verbose log for literal `swiftc`
invocations, (b) `xcodebuild build -dry-run`, (c) depend on the third-party `xcode-build-server`.
Resolved empirically against this machine's real toolchain (Xcode 26.4.0) and a real, non-trivial
Xcode project (`~/SQLumen`), not assumed — same discipline as every other CLI-flag claim in this
project's history (two prior real `xcodebuild`/`swift build` flag bugs were both found only this
way).

## What was checked

**Option (b), `-dry-run`, is dead on this toolchain**: `xcodebuild -scheme SQLumen -project
SQLumen.xcodeproj build -dry-run` fails immediately: `xcodebuild: error: option '-dry-run' is no
longer supported`. Ruled out.

**Option (a) works, but not in the shape first assumed.** SwiftPM's `swift build -v` prints one
`swift-frontend -frontend -c -primary-file <file> <every sibling file> ...` line per source file
(confirmed working, see `CompilerArgsLogParser`/`LiveSwiftPMCompilerArgumentsProvider`). Xcode's
`-verbose` build log does **not** do the equivalent — it prints one **driver-level** `swiftc`
invocation per target (`builtin-Swift-Compilation -- .../usr/bin/swiftc -module-name SQLumen
-Onone @/…/SQLumen.SwiftFileList ... -target arm64-apple-macos26.4 -sdk ... -swift-version 5
-default-isolation=MainActor ... -c -incremental -enable-batch-mode ...`), with the target's full
source file list behind an `@`-referenced response file (`SQLumen.SwiftFileList`, one absolute
path per line — confirmed readable, plain text), not printed as literal file arguments on the
`swiftc` line itself. Confirmed by forcing a real recompile (`touch`-ing one source file, since an
up-to-date build emits no compile lines at all) — real, current, and reproducible on this machine.

**Option (c), `xcode-build-server`, remains not installed** (unchanged from the original spike
finding) and is not needed given (a) works.

## Decision

**Option (a), self-contained build-log parsing — confirmed viable, adopted**, with a
Xcode-specific shape distinct from the SwiftPM parser:

- SwiftPM: per-file `-primary-file` lines map directly, one file to one line (existing
  `CompilerArgsLogParser.parse`, unchanged).
- Xcode: one driver-level `swiftc` line per target, file list behind `@SwiftFileList` — parsed by
  a new `CompilerArgsLogParser.parseXcodeSwiftCompileInvocations(buildLog:)` (pure, returns the
  flag list plus the *unresolved* file-list path), with the response file itself expanded by the
  I/O-performing `XcodeBuildLogCompilerArgumentsProvider` via `FileSystemQuerying` — every file in
  a target's expanded file list maps to that one target's full argument list, the same "many files,
  one shared argument list" shape already used for SwiftPM's whole-module-optimization fallback.

This keeps the tool's install story exactly as self-contained as before (no new third-party
runtime dependency), and produces the *exact* real build's flags (SDK, target triple, search
paths, upcoming-feature flags, even a project's own `-default-isolation=MainActor`, confirmed
present for SQLumen) — matching the correctness requirement that `sourcekitd` must see the same
semantics as the real build, not an approximation.

## What must still happen before this is exercised for real

`Sources/swift-isolation-map/SwiftIsolationMap.swift`'s `build(container:locator:processRunning:)`
(the `--auto-build` path) currently discards `result.standardOutput` for the Xcode branch — it
must add `-verbose` to the invocation and capture/return the log so
`XcodeBuildLogCompilerArgumentsProvider` has something to parse. Validated so far only against
`~/SQLumen`; must also be validated against `~/ios` (a CocoaPods-based workspace, a structurally
different case) before Phase F's real-world re-run, per this project's established
"verify against more than one real project" discipline.
