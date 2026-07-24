import Foundation
import Testing
@testable import ProjectResolution

/// XML fixtures below are hand-authored against Apple's documented, long-stable `.xcworkspacedata`/
/// `.xcscheme` schema (used verbatim across every Xcode version for well over a decade) -- not
/// extracted from a real Xcode-generated file, since this repository has no Xcode project of its
/// own to source one from. Documented limitation, not hidden: if Xcode's actual schema drifts in
/// some future version, these fixtures wouldn't catch it, unlike the golden-fixture SwiftPM test
/// in `SwiftPMSchemeResolverTests.swift`, which does run the real tool.
private let sampleScheme = """
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1500" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="ABCDEF1234567890"
               BuildableName="MyApp.app"
               BlueprintName="MyApp"
               ReferencedContainer="container:MyApp.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug">
      <Testables>
         <TestableReference skipped="NO">
            <BuildableReference
               BuildableIdentifier="primary"
               BlueprintIdentifier="1122334455667788"
               BuildableName="MyAppTests.xctest"
               BlueprintName="MyAppTests"
               ReferencedContainer="container:MyApp.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
</Scheme>
"""

private let sampleWorkspaceContents = """
<?xml version="1.0" encoding="UTF-8"?>
<Workspace version="1.0">
   <FileRef location="group:MyApp.xcodeproj"></FileRef>
</Workspace>
"""

@Test("A scheme's BuildAction entries become build targets, but TestAction entries are excluded")
func buildActionEntriesBecomeTargetsExcludingTestAction() throws {
    let fileSystem = FakeFileSystem()
    let projectURL = URL(fileURLWithPath: "/project/MyApp.xcodeproj")
    fileSystem.addFile(
        at: projectURL.appendingPathComponent("xcshareddata/xcschemes/MyApp.xcscheme"),
        contents: sampleScheme
    )

    let resolver = XcodeSchemeResolver(fileSystem: fileSystem)
    let scheme = try resolver.resolve(named: "MyApp", in: .xcodeproj(projectURL))

    #expect(scheme.buildTargets.map(\.targetName) == ["MyApp"])
    #expect(!scheme.buildTargets.map(\.targetName).contains("MyAppTests"))
}

@Test("Only shared schemes are discovered, from xcshareddata/xcschemes")
func onlySharedSchemesAreDiscovered() throws {
    let fileSystem = FakeFileSystem()
    let projectURL = URL(fileURLWithPath: "/project/MyApp.xcodeproj")
    fileSystem.addFile(
        at: projectURL.appendingPathComponent("xcshareddata/xcschemes/MyApp.xcscheme"),
        contents: sampleScheme
    )

    let resolver = XcodeSchemeResolver(fileSystem: fileSystem)
    let schemes = try resolver.discoverSchemes(in: .xcodeproj(projectURL))

    #expect(schemes.count == 1)
    let xcodeScheme = try #require(schemes.first as? XcodeScheme)
    #expect(xcodeScheme.isShared == true)
}

@Test("A workspace resolves nested .xcodeproj FileRefs and aggregates their shared schemes")
func workspaceAggregatesNestedProjectSchemes() throws {
    let fileSystem = FakeFileSystem()
    let workspaceURL = URL(fileURLWithPath: "/project/MyApp.xcworkspace")
    fileSystem.addFile(
        at: workspaceURL.appendingPathComponent("contents.xcworkspacedata"),
        contents: sampleWorkspaceContents
    )
    fileSystem.addFile(
        at: URL(fileURLWithPath: "/project/MyApp.xcodeproj/xcshareddata/xcschemes/MyApp.xcscheme"),
        contents: sampleScheme
    )

    let resolver = XcodeSchemeResolver(fileSystem: fileSystem)
    let schemes = try resolver.discoverSchemes(in: .xcworkspace(workspaceURL))

    #expect(schemes.map(\.name) == ["MyApp"])
}

@Test("Resolving an unknown scheme name throws noMatch listing what was actually found")
func unknownSchemeNameThrowsNoMatch() {
    let fileSystem = FakeFileSystem()
    let projectURL = URL(fileURLWithPath: "/project/MyApp.xcodeproj")
    fileSystem.addFile(
        at: projectURL.appendingPathComponent("xcshareddata/xcschemes/MyApp.xcscheme"),
        contents: sampleScheme
    )

    let resolver = XcodeSchemeResolver(fileSystem: fileSystem)
    #expect(throws: XcodeSchemeResolverError.noMatch(requested: "Nonexistent", available: ["MyApp"])) {
        try resolver.resolve(named: "Nonexistent", in: .xcodeproj(projectURL))
    }
}

@Test("A project with no shared schemes at all throws noSchemesFound rather than returning an empty, ambiguous success")
func noSharedSchemesThrows() {
    let fileSystem = FakeFileSystem()
    let projectURL = URL(fileURLWithPath: "/project/MyApp.xcodeproj")
    fileSystem.addDirectory(at: projectURL)

    let resolver = XcodeSchemeResolver(fileSystem: fileSystem)
    #expect(throws: XcodeSchemeResolverError.noSchemesFound) {
        try resolver.discoverSchemes(in: .xcodeproj(projectURL))
    }
}
