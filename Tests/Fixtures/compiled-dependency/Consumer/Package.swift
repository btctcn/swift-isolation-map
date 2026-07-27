// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Points at ExternalDep's build output directories, built fresh by the test itself
// (`CompiledDependencyCLITests.swift`) before this package is ever built -- never committed,
// never pre-built. Absolute paths computed from this manifest's own location (`#filePath`) rather
// than a relative path passed to swiftc, which would be resolved relative to whatever working
// directory happens to invoke the build, not reliably this file's own location.
let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let externalDepCoreBuild = fixtureRoot.appendingPathComponent("ExternalDep/build/Core").path
let externalDepDefaultBuild = fixtureRoot.appendingPathComponent("ExternalDep/build/Default").path

let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "Consumer",
            swiftSettings: [
                .unsafeFlags(["-I", externalDepCoreBuild, "-I", externalDepDefaultBuild])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", externalDepCoreBuild, "-lExternalDepCore",
                    "-Xlinker", "-rpath", "-Xlinker", externalDepCoreBuild,
                    "-L", externalDepDefaultBuild, "-lExternalDepDefault",
                    "-Xlinker", "-rpath", "-Xlinker", externalDepDefaultBuild
                ])
            ]
        )
    ]
)
