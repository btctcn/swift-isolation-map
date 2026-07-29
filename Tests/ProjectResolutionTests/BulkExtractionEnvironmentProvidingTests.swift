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
        // Only one xcodebuild invocation -- never a -verbose build call, confirming the whole
        // point of this seam (bulk phase never triggers the slow/clean-build-capable path).
        #expect(runner.invocations.count == 1)
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
        #expect(runner.invocations.count == 1)
    }

    @Test("SwiftPMBulkExtractionEnvironmentProvider: resolves sdk/target/discovered modules from --show-bin-path + --show-sdk-path, no build triggered")
    func swiftPMProviderResolvesFromShowBinPath() throws {
        let runner = FakeProcessRunner()
        let packageDirectory = URL(fileURLWithPath: "/pkg")
        runner.stub(
            executable: "swift", arguments: ["build", "--show-bin-path"],
            result: ProcessResult(exitCode: 0, standardOutput: "/pkg/.build/arm64-apple-macosx/debug\n", standardError: "")
        )
        runner.stub(
            executable: "xcrun", arguments: ["--show-sdk-path"],
            result: ProcessResult(exitCode: 0, standardOutput: "/Applications/Xcode.app/.../MacOSX.sdk\n", standardError: "")
        )
        let fileSystem = FakeFileSystem()
        fileSystem.addFile(at: URL(fileURLWithPath: "/pkg/.build/arm64-apple-macosx/debug/Modules/SomeDependency.swiftmodule"), contents: Data())

        let provider = SwiftPMBulkExtractionEnvironmentProvider(packageDirectory: packageDirectory, processRunning: runner, fileSystem: fileSystem)
        let environment = try provider.environment()
        #expect(environment.target == "arm64-apple-macosx")
        #expect(environment.sdkPath == "/Applications/Xcode.app/.../MacOSX.sdk")
        #expect(environment.discoveredModules.contains(
            DiscoveredModule(name: "SomeDependency", extractionFlags: ["-I", "/pkg/.build/arm64-apple-macosx/debug/Modules"])
        ))
    }
}
