import Foundation
import Testing
@testable import ProjectResolution

private let realProjectIrisBuildSettingsForEnvironment = """
Build settings for action build and target SomeScheme:
    ARCHS = arm64
    DEPLOYMENT_TARGET_SETTING_NAME = IPHONEOS_DEPLOYMENT_TARGET
    FRAMEWORK_SEARCH_PATHS = "/DerivedData/Debug-iphoneos"
    IPHONEOS_DEPLOYMENT_TARGET = 15.6
    PLATFORM_NAME = iphoneos
    SDKROOT = /Applications/Xcode-26.4.0.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.4.sdk
"""

/// Real `-showdestinations` output shape (docs/task-bulk-extraction-wrong-platform.md §2): a
/// physical device paired to the host in the past but not currently connected sorts *ahead of*
/// every Simulator destination. Confirmed directly against a real corpus this session: with no
/// `-destination` passed, this provider's own `-showBuildSettings` call resolved
/// `PLATFORM_NAME=iphoneos` even though the real build on that machine only ever produces
/// `Debug-iphonesimulator` -- every `FRAMEWORK_SEARCH_PATHS` entry then pointed at a directory that
/// was never built, silently disabling bulk pre-resolution for every discovered third-party module.
private let realLsboutiqueShowDestinationsOutput = """
	Available destinations for the "ls.net.ru" scheme:
		{ platform:iOS, id:6268785b905ba913ec773f578958320875aad293, name:ab iphone x, error:ab iphone x is not connected Xcode will continue when ab iphone x is connected and unlocked. }
		{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device }
		{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
		{ platform:iOS Simulator, arch:arm64, id:8BC60344-4CDF-44A1-814D-68EFF6BED4A4, OS:26.4, name:iPhone 17 Pro }
	"""

@Suite("BulkExtractionEnvironmentProviding")
struct BulkExtractionEnvironmentProvidingTests {
    @Test("LiveXcodeBulkExtractionEnvironmentProvider: a single real, fast, read-only -showBuildSettings call yields sdk/target/discovered modules, never touching -verbose build")
    func xcodeProviderResolvesFromShowBuildSettingsOnly() throws {
        let runner = FakeProcessRunner()
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showBuildSettings", "-scheme", "SomeScheme", "-workspace", "/ProjectIris.xcworkspace"],
            result: ProcessResult(exitCode: 0, standardOutput: realProjectIrisBuildSettingsForEnvironment, standardError: "")
        )
        let fileSystem = FakeFileSystem()
        fileSystem.addDirectory(at: URL(fileURLWithPath: "/DerivedData/Debug-iphoneos/Kingfisher.framework/Modules/Kingfisher.swiftmodule"))

        let provider = LiveXcodeBulkExtractionEnvironmentProvider(
            container: .xcworkspace(URL(fileURLWithPath: "/ProjectIris.xcworkspace")),
            scheme: "SomeScheme", processRunning: runner, fileSystem: fileSystem
        )

