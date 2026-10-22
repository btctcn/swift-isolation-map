import Foundation
import Testing
@testable import ProjectResolution

@Test("An SPM package's explicit, self-controlled index store path is found when present")
func spmExplicitPathIsFoundWhenPresent() {
    let fileSystem = FakeFileSystem()
    let packageDirectory = URL(fileURLWithPath: "/project")
    fileSystem.addDirectory(at: packageDirectory.appendingPathComponent(".build/swift-isolation-map-index-store"))

    let locator = IndexStoreLocator(fileSystem: fileSystem)
    let result = locator.locate(for: .swiftPackage(packageDirectory.appendingPathComponent("Package.swift")))

    #expect(result == .found(locator.explicitIndexStorePath(for: packageDirectory)))
}

@Test("SwiftPM's own default location (via the debug symlink SwiftPM always creates) is found when the explicit path is absent")
func spmDefaultLocationIsFoundAsFallback() {
    let fileSystem = FakeFileSystem()
    let packageDirectory = URL(fileURLWithPath: "/project")
    // Real SwiftPM always symlinks `.build/debug -> <triple>/debug`; a fake filesystem doesn't
    // model symlinks, so this registers the *resolved* path the locator actually checks --
    // matching what a real, symlink-following FileManager check would observe.
    let defaultStore = packageDirectory.appendingPathComponent(".build/debug/index/store")
    fileSystem.addDirectory(at: defaultStore)

    let locator = IndexStoreLocator(fileSystem: fileSystem)
    let result = locator.locate(for: .swiftPackage(packageDirectory.appendingPathComponent("Package.swift")))

    #expect(result == .found(defaultStore))
}

@Test("SwiftPM's release-configuration default location is found too, not just debug")
func spmReleaseLocationIsFoundAsFallback() {
    let fileSystem = FakeFileSystem()
    let packageDirectory = URL(fileURLWithPath: "/project")
    let releaseStore = packageDirectory.appendingPathComponent(".build/release/index/store")
    fileSystem.addDirectory(at: releaseStore)

    let locator = IndexStoreLocator(fileSystem: fileSystem)
    let result = locator.locate(for: .swiftPackage(packageDirectory.appendingPathComponent("Package.swift")))

    #expect(result == .found(releaseStore))
}

@Test("An Xcode-triggered index build (a separate root Xcode maintains for SPM packages opened directly) is found too")
func xcodeTriggeredIndexBuildIsFoundAsFallback() {
    let fileSystem = FakeFileSystem()
    let packageDirectory = URL(fileURLWithPath: "/project")
    // Confirmed empirically on real projects opened in Xcode: `.build/index-build/debug ->
    // <triple>/debug`, a second, separate root distinct from the plain command-line one.
    let xcodeIndexBuildStore = packageDirectory.appendingPathComponent(".build/index-build/debug/index/store")
    fileSystem.addDirectory(at: xcodeIndexBuildStore)

    let locator = IndexStoreLocator(fileSystem: fileSystem)
    let result = locator.locate(for: .swiftPackage(packageDirectory.appendingPathComponent("Package.swift")))

    #expect(result == .found(xcodeIndexBuildStore))
}

@Test("The plain .build root is preferred over the Xcode-triggered index-build root when both exist")
func plainBuildRootIsPreferredOverIndexBuildRoot() {
    let fileSystem = FakeFileSystem()
    let packageDirectory = URL(fileURLWithPath: "/project")
    let plainStore = packageDirectory.appendingPathComponent(".build/debug/index/store")
    let xcodeStore = packageDirectory.appendingPathComponent(".build/index-build/debug/index/store")
    fileSystem.addDirectory(at: plainStore)
    fileSystem.addDirectory(at: xcodeStore)

    let locator = IndexStoreLocator(fileSystem: fileSystem)
    let result = locator.locate(for: .swiftPackage(packageDirectory.appendingPathComponent("Package.swift")))

    #expect(result == .found(plainStore))
}

