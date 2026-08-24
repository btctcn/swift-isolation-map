// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-isolation-map",
    platforms: [
        // Bumped from .v13 for `swift-build`'s own minimum (docs/task-swift-build-prepare-for-
        // indexing-spike.md) -- required by `SwiftBuildCompilerArgumentsProvider`, the main
        // Xcode-project `CompilerArgumentsProviding` conformer.
        .macOS(.v15)
    ],
    products: [
        .executable(name: "swift-isolation-map", targets: ["swift-isolation-map"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2"),
        // Apple's 2024 open-sourcing of `SWBBuildService` (the engine `xcodebuild` itself talks to
        // -- confirmed via real build logs, `xcodebuild -> SWBBuildService -> clang`). No semver
        // tags exist upstream (only `swift-DEVELOPMENT-SNAPSHOT-*` toolchain-release tags, which
        // aren't valid SPM versions) -- pinned to the exact commit this whole feature was
        // researched, spiked, and validated against end-to-end on a real ~2200-file corpus
        // (docs/task-swift-build-prepare-for-indexing-spike.md Steps 1-10c), not floated on a
        // branch. Bump deliberately, not silently: re-validate against the real corpus (that doc's
        // own Step 10 comparison) before moving this pin forward.
        .package(url: "https://github.com/swiftlang/swift-build.git", revision: "2e916b2d01fcacc825c50e28b15b7b2483860caf")
    ],
    targets: [
        .executableTarget(
            name: "swift-isolation-map",
            dependencies: [
                "IsolationCore",
                "ProjectResolution",
                "OutputFormat",
                "SyntaxAnalysis",
                "IndexStoreIntegration",
                "SourceKitDIntegration",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .target(name: "IsolationCore"),
        .target(
            name: "ProjectResolution",
            dependencies: [
                "IsolationCore", "SyntaxAnalysis",
                .product(name: "SwiftBuild", package: "swift-build")
            ]
        ),
        .target(name: "OutputFormat"),
        .target(
            name: "SyntaxAnalysis",
            dependencies: [
                "IsolationCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftIfConfig", package: "swift-syntax")
            ]
        ),
        .target(
            name: "IndexStoreIntegration",
            dependencies: [
                "IsolationCore",
                "ProjectResolution",
                "CIndexStoreRaw"
            ]
        ),
        // `libIndexStore`'s own raw C API, `dlopen`'d at runtime like `CSourceKitD` -- not for the
        // same ABI reason (this API's own signatures are already fully `@convention(c)`-
        // representable in Swift; see the header's own doc comment), but for the same "never
        // hard-link one specific toolchain's dylib" reason. Backs `RawIndexStoreClient`, the sole
        // `IndexStoreQuerying` conformer today -- originally built (issue #51,
        // docs/task-raw-indexstore-spike.md) as a second implementation to test whether a real
        // `IndexStoreDB` declaration-loss bug was rooted in its async/persistent layer, confirmed
        // real and more correct there, and has since fully replaced `IndexStoreDB`/`IndexStoreClient`
        // as the project's only index reader -- the `indexstore-db` package dependency itself was
        // removed once nothing else depended on it.
        .target(name: "CIndexStoreRaw"),
        // A plain C target, not a systemLibrary -- `sourcekitd_variant_t` (24 bytes, passed/
        // returned by value) is passed indirectly per the platform ABI once it exceeds 16 bytes,
        // which a hand-declared Swift `@convention(c)` closure type cannot express ("not
        // representable in Objective-C", hit empirically before this target existed). Real C code
        // has no such restriction, and Swift's ClangImporter already knows how to bridge genuine C
        // structs correctly (the same mechanism `CGPoint`/`CGRect` rely on) -- so the hard ABI part
        // lives here, in C, dlopen'd at runtime (never linked at build time), and
        // SourceKitDIntegration imports this target as an ordinary C module.
        .target(name: "CSourceKitD"),
        // No external package dependency, unlike IndexStoreIntegration -- `sourcekitdInProc` has
        // no Swift-wrapper package equivalent to `indexstore-db`. dlopen'd directly at runtime
        // (see ToolchainLocating.swift/SourceKitDClient.swift), same pattern IndexStoreIntegration
        // uses for `libIndexStore.dylib`, just without a package doing the dlopen for us. See
        // docs/priority-3-phase-b-sourcekitd-client.md for the full decision record.
        .target(
            name: "SourceKitDIntegration",
            dependencies: [
                "IsolationCore",
                "ProjectResolution",
                "CSourceKitD"
            ]
        ),
        .testTarget(
            name: "IsolationCoreTests",
            dependencies: ["IsolationCore"]
        ),
        .testTarget(
            name: "ProjectResolutionTests",
            dependencies: [
                "ProjectResolution",
                .product(name: "SwiftBuild", package: "swift-build")
            ]
        ),
        .testTarget(
            name: "SyntaxAnalysisTests",
            dependencies: ["SyntaxAnalysis", "IsolationCore"]
        ),
        .testTarget(
            name: "IndexStoreIntegrationTests",
            dependencies: ["IndexStoreIntegration"]
        ),
        .testTarget(
            name: "SourceKitDIntegrationTests",
            dependencies: ["SourceKitDIntegration"]
        ),
        .testTarget(
            name: "swift-isolation-mapTests",
            dependencies: ["swift-isolation-map"]
        )
    ]
)