        let environment = try provider.environment()
        #expect(environment.sdkPath.hasSuffix("iPhoneOS26.4.sdk"))
        #expect(environment.target == "arm64-apple-ios15.6")
        #expect(environment.discoveredModules.contains(DiscoveredModule(name: "Kingfisher", extractionFlags: ["-F", "/DerivedData/Debug-iphoneos"])))
        // 1 `-showdestinations` probe (unstubbed here, so it fails and is swallowed -- no
        // destination override applies, matching `LiveXcodeCompilerArgumentsProvider`'s own tests'
        // established shape for the exact same fail-soft probe) + 1 `-showBuildSettings` call.
        #expect(runner.invocations.count == 2)
    }

    @Test("LiveXcodeBulkExtractionEnvironmentProvider: caches after the first call, never re-invoking xcodebuild")
    func xcodeProviderCachesAfterFirstCall() throws {
        let runner = FakeProcessRunner()
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showBuildSettings", "-scheme", "SomeScheme", "-workspace", "/ProjectIris.xcworkspace"],
            result: ProcessResult(exitCode: 0, standardOutput: realProjectIrisBuildSettingsForEnvironment, standardError: "")
        )
        let provider = LiveXcodeBulkExtractionEnvironmentProvider(
            container: .xcworkspace(URL(fileURLWithPath: "/ProjectIris.xcworkspace")),
            scheme: "SomeScheme", processRunning: runner, fileSystem: FakeFileSystem()
        )
        _ = try provider.environment()
        _ = try provider.environment()
        // 1 `-showdestinations` probe (unstubbed, swallowed) + 1 `-showBuildSettings` call, the
        // second `environment()` call served entirely from the cache.
        #expect(runner.invocations.count == 2)
    }

    @Test("LiveXcodeBulkExtractionEnvironmentProvider: a real -destination override reaches -showBuildSettings, fixing the real regression this session found (docs/task-bulk-extraction-wrong-platform.md §2) -- an unconnected paired device no longer wins over the Simulator")
    func xcodeProviderPassesResolvedDestinationToShowBuildSettings() throws {
        let runner = FakeProcessRunner()
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showdestinations", "-scheme", "ls.net.ru", "-workspace", "/lsboutique.xcworkspace"],
            result: ProcessResult(exitCode: 0, standardOutput: realLsboutiqueShowDestinationsOutput, standardError: "")
        )
        runner.stub(
            executable: "xcodebuild",
            arguments: [
                "-showBuildSettings", "-scheme", "ls.net.ru", "-workspace", "/lsboutique.xcworkspace",
                "-destination", "generic/platform=iOS Simulator"
            ],
            result: ProcessResult(exitCode: 0, standardOutput: realProjectIrisBuildSettingsForEnvironment, standardError: "")
        )
        let provider = LiveXcodeBulkExtractionEnvironmentProvider(
            container: .xcworkspace(URL(fileURLWithPath: "/lsboutique.xcworkspace")),
            scheme: "ls.net.ru", processRunning: runner, fileSystem: FakeFileSystem()
        )
        _ = try provider.environment()
        #expect(runner.invocations.count == 2)
    }

    @Test("SwiftPMBulkExtractionEnvironmentProvider: resolves sdk/target/discovered modules from --show-bin-path + --show-sdk-path, no build triggered")
    func swiftPMProviderResolvesFromShowBinPath() throws {
        let runner = FakeProcessRunner()
        let packageDirectory = URL(fileURLWithPath: "/pkg")
        runner.stub(
            executable: "swift", arguments: ["build", "--show-bin-path"],
            result: ProcessResult(exitCode: 0, standardOutput: "/pkg/.build/arm64-apple-macosx/debug\n", standardError: "")
        )
        // Issue #40's own real-corpus verification: the bin-path triple folder name alone
        // (`arm64-apple-macosx`) omits the OS version SwiftPM deliberately leaves out of that
        // directory name -- passing it bare as `-target` left the *compiler's* own ancient default
        // apply instead of this machine's real SDK version, which `swift symbolgraph-extract`
        // rejects outright for any dependency declaring a realistic platform minimum (confirmed
        // directly: "compiling for macOS 10.4, but module 'X' has a minimum deployment target of
        // macOS 13.0"). The real fix queries the SDK's own version and appends it.
        runner.stub(
            executable: "xcrun", arguments: ["--sdk", "macosx", "--show-sdk-version"],
            result: ProcessResult(exitCode: 0, standardOutput: "15.0\n", standardError: "")
        )
        runner.stub(
            executable: "xcrun", arguments: ["--show-sdk-path"],
            result: ProcessResult(exitCode: 0, standardOutput: "/Applications/Xcode.app/.../MacOSX.sdk\n", standardError: "")
        )
        let fileSystem = FakeFileSystem()
        fileSystem.addFile(at: URL(fileURLWithPath: "/pkg/.build/arm64-apple-macosx/debug/Modules/SomeDependency.swiftmodule"), contents: Data())

        let provider = SwiftPMBulkExtractionEnvironmentProvider(packageDirectory: packageDirectory, processRunning: runner, fileSystem: fileSystem)
        let environment = try provider.environment()
        #expect(environment.target == "arm64-apple-macosx15.0")
        #expect(environment.sdkPath == "/Applications/Xcode.app/.../MacOSX.sdk")
        #expect(environment.discoveredModules.contains(
            DiscoveredModule(name: "SomeDependency", extractionFlags: ["-I", "/pkg/.build/arm64-apple-macosx/debug/Modules"])
        ))
    }
}
