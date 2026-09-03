import Testing
@testable import swift_isolation_map
import SyntaxAnalysis

@Suite("SwiftIsolationMap.platform(fromTargetTriple:)")
struct TargetPlatformDetectionTests {
    @Test("Reads every real, confirmed OS component, including visionOS's own \"xros\" (issue #140)")
    func readsRealOSComponents() {
        #expect(SwiftIsolationMap.platform(fromTargetTriple: "arm64-apple-ios15.6-simulator") == .iOS)
        #expect(SwiftIsolationMap.platform(fromTargetTriple: "arm64-apple-macosx13.0") == .macOS)
        #expect(SwiftIsolationMap.platform(fromTargetTriple: "arm64-apple-tvos17.0-simulator") == .tvOS)
        #expect(SwiftIsolationMap.platform(fromTargetTriple: "arm64-apple-watchos10.0-simulator") == .watchOS)
        #expect(SwiftIsolationMap.platform(fromTargetTriple: "arm64-apple-xros1.0-simulator") == .visionOS)
    }

    @Test("Returns .unknown for a triple with no recognized OS component, or no -apple- marker at all")
    func returnsUnknownForUnrecognizedTriples() {
        #expect(SwiftIsolationMap.platform(fromTargetTriple: "x86_64-unknown-linux-gnu") == .unknown)
        #expect(SwiftIsolationMap.platform(fromTargetTriple: "arm64-apple-nonexistentos1.0") == .unknown)
        #expect(SwiftIsolationMap.platform(fromTargetTriple: "") == .unknown)
    }
}
