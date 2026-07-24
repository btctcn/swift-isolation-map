import Foundation
import Testing
@testable import ProjectResolution

private let sampleDescribeJSON = """
{
  "name": "Demo",
  "path": "/project",
  "products": [
    {
      "name": "DemoCLI",
      "targets": ["DemoCLI"],
      "type": { "executable": null }
    }
  ],
  "targets": [
    {
      "name": "DemoCLI",
      "path": "Sources/DemoCLI",
      "sources": ["main.swift"],
      "type": "executable",
      "c99name": "DemoCLI",
      "module_type": "SwiftTarget"
    },
    {
      "name": "DemoCore",
      "path": "Sources/DemoCore",
      "sources": ["Widget.swift", "Helper.swift"],
      "type": "library",
      "c99name": "DemoCore",
      "module_type": "SwiftTarget"
    }
  ],
  "tools_version": "6.0"
}
"""

private func makeResolver() -> (SwiftPMSchemeResolver, FakeProcessRunner) {
    let runner = FakeProcessRunner()
    runner.stub(
        executable: "swift",
        arguments: ["package", "describe", "--type", "json"],
        result: ProcessResult(exitCode: 0, standardOutput: sampleDescribeJSON, standardError: "")
    )
    return (SwiftPMSchemeResolver(processRunning: runner), runner)
}

@Test("Discovering schemes returns one per product, plus one per target not already covered by a product")
func discoverSchemesReturnsProductsAndUncoveredTargets() throws {
    let (resolver, _) = makeResolver()
    let schemes = try resolver.discoverSchemes(in: .swiftPackage(URL(fileURLWithPath: "/project/Package.swift")))
    let names = Set(schemes.map(\.name))
    #expect(names == ["DemoCLI", "DemoCore"])
}

@Test("A product's resolved scheme carries its target's real source file paths")
func productSchemeCarriesSourcePaths() throws {
    let (resolver, _) = makeResolver()
    let scheme = try resolver.resolve(named: "DemoCLI", in: .swiftPackage(URL(fileURLWithPath: "/project/Package.swift")))
    let spmScheme = try #require(scheme as? SPMResolvedScheme)
    #expect(spmScheme.sourcePaths == ["/project/Sources/DemoCLI/main.swift"])
}

@Test("A target-only scheme (no matching product) is still resolvable by name, with all its sources")
func targetOnlySchemeIsResolvable() throws {
    let (resolver, _) = makeResolver()
    let scheme = try resolver.resolve(named: "DemoCore", in: .swiftPackage(URL(fileURLWithPath: "/project/Package.swift")))
    let spmScheme = try #require(scheme as? SPMResolvedScheme)
    #expect(Set(spmScheme.sourcePaths) == ["/project/Sources/DemoCore/Widget.swift", "/project/Sources/DemoCore/Helper.swift"])
}

@Test("Resolving an unknown name throws noMatch listing every available product/target name")
func unknownNameThrowsNoMatch() {
    let (resolver, _) = makeResolver()
    #expect(throws: SwiftPMSchemeResolverError.noMatch(requested: "Nonexistent", available: ["DemoCLI", "DemoCore"])) {
        try resolver.resolve(named: "Nonexistent", in: .swiftPackage(URL(fileURLWithPath: "/project/Package.swift")))
    }
}

@Test("A non-zero describe exit code surfaces as describeFailed, not a silent empty result")
func nonZeroExitCodeSurfacesAsFailure() {
    let runner = FakeProcessRunner()
    runner.stub(
        executable: "swift",
        arguments: ["package", "describe", "--type", "json"],
        result: ProcessResult(exitCode: 1, standardOutput: "", standardError: "error: no Package.swift found")
    )
    let resolver = SwiftPMSchemeResolver(processRunning: runner)
    #expect(throws: SwiftPMSchemeResolverError.describeFailed(exitCode: 1, standardError: "error: no Package.swift found")) {
        try resolver.discoverSchemes(in: .swiftPackage(URL(fileURLWithPath: "/project/Package.swift")))
    }
}

@Test("The resolver invokes swift package describe in the package's own directory, not the current process directory")
func resolverInvokesDescribeInPackageDirectory() throws {
    let (resolver, runner) = makeResolver()
    _ = try resolver.discoverSchemes(in: .swiftPackage(URL(fileURLWithPath: "/project/Package.swift")))
    #expect(runner.invocations == [.init(executable: "swift", arguments: ["package", "describe", "--type", "json"])])
}

// MARK: - Golden-fixture test: real `swift package describe` against a dedicated checked-in fixture

/// Deliberately points at `Tests/Fixtures/simple-package/`, a separate, isolated SPM package with
/// its own `.build` -- not this project's own `Package.swift`. Running `swift package describe`
/// against the very package that's *currently* mid-`swift test` deadlocks: SwiftPM takes an
/// exclusive lock on `.build`/`workspace-state.json` for the outer `swift test` invocation, and a
/// nested `swift package describe` on that same package blocks waiting for the same lock,
/// forever. Found the hard way while writing this test -- a real golden-fixture package avoids it
/// entirely and is also what the architecture spec's testing strategy (section 4) calls for.
@Test("Real swift package describe, run against a dedicated fixture package, resolves the real executable product")
func realDescribeAgainstFixturePackageFindsExecutableProduct() throws {
    let resolver = SwiftPMSchemeResolver(processRunning: LiveProcessRunner())
    let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // SwiftPMSchemeResolverTests.swift -> ProjectResolutionTests
        .deletingLastPathComponent() // ProjectResolutionTests -> Tests
        .deletingLastPathComponent() // Tests -> project root
    let packageURL = projectRoot.appendingPathComponent("Tests/Fixtures/simple-package/Package.swift")
    let scheme = try resolver.resolve(named: "DemoCLI", in: .swiftPackage(packageURL))
    #expect(scheme.name == "DemoCLI")
    #expect(!scheme.buildTargets.isEmpty)
}
