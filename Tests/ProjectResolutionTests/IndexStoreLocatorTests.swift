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

@Test("SwiftPM's own default indexing-while-building location is found when the explicit path is absent")
func spmDefaultLocationIsFoundAsFallback() {
    let fileSystem = FakeFileSystem()
    let packageDirectory = URL(fileURLWithPath: "/project")
    let defaultStore = packageDirectory.appendingPathComponent(".build/arm64-apple-macosx/debug/index/store")
    fileSystem.addDirectory(at: defaultStore)

    let locator = IndexStoreLocator(fileSystem: fileSystem)
    let result = locator.locate(for: .swiftPackage(packageDirectory.appendingPathComponent("Package.swift")))

    #expect(result == .found(defaultStore))
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
