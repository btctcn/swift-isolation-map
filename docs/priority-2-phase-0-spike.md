# Priority 2, Phase 0 — IndexStoreDB dependency spike (de-risking record)

Per `docs/isolation-rules.md`'s sourcing discipline ("empirical testing... mandatory, not
optional") applied one level up — to a *dependency*, not an isolation rule. Before committing to
IndexStoreDB as the call-graph source for Priority 2 (architecture doc section 2.1-2.2), this was
verified as a real, working round-trip against the local toolchain, not assumed from the
architecture doc's code sketch or from upstream documentation. No production code depends on
IndexStoreDB yet — that's Phase 3. This file is the durable proof that the mechanism works; the
throwaway spike code itself was deleted (same convention as the `swiftc` reproduction snippets
throughout `docs/isolation-rules.md` and `docs/motivation.md`).

## What was run

1. A tiny real SPM package (one file, one `actor` type with a stored property and a method) built
   with an explicit index store path:
   ```
   swift build -Xswiftc -index-store-path -Xswiftc /tmp/phase0-index-store
   ```
   (see "Corrections to the architecture doc" below for why this flag form, not
   `swift build --index-store-path`, was used.)
2. A throwaway executable target depending on
   `.package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "003ac41513ba291f10ff1a0147ae68588914668d")`
   (pinned to `release/6.3`/`release/6.3.1`'s current HEAD, matching the local Swift 6.3
   toolchain — see "Dependency pin" below) that:
   - resolved `libIndexStore.dylib`'s path via `xcrun --find swift` → strip `usr/bin/swift` →
     append `usr/lib/libIndexStore.dylib`
   - opened `IndexStoreLibrary(dylibPath:)` and `IndexStoreDB(storePath:databasePath:library:waitUntilDoneInitializing:)`
     against the fixture's index store
   - called `symbols(inFilePath:)` on the fixture's one source file
   - called `occurrences(ofUSR:roles:)` on the resulting `UserSession` USR

## What came back

Resolved dylib path (confirmed to exist before use):
```
/Applications/Xcode-26.4.0.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib
```

`symbols(inFilePath:)` returned all 10 real symbols from the fixture file, each with a real USR,
correct name, and a symbol kind, including:
```
USR=s:13Phase0Fixture11UserSessionC                 name=UserSession        kind=class
USR=s:13Phase0Fixture11UserSessionC5login2asySS_tF   name=login(as:)         kind=instanceMethod
USR=s:13Phase0Fixture11UserSessionC07currentC0SSvp   name=currentUser        kind=instanceProperty
```
`occurrences(ofUSR:roles: [.reference])` on `UserSession`'s USR returned 1 result, as expected
for a symbol referenced once (in the fixture's top-level `let session = UserSession()`).

**The full round-trip (toolchain → dylib → store → real USRs) works, unmodified from the
architecture doc's assumed API shape.** No `systemLibrary` target or C shim was needed in this
project's own `Package.swift` — the C++ dependency is fully hidden behind
`import IndexStoreDB`'s Swift wrapper (confirmed by reading `IndexStoreDB.swift`'s
`@_implementationOnly import IndexStoreDB_CIndexStoreDB`).

## A genuinely useful finding, not just a confirmation

`UserSession` — declared as `actor UserSession { ... }` in the fixture — was reported with
**`kind=class`, not `kind=actor`**. Checked the actual enum
(`IndexSymbolKind` in indexstore-db's `Symbol.swift`, pinned revision): there is **no `.actor`
case at all** — it's a fixed, closed set of kinds (`class`, `struct`, `enum`, `protocol`,
`instanceMethod`, ...) inherited from the general clang/IndexStore symbol taxonomy, which
predates Swift's actor model entirely.

This is a concrete, empirical confirmation of the architecture doc's own stated rationale for
the whole hybrid design (section 2.1): *"IndexStoreDB... does not directly expose isolation
information — that's type-checker-level semantics, not indexing."* It's not even a fuzzy
approximation — `actor` vs. `class` isn't a distinction IndexStoreDB's symbol kind can express at
all, at the type-declaration level, which is as strong a confirmation as this spike could produce
that isolation attributes must come from SwiftSyntax (Phase 1), never be inferred from
IndexStoreDB symbol kinds.

## Dependency pin — decision record

`swiftlang/indexstore-db` (the `apple/indexstore-db` URL 301-redirects here — depend on the
`swiftlang` URL directly) has **no semver tags or GitHub releases in its history** — only
per-Swift-version `release/6.x` branches and toolchain snapshot tags. `sourcekit-lsp` itself
depends on it via a floating branch, not a version requirement — that consumption style isn't
available here the way it is for most SPM dependencies.

**Decision: pin by exact `revision:`, not `branch:`.**
```swift
.package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "003ac41513ba291f10ff1a0147ae68588914668d")
```
`release/6.3` is a live branch that continues to receive patches — resolving against it directly
would make the dependency graph non-reproducible build-to-build, which runs against this
project's own "never silently assume" principle just as much as an un-reviewed rule-set version
bump would. The pinned revision above is `release/6.3`'s (and `release/6.3.1`'s — both point at
the same commit) HEAD as of 2026-07-24. Manifest at this revision: `swift-tools-version:5.6`, no
`platforms:` array — no conflict with this package's own `.macOS(.v13)` floor.

**Product choice: `IndexStoreDB` (the heavyweight, C++/LMDB-backed product), not the newer, lighter
pure-Swift `IndexStore` product** (raw iteration only, no `symbols(inFilePath:)`/
`occurrences(ofUSR:)` query API — and doesn't even exist on `release/6.3`, only on `main`/6.4+).
`IndexStoreDB` has the exact API surface the architecture doc assumes and this spike just
verified working; it's the same engine every Xcode/VS Code user's sourcekit-lsp already runs, not
an exotic choice.

**Bump process:** when `SwiftNNRuleSet` review adds support for a new Swift version (per
`docs/isolation-rules.md`'s per-version-type discipline), re-pinning this revision to the
matching `release/6.x` branch's new HEAD should happen as part of that same reviewed change, not
drift silently. Not yet wired into `swift-version-watch.yml`'s automated check — worth adding
once Phase 3 actually re-introduces this dependency for real.

## Corrections to the architecture doc, found empirically during this spike

Verified against the local toolchain (Apple Swift 6.3, swiftlang-6.3.0.123.5) and current SwiftPM
— both are now stale relative to what section 2.6 of the architecture doc states:

- `swift build --index-store-path <path>` **does not exist** as a top-level flag anymore.
  `swift build --help` shows only `--auto-index-store`/`--enable-index-store`/
  `--disable-index-store` (no path argument) — indexing-while-building is **on by default**.
- The real default SPM index store location is
  `.build/index-build/<triple>/<config>/index/store` (confirmed by building this project itself
  and inspecting `.build/`), not `.build/index-store` as the doc states.
- An explicit path is still achievable via raw compiler flag passthrough — the form actually used
  by this spike, and verified working:
  ```
  swift build -Xswiftc -index-store-path -Xswiftc <path>
  ```
  Phase 2b (index store discovery / `--auto-build`) should use this form, not the doc's assumed
  flag.

## Status

Spike complete and passed. No dependency, target, or spike code remains in the tree after this
PR — the pin and product-choice decisions above are the durable output, to be re-applied for real
in Phase 3 when the call-graph integration actually consumes IndexStoreDB.
