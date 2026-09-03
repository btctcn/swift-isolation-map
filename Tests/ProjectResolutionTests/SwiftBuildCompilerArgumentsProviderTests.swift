import Foundation
import Testing
import SwiftBuild
@testable import ProjectResolution

/// Shape confirmed against a real `generateIndexingFileSettings` response captured this session
/// (docs/task-swift-build-prepare-for-indexing-spike.md Step 3) -- one `[String: SWBPropertyListItem]`
/// per source file, `swiftASTCommandArguments` a `.plArray` of `.plString`, plus `sourceFilePath`/
/// `swiftASTModuleName` as bare `.plString`s.
private func realShapedFileInfo(path: String, args: [String], moduleName: String) -> [String: SWBPropertyListItem] {
    [
        "sourceFilePath": .plString(path),
        "swiftASTCommandArguments": .plArray(args.map { .plString($0) }),
        "swiftASTModuleName": .plString(moduleName),
        // Real responses carry several more keys (outputFilePath, LanguageDialect,
        // swiftASTBuiltProductsDir, toolchains, assetSymbolIndexPath) this parser never reads --
        // included so the parser's own field selection (not "reads everything present") is what's
        // under test.
        "LanguageDialect": .plString("swift"),
        "outputFilePath": .plString("/DerivedData/Foo.build/\((path as NSString).lastPathComponent).o")
    ]
}

@Test("A single target's real-shaped response is parsed into a file -> arguments map, plus its module name")
func parsesOneTargetsRealShapedResponse() {
    let info = realShapedFileInfo(
        path: "/repo/App/AppGroupFetcher.swift",
        args: ["-module-name", "Ls_net_ru", "-Onone", "-target", "arm64-apple-ios15.6-simulator"],
        moduleName: "Ls_net_ru"
    )

    let (map, moduleNames) = SwiftBuildCompilerArgumentsProvider.parseIndexingFileSettings([info])

    #expect(map["/repo/App/AppGroupFetcher.swift"] == ["-module-name", "Ls_net_ru", "-Onone", "-target", "arm64-apple-ios15.6-simulator"])
    #expect(moduleNames == ["Ls_net_ru"])
}

@Test("Multiple files in one response all get their own entry")
func parsesMultipleFilesFromOneResponse() {
    let infos = [
        realShapedFileInfo(path: "/repo/A.swift", args: ["-module-name", "M"], moduleName: "M"),
        realShapedFileInfo(path: "/repo/B.swift", args: ["-module-name", "M"], moduleName: "M")
    ]

    let (map, moduleNames) = SwiftBuildCompilerArgumentsProvider.parseIndexingFileSettings(infos)

    #expect(Set(map.keys) == ["/repo/A.swift", "/repo/B.swift"])
    #expect(moduleNames == ["M"])
}

@Test("An entry missing sourceFilePath is skipped, not crashed on or emitted with an empty key")
func skipsEntryMissingSourceFilePath() {
    var info = realShapedFileInfo(path: "/repo/A.swift", args: ["-module-name", "M"], moduleName: "M")
    info["sourceFilePath"] = nil

    let (map, moduleNames) = SwiftBuildCompilerArgumentsProvider.parseIndexingFileSettings([info])

    #expect(map.isEmpty)
    #expect(moduleNames.isEmpty)
}

@Test("An entry missing swiftASTCommandArguments is skipped -- a file with no real args is not a usable answer")
func skipsEntryMissingCommandArguments() {
    var info = realShapedFileInfo(path: "/repo/A.swift", args: ["-module-name", "M"], moduleName: "M")
    info["swiftASTCommandArguments"] = nil

    let (map, moduleNames) = SwiftBuildCompilerArgumentsProvider.parseIndexingFileSettings([info])

    #expect(map.isEmpty)
    #expect(moduleNames.isEmpty)
}

@Test("A non-string item inside swiftASTCommandArguments is dropped, not turned into a crash or a garbage string")
func dropsNonStringArgumentItems() {
    var info = realShapedFileInfo(path: "/repo/A.swift", args: ["-module-name", "M"], moduleName: "M")
    info["swiftASTCommandArguments"] = .plArray([.plString("-module-name"), .plBool(true), .plString("M")])

    let (map, _) = SwiftBuildCompilerArgumentsProvider.parseIndexingFileSettings([info])

    #expect(map["/repo/A.swift"] == ["-module-name", "M"])
}

