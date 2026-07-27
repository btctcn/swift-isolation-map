import Foundation
import Testing
@testable import SourceKitDIntegration

/// Live-toolchain tier, same discipline as `IndexStoreIntegrationTests/DeclarationLinkerTests.swift`:
/// a real `sourcekitdInProc` dlopen, real cursor-info requests, against a real fixture file. No
/// skip-if-toolchain-missing guard, consistent with this project's existing style (CI always has a
/// working toolchain).
///
/// Both assertions share **one** `SourceKitDClient` instance deliberately, not two independently
/// constructed ones -- matches the binding design's real production usage ("one in-process
/// session per analysis run") and, concretely, avoids a real race this project's own C shim hit
/// during development: two `SourceKitDClient`s constructed concurrently (as two separate `@Test`
/// functions naturally are, under Swift Testing's default parallel execution) raced on the shim's
/// process-wide `dlopen`/`dlsym` state and crashed (`SIGSEGV`) -- since sourcekitd itself is a
/// single process-wide shared library regardless of how many Swift-side wrapper instances exist,
/// this project's own actual usage never needs more than one instance anyway.
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