@Test("The new swiftbuild-backend's .build/out root is found as a fallback, confirmed by its v5 subdirectory")
func swiftBuildBackendOutRootIsFoundAsFallback() {
    let fileSystem = FakeFileSystem()
    let packageDirectory = URL(fileURLWithPath: "/project")
    // Real shape confirmed in docs/task-swiftpm-swiftbuild-backend-migration.md: under the new
    // default `swiftbuild` build system, `--auto-index-store` writes real index data directly
    // under `.build/out`, ignoring any `-Xswiftc -index-store-path` override.
    fileSystem.addDirectory(at: packageDirectory.appendingPathComponent(".build/out/v5"))

    let locator = IndexStoreLocator(fileSystem: fileSystem)
    let result = locator.locate(for: .swiftPackage(packageDirectory.appendingPathComponent("Package.swift")))

    #expect(result == .found(packageDirectory.appendingPathComponent(".build/out")))
}

@Test("A .build/out directory with no v5 subdirectory (e.g. a release-config build under the new backend) is not mistaken for an index store")
func swiftBuildBackendOutRootWithoutV5IsNotMistakenForAStore() {
    let fileSystem = FakeFileSystem()
    let packageDirectory = URL(fileURLWithPath: "/project")
    // Confirmed empirically: a release-config build under the new backend produces a real
    // `.build/out` directory (Products/, Intermediates.noindex/, ...) but no index data at all --
    // `.build/out`'s own existence must not be enough to report `.found`.
    fileSystem.addDirectory(at: packageDirectory.appendingPathComponent(".build/out/Products"))

    let locator = IndexStoreLocator(fileSystem: fileSystem)
    let result = locator.locate(for: .swiftPackage(packageDirectory.appendingPathComponent("Package.swift")))

    #expect(result == .missing)
}

@Test("An SPM package with no index store anywhere is reported missing")
func spmMissingWhenNoStoreExists() {
    let fileSystem = FakeFileSystem()
    let packageDirectory = URL(fileURLWithPath: "/project")
    fileSystem.addDirectory(at: packageDirectory.appendingPathComponent(".build"))

    let locator = IndexStoreLocator(fileSystem: fileSystem)
    let result = locator.locate(for: .swiftPackage(packageDirectory.appendingPathComponent("Package.swift")))

    #expect(result == .missing)
}

@Test("An Xcode project's DerivedData index store is found by matching the project name prefix")
func xcodeDerivedDataIsFoundByNamePrefix() {
    let fileSystem = FakeFileSystem()
    let derivedDataRoot = URL(fileURLWithPath: "/Users/dev/Library/Developer/Xcode/DerivedData")
    let dataStore = derivedDataRoot.appendingPathComponent("MyProject-abcxyz123/Index.noindex/DataStore")
    fileSystem.addDirectory(at: dataStore)

    let locator = IndexStoreLocator(fileSystem: fileSystem, derivedDataRoot: derivedDataRoot)
    let result = locator.locate(for: .xcodeproj(URL(fileURLWithPath: "/project/MyProject.xcodeproj")))

    #expect(result == .found(dataStore))
}

@Test("An Xcode project with no matching DerivedData entry is reported missing")
func xcodeMissingWhenNoMatchingDerivedDataEntry() {
    let fileSystem = FakeFileSystem()
    let derivedDataRoot = URL(fileURLWithPath: "/Users/dev/Library/Developer/Xcode/DerivedData")
    fileSystem.addDirectory(at: derivedDataRoot.appendingPathComponent("OtherProject-xyz/Index.noindex/DataStore"))

    let locator = IndexStoreLocator(fileSystem: fileSystem, derivedDataRoot: derivedDataRoot)
    let result = locator.locate(for: .xcodeproj(URL(fileURLWithPath: "/project/MyProject.xcodeproj")))

    #expect(result == .missing)
}
