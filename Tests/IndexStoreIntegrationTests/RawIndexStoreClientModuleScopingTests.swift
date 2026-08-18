import Foundation
import Testing
import ProjectResolution
@testable import IndexStoreIntegration

/// Real, end-to-end coverage for `RawIndexStoreClient`'s own `allowedModuleNames` filter
/// (docs/task-index-store-module-scoping.md) -- built the same way `DeclarationLinkerTests.swift`'s
/// own golden-fixture tests are: a real SPM package, indexed for real, read through the real
/// `libIndexStore` C API, no mocking of the index store itself (the whole point is to prove the new
/// `indexstore_shim_unit_reader_get_module_name`/`indexstore_shim_unit_reader_is_system_unit` shim
/// functions work against a real store, not just that the Swift-side filtering logic is internally
/// consistent).
@Suite("RawIndexStoreClient module-name scoping")
struct RawIndexStoreClientModuleScopingTests {
    /// Copies the shared `Fixtures/cross-file-witness` source tree into a fresh, per-test temp
    /// directory before building -- `DeclarationLinkerTests.swift`'s own tests build directly
    /// against the *shared* fixture directory's own `.build` folder, and Swift Testing's default
    /// parallel execution means multiple tests deleting/rebuilding that same shared `.build`
    /// concurrently is a real, confirmed race (`swift build` exiting 1 mid-build when another test's
    /// own delete-then-rebuild interleaves). A private, unique-per-test copy makes each of this
    /// suite's own tests fully independent of both each other and of the other file's tests.
    private func realIndexStore(storeSuffix: String) throws -> (storePath: String, fixtureRoot: URL) {
        let sharedFixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RawIndexStoreClientModuleScopingTests.swift -> IndexStoreIntegrationTests
            .deletingLastPathComponent() // IndexStoreIntegrationTests -> Tests
            .appendingPathComponent("Fixtures/cross-file-witness")
        let unresolvedFixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-isolation-map-test-module-scoping-fixture-\(storeSuffix)")
        try? FileManager.default.removeItem(at: unresolvedFixtureRoot)
        try FileManager.default.copyItem(at: sharedFixtureRoot, to: unresolvedFixtureRoot)
        // `realpath(3)`, not `URL.resolvingSymlinksInPath()` -- confirmed directly (a standalone
        // real check against this exact machine's own `NSTemporaryDirectory()`) that Foundation's
        // own API leaves `/var/folders/...` completely unresolved, silently returning its input
        // unchanged; `realpath` correctly resolves it to `/private/var/folders/...`. Matters here
        // specifically because `/var` is a real symlink to `/private/var` on macOS, and the
        // compiler/index store records the *resolved*, canonical absolute path for the working
        // directory it actually compiled in -- an unresolved `fixtureRoot` here would never match
        // what `definedSymbols(inFile:)` looks up by, later.
        var realpathBuffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolvedFixtureRoot.path, &realpathBuffer) != nil else {
            throw CocoaError(.fileReadUnknown)
        }
        let fixtureRoot = URL(fileURLWithPath: String(cString: realpathBuffer))
        try? FileManager.default.removeItem(at: fixtureRoot.appendingPathComponent(".build"))

        let indexStorePath = NSTemporaryDirectory() + "swift-isolation-map-test-module-scoping-\(storeSuffix)"
        try? FileManager.default.removeItem(atPath: indexStorePath)

