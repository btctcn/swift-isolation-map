import Foundation
import Testing
@testable import SourceKitDIntegration

/// Live-toolchain tier, same discipline as `IndexStoreIntegrationTests/DeclarationLinkerTests.swift`:
/// a real `sourcekitdInProc` dlopen, real cursor-info requests, against a real fixture file. No
/// skip-if-toolchain-missing guard, consistent with this project's existing style (CI always has a
/// working toolchain).
///
/// All assertions in this file share **one** `SourceKitDClient` instance deliberately, not several
/// independently constructed ones -- matches the binding design's real production usage ("one
/// in-process session per analysis run") and, concretely, avoids a real race this project's own C
/// shim hit twice during development: two `SourceKitDClient`s constructed concurrently (as two
/// separate `@Test` functions naturally are, under Swift Testing's default parallel execution)
/// crash the whole test process (`SIGSEGV`) -- first confirmed while building the cursor-info path
/// itself, then confirmed *again*, independently, when the `source.request.statistics` smoke test
/// below was first added as its own separate `@Test func` (each constructing its own client): both
/// tests started, neither finished, the whole `swiftpm-testing-helper` process died. Since
/// sourcekitd itself is a single process-wide shared library regardless of how many Swift-side
/// wrapper instances exist, this project's own actual usage never needs more than one instance
/// anyway -- so the fix both times was the same: merge into one test function sharing one client,
/// not add more synchronization around construction. **Do not add a new `@Test func` that calls
/// `SourceKitDClient()` in this file** -- extend this one instead.
@Test
func realCursorInfoAgainstRealFixtureFilesSucceedsAndFailsAsExpected() async throws {
    let fixtureFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SourceKitDClientTests.swift -> SourceKitDIntegrationTests
        .deletingLastPathComponent() // SourceKitDIntegrationTests -> Tests
        .appendingPathComponent("Fixtures/simple-actor/Sources/SimpleActorApp/main.swift")
        .resolvingSymlinksInPath()

    let text = try String(contentsOf: fixtureFile, encoding: .utf8)
    // Offset of the parameter-type reference `Counter` in `trigger(_ counter: Counter)` -- not
    // the declaration itself, to prove cursor-info resolves a *reference*, matching how Phase C
    // will query real call/inheritance sites, not declarations.
    let declarationRange = try #require(text.range(of: "actor Counter"))
    let referenceRange = try #require(text.range(of: "Counter", range: declarationRange.upperBound..<text.endIndex))
    let byteOffset = text.utf8.distance(from: text.utf8.startIndex, to: referenceRange.lowerBound.samePosition(in: text.utf8)!)

    let sdk = try realSDKPath()
    let arguments = ["-sdk", sdk, "-swift-version", "6", fixtureFile.path]

    let client = try SourceKitDClient()

    let result = try await client.cursorInfo(CursorInfoRequest(
        sourceFile: fixtureFile.path,
        byteOffset: byteOffset,
        compilerArguments: arguments
    ))
    #expect(result.primary.usr.contains("Counter"))

    await #expect(throws: SourceKitDQueryError.self) {
        try await client.cursorInfo(CursorInfoRequest(
            sourceFile: "/never/a/real/file.swift",
            byteOffset: 0,
            compilerArguments: []
        ))
    }

    try await checkStatisticsRequestShapeAndCumulativeCounters(
        client: client,
        fixtureFile: fixtureFile,
        byteOffset: byteOffset,
        compilerArguments: arguments
    )
}

/// Smoke test for `docs/task-oracle-query-concurrency.md`'s §2.5/amendments: `strings -a` on the
/// real binary confirmed `source.request.statistics` and its `num-ast-builds`/`num-ast-cache-hits`
/// UIDs exist, but *not* the response's actual shape (nesting, key names actually used at the
/// wire level) -- that is exactly the "strings vs. control-flow" gap the amendments call out, so
/// this pins it down by literally issuing the request and dumping the real response, rather than
/// assuming `key.results`/`key.description`/`key.value` compose the way `strings` output alone
/// suggested.
///
/// Also checks the amendments' cumulative-counter claim empirically: two `requestStatistics()`
/// calls with a real cursor-info query issued in between should show `num-ast-builds` at least as
/// large the second time (a session-lifetime counter never resets, so it cannot decrease) -- not
/// a per-phase counter that would reset to zero between the two snapshots.
///
/// Called from the one shared-client test above, not its own `@Test func` -- see this file's own
/// top-of-file comment for why a second independently-constructed `SourceKitDClient` crashes here.
private func checkStatisticsRequestShapeAndCumulativeCounters(
    client: SourceKitDClient,
    fixtureFile: URL,
    byteOffset: Int,
    compilerArguments: [String]
) async throws {
    let before = try await client.requestStatistics()
    print("=== source.request.statistics: real response shape (before any query) ===")
    print(before.dump)

    _ = try await client.cursorInfo(CursorInfoRequest(
        sourceFile: fixtureFile.path,
        byteOffset: byteOffset,
        compilerArguments: compilerArguments
    ))

    let after = try await client.requestStatistics()
    print("=== source.request.statistics: real response shape (after) ===")
    print(after.dump)

    #expect(!before.dump.isEmpty)
    let astBuilds = "source.statistic.num-ast-builds"
    let astCacheHits = "source.statistic.num-ast-cache-hits"
    let numRequests = "source.statistic.num-requests"
    #expect(before.byKind[astBuilds] != nil, "expected \(astBuilds) in key.results -- if this fails, the real response shape changed; read the dump above")
    #expect(before.byKind[astCacheHits] != nil, "expected \(astCacheHits) in key.results -- if this fails, the real response shape changed; read the dump above")

    // This shared-client test already queried this exact fixture file/offset once (the
    // `cursorInfo` call above the call to this function), so the AST is already warm by the time
    // this function's own `cursorInfo` call runs. Kept as an exact, zero-tolerance equality (not
    // loosened below) because it tests a real behavioral invariant this project depends on --
    // same file/args must reuse the cached AST, not rebuild -- not an incidental magic number.
    #expect(after.byKind[astBuilds] == before.byKind[astBuilds], "expected no new AST build against an already-warm file/args pair")
    // Deliberately a strict-growth check (`>`), not exact-`+1` equality: on this toolchain the
    // observed real value is exactly +1 (recorded in docs/task-oracle-query-concurrency.md's
    // §2.6 for the record), but pinning that exact secondary count here would make this test
    // fail on a future toolchain that, say, starts consuming two cache entries for one query --
    // a change that would not itself falsify the cumulative-counter claim this test exists to
    // check. Strict growth still fully proves "the counter moved, and only upward."
    #expect((after.byKind[astCacheHits] ?? 0) > (before.byKind[astCacheHits] ?? 0), "expected the cache-hit counter to have grown for the already-warm query")
    #expect((after.byKind[numRequests] ?? 0) > (before.byKind[numRequests] ?? 0), "expected the request counter to have moved at all between the two snapshots")

    // Cumulative, session-lifetime semantics: every counter must be monotonically non-decreasing
    // across the two snapshots, never reset to a smaller (or zero) value.
    for (kind, beforeValue) in before.byKind {
        if let afterValue = after.byKind[kind] {
            #expect(afterValue >= beforeValue, "\(kind) decreased (\(beforeValue) -> \(afterValue)) -- would falsify the cumulative-counter claim")
        }
    }
}

private func realSDKPath() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["xcrun", "--show-sdk-path", "--sdk", "macosx"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
}
