import Foundation
import Testing
@testable import ProjectResolution

/// EXPERIMENTAL (docs/task-private-derived-data-hypothesis.md) -- `PrivateDerivedData` itself has
/// no I/O beyond `realpath(3)` (a real, existing path is required for that call to succeed, so
/// these tests use real temp directories, not synthetic paths) -- no fixture project/build needed.
@Suite("PrivateDerivedData composite key")
struct PrivateDerivedDataLocatorTests {
    private func makeRealDirectory(named name: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("cacheRoot() lives under ~/Library/Caches, never Xcode's own ~/Library/Developer/Xcode/DerivedData")
    func cacheRootIsUnderLibraryCaches() {
        let root = PrivateDerivedData.cacheRoot()
        #expect(root.path.contains("/Library/Caches/swift-isolation-map/DerivedData"))
        #expect(!root.path.contains("Xcode/DerivedData"))
    }

    @Test("sanitized(_:) keeps alphanumerics/-/_/. and replaces everything else with _")
    func sanitizedReplacesUnsafeCharacters() {
        #expect(PrivateDerivedData.sanitized("Ls_net_ru") == "Ls_net_ru")
        #expect(PrivateDerivedData.sanitized("generic/platform=iOS Simulator") == "generic_platform_iOS_Simulator")
        #expect(PrivateDerivedData.sanitized("My Scheme Name") == "My_Scheme_Name")
        #expect(PrivateDerivedData.sanitized("") == "_")
    }

    @Test("projectIdentityHash is deterministic for the identical real path")
    func projectIdentityHashIsDeterministic() throws {
        let directory = try makeRealDirectory(named: "swift-isolation-map-test-private-dd-\(UUID().uuidString)")
        let container = directory.appendingPathComponent("Foo.xcworkspace")
        let first = PrivateDerivedData.projectIdentityHash(for: container)
        let second = PrivateDerivedData.projectIdentityHash(for: container)
        #expect(first == second)
        #expect(first.count == 8)
    }

    @Test("projectIdentityHash differs for two different real checkouts, even with the identical basename -- two branches/worktrees of the same repo must never share a cache")
    func projectIdentityHashDiffersForDifferentCheckouts() throws {
        let checkoutA = try makeRealDirectory(named: "swift-isolation-map-test-checkout-a-\(UUID().uuidString)")
        let checkoutB = try makeRealDirectory(named: "swift-isolation-map-test-checkout-b-\(UUID().uuidString)")
        let containerA = checkoutA.appendingPathComponent("Foo.xcworkspace")
        let containerB = checkoutB.appendingPathComponent("Foo.xcworkspace")
        #expect(PrivateDerivedData.projectIdentityHash(for: containerA) != PrivateDerivedData.projectIdentityHash(for: containerB))
    }

    @Test("path(for:scheme:destination:) nests scheme, destination, and configuration as separate, sanitized path components under one project-identity directory")
    func pathNestsComponentsSeparately() throws {
        let directory = try makeRealDirectory(named: "swift-isolation-map-test-private-dd-path-\(UUID().uuidString)")
        let container = ProjectContainer.xcworkspace(directory.appendingPathComponent("lsboutique.xcworkspace"))

        let path = PrivateDerivedData.path(for: container, scheme: "ls.net.ru", destination: "generic/platform=iOS Simulator")

        let components = path.pathComponents
        #expect(components.contains("ls.net.ru"))
        #expect(components.contains("generic_platform_iOS_Simulator"))
        #expect(components.contains("default"))
        #expect(path.path.hasPrefix(PrivateDerivedData.cacheRoot().path))
        // Project-identity segment: human-readable basename plus a hash, not just the bare basename
        // (docs/task-private-derived-data-hypothesis.md Step 3) -- confirmed by shape, not just
        // presence, since a coincidental substring match elsewhere in the path isn't proof.
        #expect(components.contains { $0.hasPrefix("lsboutique-") && $0.count == "lsboutique-".count + 8 })
    }

    @Test("path(for:scheme:destination:) differs when only the scheme differs -- the exact cross-scheme pollution scenario this design exists to prevent")
    func pathDiffersByScheme() throws {
        let directory = try makeRealDirectory(named: "swift-isolation-map-test-private-dd-scheme-\(UUID().uuidString)")
        let container = ProjectContainer.xcworkspace(directory.appendingPathComponent("lsboutique.xcworkspace"))

        let appPath = PrivateDerivedData.path(for: container, scheme: "ls.net.ru", destination: "generic/platform=iOS Simulator")
        let testsPath = PrivateDerivedData.path(for: container, scheme: "lsboutiqueTests", destination: "generic/platform=iOS Simulator")

        #expect(appPath != testsPath)
    }

    @Test("path(for:scheme:destination:) differs when only the destination differs -- a same-scheme, different-platform run must not silently mix variants into one store")
    func pathDiffersByDestination() throws {
        let directory = try makeRealDirectory(named: "swift-isolation-map-test-private-dd-destination-\(UUID().uuidString)")
        let container = ProjectContainer.xcworkspace(directory.appendingPathComponent("lsboutique.xcworkspace"))

        let simulatorPath = PrivateDerivedData.path(for: container, scheme: "ls.net.ru", destination: "generic/platform=iOS Simulator")
        let devicePath = PrivateDerivedData.path(for: container, scheme: "ls.net.ru", destination: "generic/platform=iOS")

        #expect(simulatorPath != devicePath)
    }

    @Test("path(for:scheme:destination:) falls back to a stable sentinel when destination is nil, rather than colliding with a real destination string")
    func pathHandlesNilDestination() throws {
        let directory = try makeRealDirectory(named: "swift-isolation-map-test-private-dd-nil-destination-\(UUID().uuidString)")
        let container = ProjectContainer.xcworkspace(directory.appendingPathComponent("lsboutique.xcworkspace"))

        let path = PrivateDerivedData.path(for: container, scheme: "ls.net.ru", destination: nil)
        #expect(path.pathComponents.contains("unknown-destination"))
    }
}
