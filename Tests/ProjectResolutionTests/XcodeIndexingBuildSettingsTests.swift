import Foundation
import Testing
@testable import ProjectResolution

/// Real `-showdestinations` shape for a modern multiplatform SwiftUI scheme (issue #140,
/// `docs/task-multi-platform-target-support.md`): `IceCubesApp`'s own single `IceCubesApp` scheme
/// lists iOS Simulator, Mac Catalyst (no `"Simulator"` in its own platform string -- confirmed
/// never selected, matching issue #139's own finding), and visionOS Simulator as separate,
/// simultaneously-valid destinations. iOS Simulator is listed first.
private let realMultiPlatformShowDestinationsOutput = """
	Available destinations for the "IceCubesApp" scheme:
		{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
		{ platform:iOS Simulator, arch:arm64, id:8BC60344-4CDF-44A1-814D-68EFF6BED4A4, OS:26.4, name:iPhone 17 Pro }
		{ platform:macOS, variant:Mac Catalyst, arch:arm64, id:00006000-000000000000, name:My Mac }
		{ platform:visionOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-xrsimulator:placeholder, name:Any visionOS Simulator Device }
		{ platform:visionOS Simulator, arch:arm64, id:4B857BF6-8C99-4A4C-9C8E-9B1B9B1B9B1B, OS:2.4, name:Apple Vision Pro }
	"""

@Suite("resolveDeterministicSimulatorDestination (issue #140 -- preferredPlatform / --platform)")
struct ResolveDeterministicSimulatorDestinationTests {
    @Test("nil preferredPlatform (default) picks the first Simulator destination, unchanged from before --platform existed")
    func nilPreferredPlatformPicksFirstSimulatorDestination() throws {
        let runner = FakeProcessRunner()
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showdestinations", "-scheme", "IceCubesApp", "-project", "/IceCubesApp.xcodeproj"],
            result: ProcessResult(exitCode: 0, standardOutput: realMultiPlatformShowDestinationsOutput, standardError: "")
        )
        let destination = try resolveDeterministicSimulatorDestination(
            container: .xcodeproj(URL(fileURLWithPath: "/IceCubesApp.xcodeproj")), scheme: "IceCubesApp", processRunning: runner
        )
        #expect(destination == "generic/platform=iOS Simulator")
    }

    @Test("preferredPlatform \"visionOS\" reaches the real visionOS Simulator destination, listed after iOS -- the exact gap issue #140 was filed for")
    func preferredPlatformReachesVisionOS() throws {
        let runner = FakeProcessRunner()
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showdestinations", "-scheme", "IceCubesApp", "-project", "/IceCubesApp.xcodeproj"],
            result: ProcessResult(exitCode: 0, standardOutput: realMultiPlatformShowDestinationsOutput, standardError: "")
        )
        let destination = try resolveDeterministicSimulatorDestination(
            container: .xcodeproj(URL(fileURLWithPath: "/IceCubesApp.xcodeproj")), scheme: "IceCubesApp", processRunning: runner,
            preferredPlatform: "visionOS"
        )
        #expect(destination == "generic/platform=visionOS Simulator")
    }

    @Test("preferredPlatform matches case-insensitively")
    func preferredPlatformMatchesCaseInsensitively() throws {
        let runner = FakeProcessRunner()
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showdestinations", "-scheme", "IceCubesApp", "-project", "/IceCubesApp.xcodeproj"],
            result: ProcessResult(exitCode: 0, standardOutput: realMultiPlatformShowDestinationsOutput, standardError: "")
        )
        let destination = try resolveDeterministicSimulatorDestination(
            container: .xcodeproj(URL(fileURLWithPath: "/IceCubesApp.xcodeproj")), scheme: "IceCubesApp", processRunning: runner,
            preferredPlatform: "VISIONOS"
        )
        #expect(destination == "generic/platform=visionOS Simulator")
    }

    @Test("preferredPlatform \"macCatalyst\" throws -- Mac Catalyst's own real platform string never contains \"Simulator\", so it's never even a candidate, matching issue #139's own finding")
    func preferredPlatformMacCatalystThrows() throws {
        let runner = FakeProcessRunner()
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showdestinations", "-scheme", "IceCubesApp", "-project", "/IceCubesApp.xcodeproj"],
            result: ProcessResult(exitCode: 0, standardOutput: realMultiPlatformShowDestinationsOutput, standardError: "")
        )
        #expect(throws: DestinationResolutionError.requestedPlatformNotAvailable(
            requested: "macCatalyst", available: ["iOS Simulator", "iOS Simulator", "visionOS Simulator", "visionOS Simulator"]
        )) {
            try resolveDeterministicSimulatorDestination(
                container: .xcodeproj(URL(fileURLWithPath: "/IceCubesApp.xcodeproj")), scheme: "IceCubesApp", processRunning: runner,
                preferredPlatform: "macCatalyst"
            )
        }
    }

    @Test("preferredPlatform naming a genuinely unavailable platform throws with the real available list, never silently falling back to a different platform")
    func preferredPlatformUnavailableThrowsWithRealAvailableList() throws {
        let runner = FakeProcessRunner()
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showdestinations", "-scheme", "IceCubesApp", "-project", "/IceCubesApp.xcodeproj"],
            result: ProcessResult(exitCode: 0, standardOutput: realMultiPlatformShowDestinationsOutput, standardError: "")
        )
        #expect(throws: DestinationResolutionError.requestedPlatformNotAvailable(
            requested: "tvOS", available: ["iOS Simulator", "iOS Simulator", "visionOS Simulator", "visionOS Simulator"]
        )) {
            try resolveDeterministicSimulatorDestination(
                container: .xcodeproj(URL(fileURLWithPath: "/IceCubesApp.xcodeproj")), scheme: "IceCubesApp", processRunning: runner,
                preferredPlatform: "tvOS"
            )
        }
    }

    @Test("A scheme with only one real Simulator platform is unaffected by preferredPlatform matching it")
    func singlePlatformSchemeUnaffected() throws {
        let runner = FakeProcessRunner()
        let output = """
        	Available destinations for the "ls.net.ru" scheme:
        		{ platform:iOS Simulator, arch:arm64, id:8BC60344-4CDF-44A1-814D-68EFF6BED4A4, OS:26.4, name:iPhone 17 Pro }
        	"""
        runner.stub(
            executable: "xcodebuild",
            arguments: ["-showdestinations", "-scheme", "ls.net.ru", "-workspace", "/lsboutique.xcworkspace"],
            result: ProcessResult(exitCode: 0, standardOutput: output, standardError: "")
        )
        let destination = try resolveDeterministicSimulatorDestination(
            container: .xcworkspace(URL(fileURLWithPath: "/lsboutique.xcworkspace")), scheme: "ls.net.ru", processRunning: runner,
            preferredPlatform: "iOS"
        )
        #expect(destination == "generic/platform=iOS Simulator")
    }
}