@Test("A missing swiftASTModuleName is tolerated -- the file's arguments still get recorded")
func toleratesMissingModuleName() {
    var info = realShapedFileInfo(path: "/repo/A.swift", args: ["-module-name", "M"], moduleName: "M")
    info["swiftASTModuleName"] = nil

    let (map, moduleNames) = SwiftBuildCompilerArgumentsProvider.parseIndexingFileSettings([info])

    #expect(map["/repo/A.swift"] == ["-module-name", "M"])
    #expect(moduleNames.isEmpty)
}

@Test("Module names union across every target's response, not just the last one parsed")
func moduleNamesUnionAcrossResponses() {
    let a = realShapedFileInfo(path: "/repo/A.swift", args: ["-module-name", "ModuleA"], moduleName: "ModuleA")
    let b = realShapedFileInfo(path: "/repo/B.swift", args: ["-module-name", "ModuleB"], moduleName: "ModuleB")

    let (_, moduleNames) = SwiftBuildCompilerArgumentsProvider.parseIndexingFileSettings([a, b])

    #expect(moduleNames == ["ModuleA", "ModuleB"])
}

@Test("matchesSimulatorPlatform accepts real iPhoneSimulator SDK args when iphonesimulator was requested")
func matchesSimulatorPlatformAcceptsRealIPhoneSimulatorArgs() {
    let args = ["-target", "arm64-apple-ios18.6-simulator", "-sdk", "/Applications/Xcode-26.4.0.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.4.sdk"]

    #expect(SwiftBuildCompilerArgumentsProvider.matchesSimulatorPlatform(args, sdkFamily: .iphonesimulator))
}

@Test("matchesSimulatorPlatform rejects a real AppleTVSimulator SDK when iphonesimulator was requested -- a platform-incompatible target silently returning its own native platform, not an error")
func matchesSimulatorPlatformRejectsRealAppleTVSimulatorArgsUnderIOSRequest() {
    // Real shape captured this session (issue #124): forcing `platform: "iphonesimulator"` on
    // Swiftfin's own `Swiftfin tvOS` target didn't error -- `generateIndexingFileSettings` silently
    // returned this target's own real, natively-appropriate tvOS Simulator args instead.
    let args = ["-target", "x86_64-apple-tvos26.1-simulator", "-sdk", "/Applications/Xcode-26.4.0.app/Contents/Developer/Platforms/AppleTVSimulator.platform/Developer/SDKs/AppleTVSimulator26.4.sdk"]

    #expect(!SwiftBuildCompilerArgumentsProvider.matchesSimulatorPlatform(args, sdkFamily: .iphonesimulator))
}

@Test("matchesSimulatorPlatform accepts the same real AppleTVSimulator SDK args when appletvsimulator was requested -- issue #124's own real fix")
func matchesSimulatorPlatformAcceptsRealAppleTVSimulatorArgsUnderTVOSRequest() {
    let args = ["-target", "x86_64-apple-tvos26.1-simulator", "-sdk", "/Applications/Xcode-26.4.0.app/Contents/Developer/Platforms/AppleTVSimulator.platform/Developer/SDKs/AppleTVSimulator26.4.sdk"]

    #expect(SwiftBuildCompilerArgumentsProvider.matchesSimulatorPlatform(args, sdkFamily: .appletvsimulator))
}

@Test("matchesSimulatorPlatform accepts real watchOS/visionOS Simulator SDK args when the matching family was requested")
func matchesSimulatorPlatformAcceptsWatchOSAndVisionOSArgs() {
    let watchArgs = ["-sdk", "/Applications/Xcode-26.4.0.app/.../WatchSimulator26.4.sdk"]
    let visionArgs = ["-sdk", "/Applications/Xcode-26.4.0.app/.../XRSimulator26.4.sdk"]

    #expect(SwiftBuildCompilerArgumentsProvider.matchesSimulatorPlatform(watchArgs, sdkFamily: .watchsimulator))
    #expect(SwiftBuildCompilerArgumentsProvider.matchesSimulatorPlatform(visionArgs, sdkFamily: .xrsimulator))
}

@Test("matchesSimulatorPlatform rejects args with no -sdk flag at all, rather than crashing or defaulting to true")
func matchesSimulatorPlatformRejectsMissingSDKFlag() {
    #expect(!SwiftBuildCompilerArgumentsProvider.matchesSimulatorPlatform(["-module-name", "M"], sdkFamily: .iphonesimulator))
}

