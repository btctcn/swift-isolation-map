# Upstream report: `IndexStoreDB` drops occurrences for files shared across multiple targets

Filed against [`swiftlang/indexstore-db`](https://github.com/swiftlang/indexstore-db) as
[issue #292](https://github.com/swiftlang/indexstore-db/issues/292) (body matches this document,
confirmed by direct comparison), with a fix submitted as
[PR #293](https://github.com/swiftlang/indexstore-db/pull/293) ("Fixes #292" — a new
`SharedFileMultiTarget` tibs fixture plus regression tests, full `swift test` run confirmed green).
**Status as of 2026-09-05: PR #293 still open, unreviewed** — opened 2026-08-10, no maintainer
activity since (one comment, one review recorded, but no update since the day it was opened). This
document is kept as the original investigation record; the content below reflects the state at the
time of filing, not a live draft. See `docs/task-raw-indexstore-spike.md` for how this was found.

---

## Where this came from

While migrating `swift-isolation-map` from `IndexStoreDB` to a raw `libIndexStore`-backed client
(issue #51), a controlled, same-process, same-moment comparison of both clients against Project
Iris (a real, ~2251-file production iOS app) showed a ~13% call-graph edge disagreement that
survived even after every earlier single-file spot check had matched perfectly. Tracing the one
file responsible for almost all of that disagreement (`Common/MindboxNotification.swift`) found
that its declarations carry **three different module-name prefixes** — the main app plus Project
Iris's own two notification-extension targets, all three compiling this one shared file. Querying
`IndexStoreDB` directly for this file returned only one target's worth of data; the raw client
returned all three. A minimal, three-`swiftc`-invocation reproduction (below) confirmed this is a
general `IndexStoreDB` behavior, not specific to Project Iris.

---

## The issue, ready to file

**Suggested title:** `foreachSymbolOccurrenceInFilePath` (and `symbolOccurrences(inFilePath:)`) returns occurrences from only one compiling target when a file belongs to multiple units

### Summary

`IndexStoreDB.symbolOccurrences(inFilePath:)` (and `symbols(inFilePath:)`, which shares the same
underlying enumeration) silently returns occurrences from only **one** of the compilation units
that reference a given source file, when that file is a member of more than one unit — e.g. an app
target and an extension target both compiling the same shared `.swift` file. This is routine
iOS/macOS architecture: app + notification-service extension, app + widget extension, app + share
extension, or any multi-target setup with shared sources.

### Environment

- `indexstore-db` revision: `003ac41513ba291f10ff1a0147ae68588914668d` (pinned; matches
  `swift/release/6.3`'s HEAD at time of writing)
- Toolchain: Xcode 26.4 / Swift 6.3, macOS (arm64)
- Found while building [`swift-isolation-map`](https://github.com/btctcn/swift-isolation-map), a
  static actor-isolation analysis CLI that reads `IndexStoreDB` for its call graph, against a real
  production iOS app with two notification-extension targets sharing source files with the main
  app target.

### Minimal reproduction

No SwiftPM, no Xcode project, no third-party dependency — two `swiftc` invocations against the
same file, indexed into one store:

```sh
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET="arm64-apple-macosx13.0"

cat > Shared.swift <<'EOF'
public struct SharedThing {
    public init() {}
    public func doWork() { helper() }
    private func helper() { print("working") }
}
EOF

xcrun swiftc -module-name AppModule -swift-version 6 -sdk "$SDK" -target "$TARGET" \
  -emit-module -emit-module-path AppModule.swiftmodule -parse-as-library \
  -index-store-path "$PWD/index-store" -c Shared.swift -o AppModule.o

xcrun swiftc -module-name ExtModule -swift-version 6 -sdk "$SDK" -target "$TARGET" \
  -emit-module -emit-module-path ExtModule.swiftmodule -parse-as-library \
  -index-store-path "$PWD/index-store" -c Shared.swift -o ExtModule.o
```

Then, opening `index-store` with `IndexStoreDB` and calling
`symbolOccurrences(inFilePath: "<absolute path to Shared.swift>")`:

- **Expected**: 8 definitions (4 from `AppModule`'s compilation + 4 from `ExtModule`'s).
- **Actual**: 4 definitions — only one module's worth (which one is not deterministic from the
  caller's perspective; depends on `foreachUnitContainingFile`'s own internal enumeration order).

Cross-checked directly against `libIndexStore`'s own raw C API
(`indexstore_record_reader_occurrences_apply_f` on each of the two distinct on-disk records for
this file) — the raw index data is complete and correct; both modules' occurrences are present on
disk. The loss happens specifically in `IndexStoreDB`'s own file-based enumeration, not in the
underlying index store.

### Root cause

`Sources/IndexStoreDB_Index/SymbolIndex.cpp`,
`SymbolIndexImpl::foreachSymbolOccurrenceInFilePath` (lines 509–534):

```cpp
bool SymbolIndexImpl::foreachSymbolOccurrenceInFilePath(CanonicalFilePathRef filePath,
                                                        function_ref<bool(SymbolOccurrenceRef Occur)> Receiver) {
  bool didFinish = true;
  ReadTransaction reader(DBase);

  IDCode filePathCode = reader.getFilePathCode(filePath);
  reader.foreachUnitContainingFile(filePathCode, [&](ArrayRef<IDCode> idCodes) -> bool {
    for (IDCode idCode : idCodes) {
      UnitInfo unitInfo = reader.getUnitInfo(idCode);
      for (UnitInfo::Provider provider : unitInfo.ProviderDepends) {
        IDCode providerCode = provider.ProviderCode;
        if (provider.FileCode == filePathCode) {
          auto record = createVisibleProviderForCode(providerCode, reader);
          if (!record) {
            continue;
          }
          didFinish = record->foreachSymbolOccurrence(Receiver);

          return false;   // <-- returns from the OUTER foreachUnitContainingFile callback
        }
      }
    }
    return true;
  });
  ...
}
```

The `return false;` on the line marked above returns from the *outer* callback passed to
`reader.foreachUnitContainingFile`, not just the inner `for` loops — so as soon as the **first**
unit containing this file yields a matching provider, the entire unit enumeration stops. Any other
unit that also contains this file (i.e. every other target compiling it) is never visited, and its
occurrences are silently never reported to `Receiver`.

The same shape likely affects `foreachSymbol`/`symbols(inFilePath:)` too, since it presumably
shares comparable enumeration logic — not independently verified in this report, called out here
so it can be checked in the same pass as the fix.

### Impact

Any tool built on `symbolOccurrences(inFilePath:)`/`symbols(inFilePath:)` — code navigation,
find-references, refactoring tooling, static analysis — silently loses data for any source file
shared across more than one compilation target, with no error, warning, or partial-result
indication. This is not a rare shape: app + notification/widget/share extension sharing source
files is routine iOS/macOS architecture, and `sourcekit-lsp` (the primary consumer of
`IndexStoreDB`) presumably calls this same path for per-file queries, though that was not
independently verified for this report.

Measured on one real, ~2251-file production app: a single shared file compiled into 3 targets
(main app + 2 notification extensions) had only 1 of 3 targets' worth of declarations (72 of 216,
33%) visible via `symbolOccurrences(inFilePath:)`; the same shape's call-graph queries lost 209 of
627 call sites (33%) for the same reason.

### Suggested fix

Continue the outer `foreachUnitContainingFile` enumeration across all matching units/providers
instead of returning `false` after the first match — accumulating occurrences from every compiling
target's own record for this file path, not just the first one found. Happy to submit a PR with a
fix and a regression test if that's useful.

---

## Notes for whoever decides whether/how to file this

- **Repository**: this is specifically an `IndexStoreDB` (Swift/C++ wrapper) bug, not
  `libIndexStore`/`indexstore.h` (the lower-level C API in `swiftlang/llvm-project`) — the raw data
  on disk is correct; the loss is in `IndexStoreDB`'s own enumeration logic. File against
  `swiftlang/indexstore-db`.
- **Before filing**: search existing issues in both `swiftlang/indexstore-db` and
  `swiftlang/sourcekit-lsp` for `symbolOccurrences`, "multiple targets", "shared file", "extension
  target index" to rule out a duplicate.
- **Confidence level**: the root-cause citation (exact file/function/line) was found by reading the
  real, checked-out `indexstore-db` source this project already depends on
  (`.build/checkouts/indexstore-db`) — not guessed or inferred from behavior alone.
- **What's independently confirmed vs. not**: the `symbolOccurrences(inFilePath:)` bug itself is
  confirmed twice (real corpus + minimal repro) and the exact code line is identified. The
  `foreachSymbol`/`symbols(inFilePath:)` sibling-bug claim and the `sourcekit-lsp` impact claim are
  both flagged in the report as *plausible but not independently verified* — worth being explicit
  about that distinction if asked follow-up questions after filing.
