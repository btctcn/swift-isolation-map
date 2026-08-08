import Foundation
import Testing
import IsolationCore
import ProjectResolution
@testable import IndexStoreIntegration

/// Issue #51's scoped spike (`docs/task-raw-indexstore-spike.md`): diffs `RawIndexStoreClient`
/// (raw `libIndexStore` C API, one upfront full-store scan) against `IndexStoreClient`
/// (`IndexStoreDB`, on-demand queries) on the *same real index store*, built from
/// `Tests/Fixtures/cross-file-witness` -- deliberately reused rather than a new fixture, since it
/// already exercises every shape `IndexStoreQuerying`'s 7 methods need: direct inheritance
/// (`BaseWidget`/`DerivedWidget`), extension-of-an-external-type (`NSView`), a nested-type
/// extension, a generic-type extension, cross-file conformance, protocol conformance via
/// extension (`Refreshable`/`SyncCoordinator`), a stored-property accessor (`counter`), and a real
/// call graph (`trigger` -> `unrelatedMethod`/`refresh`).
@Suite("RawIndexStoreClient vs. IndexStoreClient: real-index-store diff (issue #51 spike)")
struct RawIndexStoreClientDiffTests {
    static func buildFixtureStore() throws -> (storePath: String, sourcesDirectory: URL) {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RawIndexStoreClientDiffTests.swift -> IndexStoreIntegrationTests
            .deletingLastPathComponent() // IndexStoreIntegrationTests -> Tests
            .appendingPathComponent("Fixtures/cross-file-witness")
        let sourcesDirectory = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness")
        let indexStorePath = NSTemporaryDirectory() + "swift-isolation-map-test-raw-diff-store"
        // A dedicated `--scratch-path`, not the fixture's own default `.build` -- `DeclarationLinkerTests.swift`
        // builds this *same* fixture from its own default `.build` directory, and Swift Testing
        // runs tests concurrently by default; two `swift build` invocations sharing one `.build`
        // directory at the same time corrupt each other's build database ("disk I/O error"),
        // confirmed as a real, reproducible failure before this fix.
        let scratchPath = NSTemporaryDirectory() + "swift-isolation-map-test-raw-diff-scratch"
        try? FileManager.default.removeItem(atPath: indexStorePath)
        try? FileManager.default.removeItem(atPath: scratchPath)

        let processRunner = LiveProcessRunner()
        let buildResult = try processRunner.run(
            executable: "swift",
            arguments: ["build", "--scratch-path", scratchPath, "-Xswiftc", "-index-store-path", "-Xswiftc", indexStorePath],
            workingDirectory: fixtureRoot
        )
        #expect(buildResult.exitCode == 0, "fixture build failed: \(buildResult.standardError)")
        return (indexStorePath, sourcesDirectory)
    }