// MARK: - SimulatorSDKFamily.parsing (issue #124)

@Test("SimulatorSDKFamily.parsing recognizes every real resolveDeterministicSimulatorDestination() platform name")
func simulatorSDKFamilyParsingRecognizesEveryRealPlatformName() {
    #expect(SimulatorSDKFamily.parsing(destination: "generic/platform=iOS Simulator") == .iphonesimulator)
    #expect(SimulatorSDKFamily.parsing(destination: "generic/platform=tvOS Simulator") == .appletvsimulator)
    #expect(SimulatorSDKFamily.parsing(destination: "generic/platform=watchOS Simulator") == .watchsimulator)
    #expect(SimulatorSDKFamily.parsing(destination: "generic/platform=visionOS Simulator") == .xrsimulator)
}

@Test("SimulatorSDKFamily.parsing returns nil for a nil destination (a pure macOS/host scheme) or an unrecognized platform name")
func simulatorSDKFamilyParsingReturnsNilForNilOrUnrecognized() {
    #expect(SimulatorSDKFamily.parsing(destination: nil) == nil)
    #expect(SimulatorSDKFamily.parsing(destination: "generic/platform=macOS") == nil)
    #expect(SimulatorSDKFamily.parsing(destination: "not a real destination string") == nil)
}

@Test("preferredArguments picks the single candidate whose target name is a path component of the file -- the real WordPress-iOS shape (WordPressShareExtension vs WordPressDraftActionExtension)")
func preferredArgumentsPicksTheFilesOwnHomeTarget() {
    let filePath = "/Users/dev/WordPress-iOS/WordPress/WordPressShareExtension/Sources/Extensions/WPStyleGuide+Share.swift"
    let candidates = [
        (targetName: "WordPressDraftActionExtension", args: ["-module-name", "WordPressDraftActionExtension"]),
        (targetName: "WordPressShareExtension", args: ["-module-name", "WordPressShareExtension"])
    ]

    let chosen = SwiftBuildCompilerArgumentsProvider.preferredArguments(candidates: candidates, filePath: filePath)

    #expect(chosen == ["-module-name", "WordPressShareExtension"])
}

@Test("preferredArguments falls back to the first candidate when no target name matches the file's own path -- the overwhelmingly common one-file-one-target case")
func preferredArgumentsFallsBackToFirstWhenNoNameMatches() {
    let filePath = "/Users/dev/App/Sources/Feature.swift"
    let candidates = [
        (targetName: "App", args: ["-module-name", "App"]),
        (targetName: "AppTests", args: ["-module-name", "AppTests"])
    ]

    let chosen = SwiftBuildCompilerArgumentsProvider.preferredArguments(candidates: candidates, filePath: filePath)

    #expect(chosen == ["-module-name", "App"])
}

@Test("preferredArguments falls back to the first candidate when more than one target name matches -- an ambiguous case with no principled tiebreak, kept deterministic rather than guessed at")
func preferredArgumentsFallsBackToFirstWhenMultipleNamesMatch() {
    let filePath = "/Users/dev/Workspace/Shared/Shared/Utility.swift"
    let candidates = [
        (targetName: "Shared", args: ["-module-name", "SharedFirst"]),
        (targetName: "Shared", args: ["-module-name", "SharedSecond"])
    ]

    let chosen = SwiftBuildCompilerArgumentsProvider.preferredArguments(candidates: candidates, filePath: filePath)

    #expect(chosen == ["-module-name", "SharedFirst"])
}

@Test("Arena paths are subpaths of the given derivedDataPath, matching the on-disk layout a real -derivedDataPath build produces")
func arenaInfoDerivesRealOnDiskLayout() {
    let derivedDataPath = URL(fileURLWithPath: "/Users/dev/Library/Caches/swift-isolation-map/DerivedData/MyApp-abcd1234/MyScheme/generic_platform_iOS_Simulator/default")

    let arena = SwiftBuildCompilerArgumentsProvider.arenaInfo(derivedDataPath: derivedDataPath)

    #expect(arena.derivedDataPath == derivedDataPath.path)
    #expect(arena.buildProductsPath == derivedDataPath.path + "/Build/Products")
    #expect(arena.buildIntermediatesPath == derivedDataPath.path + "/Build/Intermediates.noindex")
    #expect(arena.indexDataStoreFolderPath == derivedDataPath.path + "/Index.noindex/DataStore")
    #expect(arena.indexEnableDataStore == true)
}
