import Foundation
import Testing
@testable import ProjectResolution
@testable import swift_isolation_map

@Suite("StalenessOrchestration")
struct StalenessOrchestrationTests {
    @Test("manifestURL: sibling of Package.swift, not inside .build")
    func manifestURLIsProjectRootSibling() {
        let packageURL = URL(fileURLWithPath: "/repo/MyPackage/Package.swift")
        let manifestURL = StalenessOrchestration.manifestURL(for: .swiftPackage(packageURL))
        #expect(manifestURL.path == "/repo/MyPackage/.swift-isolation-map-manifest.json")
    }

    @Test("manifestURL: sibling of .xcodeproj")
    func manifestURLForXcodeproj() {
        let projectURL = URL(fileURLWithPath: "/repo/App/App.xcodeproj")
        let manifestURL = StalenessOrchestration.manifestURL(for: .xcodeproj(projectURL))
        #expect(manifestURL.path == "/repo/App/.swift-isolation-map-manifest.json")
    }

    @Test("swiftFiles: recursively finds .swift files, skipping .build/.swiftpm/.git/DerivedData")
    func swiftFilesSkipsBuildDirectories() {
        let fileSystem = FakeFileSystem()
        let root = URL(fileURLWithPath: "/repo/MyPackage")
        fileSystem.addFile(at: root.appendingPathComponent("Sources/App/main.swift"), contents: "// main")
        fileSystem.addFile(at: root.appendingPathComponent("Sources/App/Nested/Helper.swift"), contents: "// helper")
        fileSystem.addFile(at: root.appendingPathComponent("Package.swift"), contents: "// package")
        fileSystem.addFile(at: root.appendingPathComponent("README.md"), contents: "# readme")
        fileSystem.addFile(at: root.appendingPathComponent(".build/checkouts/Dep/Source.swift"), contents: "// dep")
        fileSystem.addFile(at: root.appendingPathComponent(".swiftpm/xcode/Config.swift"), contents: "// config")
        fileSystem.addFile(at: root.appendingPathComponent(".git/hooks/Fake.swift"), contents: "// git")

        let found = Set(StalenessOrchestration.swiftFiles(under: root, fileSystem: fileSystem).map(\.path))
        #expect(found == [
            root.appendingPathComponent("Sources/App/main.swift").path,
            root.appendingPathComponent("Sources/App/Nested/Helper.swift").path,
            root.appendingPathComponent("Package.swift").path
        ])
    }

    @Test("loadManifest: nil when the file doesn't exist")
    func loadManifestNilWhenMissing() {
        let fileSystem = FakeFileSystem()
        let url = URL(fileURLWithPath: "/repo/.swift-isolation-map-manifest.json")
        #expect(StalenessOrchestration.loadManifest(at: url, fileSystem: fileSystem) == nil)
    }

    @Test("loadManifest: nil when the file exists but doesn't decode as a manifest")
    func loadManifestNilWhenUndecodable() {
        let fileSystem = FakeFileSystem()
        let url = URL(fileURLWithPath: "/repo/.swift-isolation-map-manifest.json")
        fileSystem.addFile(at: url, contents: "not json")
        #expect(StalenessOrchestration.loadManifest(at: url, fileSystem: fileSystem) == nil)
    }

    @Test("writeManifest then loadManifest round-trips")
    func writeThenLoadRoundTrips() throws {
        let fileSystem = FakeFileSystem()
        let url = URL(fileURLWithPath: "/repo/.swift-isolation-map-manifest.json")
        let manifest = StalenessManifest(contentHashesByFilePath: ["/repo/A.swift": "abc123"])

        try StalenessOrchestration.writeManifest(manifest, to: url, fileSystem: fileSystem)
        let loaded = StalenessOrchestration.loadManifest(at: url, fileSystem: fileSystem)
        #expect(loaded == manifest)
    }
}