    @Test("Every IndexStoreQuerying method returns identical results from both clients, for every declaration and call site the fixture has")
    func rawClientMatchesIndexStoreDBClient() throws {
        let (storePath, sourcesDirectory) = try Self.buildFixtureStore()
        let databasePath = NSTemporaryDirectory() + "swift-isolation-map-test-raw-diff-db"
        try? FileManager.default.removeItem(atPath: databasePath)

        let dbClient = try IndexStoreClient(storePath: storePath, databasePath: databasePath)
        let rawClient = try RawIndexStoreClient(storePath: storePath)

        let sourceFileNames = [
            "DirectInheritance.swift", "ExtensionOfExternalType.swift", "MultiFileType.swift",
            "MultiFileTypeExtension.swift", "Protocol.swift", "SyncCoordinator.swift",
            "SyncCoordinatorRefreshable.swift", "main.swift"
        ]
        let filePaths = sourceFileNames.map { sourcesDirectory.appendingPathComponent($0).path }

        // 1. `definedSymbols(inFile:)` -- every file, byte-for-byte (order-independent: compare as
        // sets of (usr, name, line, column), since the two clients scan in different orders).
        var allDefinedUSRs: Set<String> = []
        for path in filePaths {
            let dbSymbols = Set(dbClient.definedSymbols(inFile: path).map { "\($0.usr)|\($0.name)|\($0.location.line)|\($0.location.column)" })
            let rawSymbols = Set(rawClient.definedSymbols(inFile: path).map { "\($0.usr)|\($0.name)|\($0.location.line)|\($0.location.column)" })
            #expect(dbSymbols == rawSymbols, "definedSymbols mismatch for \(path)")
            allDefinedUSRs.formUnion(dbClient.definedSymbols(inFile: path).map(\.usr))
        }
        #expect(!allDefinedUSRs.isEmpty)

        // 2. `callGraphEdges(forUSR:)` -- for every real defined USR (reverse lookup).
        for usr in allDefinedUSRs {
            let dbEdges = Set(dbClient.callGraphEdges(forUSR: usr).map { "\($0.callerUSR)|\($0.calleeUSR)|\($0.location.line)|\($0.location.column)" })
            let rawEdges = Set(rawClient.callGraphEdges(forUSR: usr).map { "\($0.callerUSR)|\($0.calleeUSR)|\($0.location.line)|\($0.location.column)" })
            #expect(dbEdges == rawEdges, "callGraphEdges mismatch for USR \(usr)")
        }

        // 3. `callSites(inFile:)` -- every file.
        for path in filePaths {
            let dbSites = Set(dbClient.callSites(inFile: path).map { "\($0.callerUSR)|\($0.calleeUSR)|\($0.location.line)|\($0.location.column)" })
            let rawSites = Set(rawClient.callSites(inFile: path).map { "\($0.callerUSR)|\($0.calleeUSR)|\($0.location.line)|\($0.location.column)" })
            #expect(dbSites == rawSites, "callSites mismatch for \(path)")
        }

        // 4. `owningPropertyUSR(forUSR:)`, `baseTypeUSRs(forUSR:)`, `containingExtensionUSR(forMemberUSR:)`,
        // `extendedTypeUSR(forExtensionUSR:)` -- for every real defined USR, whatever the answer is
        // (nil counts as a match too).
        var anyOwningPropertyMatch = false
        var anyBaseTypeMatch = false
        var anyContainingExtensionMatch = false
        var anyExtendedTypeMatch = false
        for usr in allDefinedUSRs {
            let dbOwning = dbClient.owningPropertyUSR(forUSR: usr)
            let rawOwning = rawClient.owningPropertyUSR(forUSR: usr)
            #expect(dbOwning == rawOwning, "owningPropertyUSR mismatch for USR \(usr)")
            if dbOwning != nil { anyOwningPropertyMatch = true }

            let dbBase = Set(dbClient.baseTypeUSRs(forUSR: usr).map { "\($0.usr)|\($0.name)" })
            let rawBase = Set(rawClient.baseTypeUSRs(forUSR: usr).map { "\($0.usr)|\($0.name)" })
            #expect(dbBase == rawBase, "baseTypeUSRs mismatch for USR \(usr)")
            if !dbBase.isEmpty { anyBaseTypeMatch = true }

            let dbContaining = dbClient.containingExtensionUSR(forMemberUSR: usr)
            let rawContaining = rawClient.containingExtensionUSR(forMemberUSR: usr)
            #expect(dbContaining == rawContaining, "containingExtensionUSR mismatch for USR \(usr)")
            if dbContaining != nil { anyContainingExtensionMatch = true }

            let dbExtended = dbClient.extendedTypeUSR(forExtensionUSR: usr)
            let rawExtended = rawClient.extendedTypeUSR(forExtensionUSR: usr)
            #expect(dbExtended == rawExtended, "extendedTypeUSR mismatch for USR \(usr)")
            if dbExtended != nil { anyExtendedTypeMatch = true }
        }
        // Guards against a vacuously-passing diff (every comparison silently nil == nil) -- the
        // fixture is deliberately shaped to exercise all 4 of these relations for real, so at
        // least one real (non-nil/non-empty) match must show up on each, or the test fixture (or
        // one of the two clients) isn't actually being exercised the way this test claims.
        #expect(anyOwningPropertyMatch, "fixture's `counter` property accessor never matched -- test isn't exercising owningPropertyUSR for real")
        #expect(anyBaseTypeMatch, "fixture's inheritance/conformance shapes never matched -- test isn't exercising baseTypeUSRs for real")
        #expect(anyContainingExtensionMatch, "fixture's extension members never matched -- test isn't exercising containingExtensionUSR for real")
        #expect(anyExtendedTypeMatch, "fixture's extensions never matched -- test isn't exercising extendedTypeUSR for real")
    }
}
