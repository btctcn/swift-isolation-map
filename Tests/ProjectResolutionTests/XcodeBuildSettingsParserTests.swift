import Foundation
import Testing
@testable import ProjectResolution

/// Real lines captured this session from `xcodebuild -showBuildSettings -workspace
/// <Project Iris's .xcworkspace> -scheme <Project Iris's scheme>` (Xcode 26.4.0) -- confirmed to
/// be fast and read-only (no build triggered), unlike `-verbose build`. Kept as real excerpted
/// lines, not a hand-assembled fixture, per this project's standing "verify real output, don't
/// guess format" discipline; the real four-space indent + ` = ` separator shape is exactly what's
/// tested. Project Iris is a private real-world validation corpus -- see
/// docs/reference-project-corpora.md -- so its own project/scheme/pod names are not used here.
private let realProjectIrisBuildSettingsExcerpt = """
Build settings for action build and target SomeScheme:
    ARCHS = arm64
    DEPLOYMENT_TARGET_SETTING_NAME = IPHONEOS_DEPLOYMENT_TARGET
    EFFECTIVE_PLATFORM_NAME = -iphoneos
    FRAMEWORK_SEARCH_PATHS = /Users/ab/Library/Developer/Xcode/DerivedData/ProjectIris-frhndxbzytxjwahilecqaixiieah/Build/Products/Debug-iphoneos  "/Users/ab/Library/Developer/Xcode/DerivedData/ProjectIris-frhndxbzytxjwahilecqaixiieah/Build/Products/Debug-iphoneos/Kingfisher" /Users/ab/ProjectIris/Vendors
    IPHONEOS_DEPLOYMENT_TARGET = 15.6
    MACOSX_DEPLOYMENT_TARGET = 26.4
    PLATFORM_NAME = iphoneos
    PODS_ROOT = /Users/ab/ProjectIris/Pods
    SDKROOT = /Applications/Xcode-26.4.0.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.4.sdk
    SWIFT_VERSION = 5.0
"""

@Suite("XcodeBuildSettingsParser")
struct XcodeBuildSettingsParserTests {
    @Test("parse() reads real 'KEY = VALUE' lines, ignoring the non-setting header line")
    func parsesRealCapturedSettings() {
        let settings = XcodeBuildSettingsParser.parse(output: realProjectIrisBuildSettingsExcerpt)
        #expect(settings["ARCHS"] == "arm64")
        #expect(settings["PLATFORM_NAME"] == "iphoneos")
        #expect(settings["DEPLOYMENT_TARGET_SETTING_NAME"] == "IPHONEOS_DEPLOYMENT_TARGET")
        #expect(settings["IPHONEOS_DEPLOYMENT_TARGET"] == "15.6")
        #expect(settings["PODS_ROOT"] == "/Users/ab/ProjectIris/Pods")
        #expect(settings["SDKROOT"]?.hasSuffix("iPhoneOS26.4.sdk") == true)
        // The real, unmodified multi-value line (mixed quoted/unquoted entries) -- callers tokenize
        // this themselves with the existing `CompilerArgsLogParser.tokenize`.
        #expect(settings["FRAMEWORK_SEARCH_PATHS"]?.contains("Kingfisher") == true)
    }

    @Test("parse() keeps the first occurrence of a key, not the last")
    func keepsFirstOccurrence() {
        let output = """
            KEY = first
            KEY = second
            """
        #expect(XcodeBuildSettingsParser.parse(output: output)["KEY"] == "first")
    }

    @Test("targetTriple: real confirmed iOS-device mapping ('ios', not 'iphoneos') -- verified empirically this session: 'arm64-apple-iphoneos15.6' silently produced garbage from a real symbolgraph-extract call, 'arm64-apple-ios15.6' correctly extracted Swift's own real symbol graph")
    func realIOSDeviceTripleMapping() {
        #expect(XcodeBuildSettingsParser.targetTriple(architecture: "arm64", platformName: "iphoneos", deploymentTarget: "15.6") == "arm64-apple-ios15.6")
    }

    @Test("targetTriple: real confirmed macOS mapping ('macos', not 'macosx') -- matches a real captured ~/SQLumen compile line's own '-target arm64-apple-macos26.4'")
    func realMacOSTripleMapping() {
        #expect(XcodeBuildSettingsParser.targetTriple(architecture: "arm64", platformName: "macosx", deploymentTarget: "26.4") == "arm64-apple-macos26.4")
    }

    @Test("targetTriple: simulator platforms get an explicit '-simulator' suffix")
    func simulatorTripleMapping() {
        #expect(XcodeBuildSettingsParser.targetTriple(architecture: "arm64", platformName: "iphonesimulator", deploymentTarget: "17.0") == "arm64-apple-ios17.0-simulator")
    }

    @Test("targetTriple: an unrecognized platform returns nil rather than a fabricated triple")
    func unrecognizedPlatformReturnsNil() {
        #expect(XcodeBuildSettingsParser.targetTriple(architecture: "arm64", platformName: "somemadeupplatform", deploymentTarget: "1.0") == nil)
    }
}