        let processRunner = LiveProcessRunner()
        let buildResult = try processRunner.run(
            executable: "swift",
            arguments: ["build", "-Xswiftc", "-index-store-path", "-Xswiftc", indexStorePath],
            workingDirectory: fixtureRoot
        )
        #expect(buildResult.exitCode == 0, "fixture build failed: \(buildResult.standardError)")
        return (indexStorePath, fixtureRoot)
    }

    @Test("allowedModuleNames: nil (the default) scans the whole store, unchanged from this type's original behavior")
    func nilAllowedModuleNamesScansEverything() throws {
        let (storePath, fixtureRoot) = try realIndexStore(storeSuffix: "nil-filter")
        let client = try RawIndexStoreClient(storePath: storePath, allowedModuleNames: nil)
        #expect(client.skippedUnitCount == 0)
        let sourceFile = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness/SyncCoordinator.swift").path
        #expect(!client.definedSymbols(inFile: sourceFile).isEmpty, "no filtering at all must still find the fixture's own real symbols")
    }

    @Test("allowedModuleNames containing the fixture's own real module name (CrossFileWitness) keeps its declarations, same as no filtering at all")
    func allowedModuleNamesIncludingTheRealModuleKeepsDeclarations() throws {
        let (storePath, fixtureRoot) = try realIndexStore(storeSuffix: "included")
        let unfiltered = try RawIndexStoreClient(storePath: storePath, allowedModuleNames: nil)
        let filtered = try RawIndexStoreClient(storePath: storePath, allowedModuleNames: ["CrossFileWitness"])

        let sourceFile = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness/SyncCoordinator.swift").path
        #expect(!unfiltered.definedSymbols(inFile: sourceFile).isEmpty, "sanity: the unfiltered baseline genuinely has real symbols for this file")
        #expect(
            filtered.definedSymbols(inFile: sourceFile) == unfiltered.definedSymbols(inFile: sourceFile),
            "explicitly allowing the fixture's own real module must produce byte-identical results to no filtering at all, for the fixture's own file"
        )
    }

    @Test("allowedModuleNames NOT containing the fixture's own real module name excludes every declaration -- the real shape this filter exists for (a shared index store's own stray, unrelated module)")
    func allowedModuleNamesExcludingTheRealModuleDropsEverything() throws {
        let (storePath, fixtureRoot) = try realIndexStore(storeSuffix: "excluded")
        let filtered = try RawIndexStoreClient(storePath: storePath, allowedModuleNames: ["SomeUnrelatedModuleNeverCompiledHere"])
        // `CrossFileWitness` itself is an ordinary Swift module compile, never a Clang system
        // module -- unlike the SDK exemption `systemUnitsSurviveFilteringEvenWhenNotInAllowList`
        // covers below, it has no `is_system_unit` escape hatch, so excluding it from the allow-
        // list must still skip its own unit.
        #expect(filtered.skippedUnitCount > 0, "the fixture's only real, non-system unit must have been skipped -- its module name isn't in the allow-list")

        let sourceFile = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness/SyncCoordinator.swift").path
        #expect(filtered.definedSymbols(inFile: sourceFile).isEmpty, "excluding the fixture's own real module must leave no real declarations behind")
    }

    /// The `is_system_unit` exemption (docs/task-index-store-module-scoping.md, Step 4/5) --
    /// confirmed real on Project Iris via a full corpus regression before this existed
    /// (`crossActorBoundaries` 1790->23198): a positive allow-list built from the app's own real
    /// *Swift* `-module-name` values can never contain a precompiled SDK/Clang-module's own name
    /// (`AppKit` here; `UIKit`/`Foundation`/... on Project Iris), so filtering by that allow-list
    /// alone silently discards every SDK/Clang-module unit's own declaration data.
    /// `ExtensionOfExternalType.swift`'s `extension NSView { func realExtensionMethod() {} }`
    /// exercises exactly the data this exemption protects: `extendedTypeUSR`/`baseTypeUSRs` for
    /// `NSView` only resolve to real base types (`NSResponder`, ...) when AppKit's own indexed
    /// unit contributed that `.baseOf` relation data -- the fixture's own `CrossFileWitness` unit
    /// has no such data about a type it doesn't itself declare.
    @Test("A system (SDK/Clang-module) unit like AppKit's own survives allowedModuleNames filtering even when \"AppKit\" isn't in the allow-list")
    func systemUnitsSurviveFilteringEvenWhenAppKitIsNotInTheAllowList() throws {
        let (storePath, fixtureRoot) = try realIndexStore(storeSuffix: "system-exemption")
        // "AppKit" deliberately absent -- only the fixture's own module is ever explicitly allowed.
        let filtered = try RawIndexStoreClient(storePath: storePath, allowedModuleNames: ["CrossFileWitness"])

        let extensionFile = fixtureRoot.appendingPathComponent("Sources/CrossFileWitness/ExtensionOfExternalType.swift").path
        let symbols = filtered.definedSymbols(inFile: extensionFile)
        guard let method = symbols.first(where: { $0.name == "realExtensionMethod()" }) else {
            Issue.record("expected to find realExtensionMethod() in the fixture's own extension file; symbols: \(symbols)")
            return
        }
        guard let extensionUSR = filtered.containingExtensionUSR(forMemberUSR: method.usr) else {
            Issue.record("expected realExtensionMethod() to have a containing extension USR")
            return
        }
        guard let extendedTypeUSR = filtered.extendedTypeUSR(forExtensionUSR: extensionUSR) else {
            Issue.record("expected the extension's own extendedTypeUSR to resolve to NSView's real USR")
            return
        }
        #expect(extendedTypeUSR == "c:objc(cs)NSView")

        let baseTypeNames = Set(filtered.baseTypeUSRs(forUSR: extendedTypeUSR).map(\.name))
        #expect(
            baseTypeNames.contains("NSResponder"),
            "NSView's own real AppKit base type must still be discoverable even though \"AppKit\" was never in allowedModuleNames -- this is exactly the data the original (fixed) regression lost"
        )
    }
}
