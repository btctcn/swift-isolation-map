import Foundation
import Testing
@testable import ProjectResolution

/// Real `module.modulemap` text captured this session from a real, built `~/ios` dependency
/// (`ActionSheetPicker-3.0`'s framework, Xcode 26.4.0) -- this framework has no
/// `Modules/*.swiftmodule` directory at all, only a modulemap, and its real module name
/// (`ActionSheetPicker_3_0`, underscores) differs from its search-path directory name
/// (`ActionSheetPicker-3.0`, a dash -- not a valid Swift identifier), confirming why the directory
/// basename can never be trusted directly.
private let realActionSheetPickerModulemap = """
framework module ActionSheetPicker_3_0 {
  umbrella header "ActionSheetPicker-3.0-umbrella.h"

  export *
  module * { export * }
}
"""

/// Real `module.modulemap` text captured the same way from `Kingfisher.framework` -- this
/// framework, unlike the one above, *also* ships a `Modules/Kingfisher.swiftmodule` directory,
/// which `realModuleName(ofFrameworkAt:fileSystem:)` must prefer over parsing this text at all.
private let realKingfisherModulemap = """
framework module Kingfisher {
  umbrella header "Kingfisher-umbrella.h"

  export *
  module * { export * }
}

module Kingfisher.Swift {
  header "Kingfisher-Swift.h"
}
"""

@Suite("FrameworkModuleDiscovery")
struct FrameworkModuleDiscoveryTests {
    @Test("moduleName(fromModulemapText:) parses a real 'framework module <Name> {' line, real name differing from the search-path directory basename")
    func parsesRealFrameworkModulemap() {
        #expect(FrameworkModuleDiscovery.moduleName(fromModulemapText: realActionSheetPickerModulemap) == "ActionSheetPicker_3_0")
    }

    @Test("realModuleName(ofFrameworkAt:) prefers a Modules/<Name>.swiftmodule directory over parsing the modulemap, when both are present")
    func prefersSwiftmoduleDirectoryOverModulemap() {
        let fileSystem = FakeFileSystem()
        let frameworkURL = URL(fileURLWithPath: "/Frameworks/Kingfisher.framework")
        fileSystem.addDirectory(at: frameworkURL.appendingPathComponent("Modules/Kingfisher.swiftmodule"))
        fileSystem.addFile(at: frameworkURL.appendingPathComponent("Modules/module.modulemap"), contents: realKingfisherModulemap)

        let name = FrameworkModuleDiscovery.realModuleName(ofFrameworkAt: frameworkURL, fileSystem: fileSystem)
        #expect(name == "Kingfisher")
    }

    @Test("realModuleName(ofFrameworkAt:) falls back to parsing module.modulemap when there's no swiftmodule directory")
    func fallsBackToModulemapWhenNoSwiftmoduleDirectory() {
        let fileSystem = FakeFileSystem()
        let frameworkURL = URL(fileURLWithPath: "/Frameworks/ActionSheetPicker-3.0/ActionSheetPicker_3_0.framework")
        fileSystem.addFile(at: frameworkURL.appendingPathComponent("Modules/module.modulemap"), contents: realActionSheetPickerModulemap)

        let name = FrameworkModuleDiscovery.realModuleName(ofFrameworkAt: frameworkURL, fileSystem: fileSystem)
        #expect(name == "ActionSheetPicker_3_0")
    }

    @Test("realModuleName(ofFrameworkAt:) returns nil, not a guessed name, when neither a swiftmodule directory nor a parseable modulemap exists")
    func returnsNilWhenNeitherSourceExists() {
        let fileSystem = FakeFileSystem()
        let frameworkURL = URL(fileURLWithPath: "/Frameworks/ObjCOnly.framework")
        fileSystem.addDirectory(at: frameworkURL)

        let name = FrameworkModuleDiscovery.realModuleName(ofFrameworkAt: frameworkURL, fileSystem: fileSystem)
        #expect(name == nil)
    }

    @Test("discoverFrameworks(inSearchPaths:) finds every .framework bundle across multiple search paths, keyed by real module name, carrying -F as its extraction flag")
    func discoversFrameworksAcrossSearchPaths() {
        let fileSystem = FakeFileSystem()
        let searchPathA = "/DerivedData/Debug-iphoneos"
        let searchPathB = "/DerivedData/Debug-iphoneos/ActionSheetPicker-3.0"
        fileSystem.addDirectory(at: URL(fileURLWithPath: searchPathA).appendingPathComponent("Kingfisher.framework/Modules/Kingfisher.swiftmodule"))
        fileSystem.addFile(
            at: URL(fileURLWithPath: searchPathB).appendingPathComponent("ActionSheetPicker_3_0.framework/Modules/module.modulemap"),
            contents: realActionSheetPickerModulemap
        )

        let discovered = FrameworkModuleDiscovery.discoverFrameworks(inSearchPaths: [searchPathA, searchPathB], fileSystem: fileSystem)
        #expect(discovered.contains(DiscoveredModule(name: "Kingfisher", extractionFlags: ["-F", searchPathA])))
        #expect(discovered.contains(DiscoveredModule(name: "ActionSheetPicker_3_0", extractionFlags: ["-F", searchPathB])))
    }
}
