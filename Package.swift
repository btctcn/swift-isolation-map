// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-isolation-map",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "swift-isolation-map", targets: ["swift-isolation-map"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2"),
        // Pinned by exact revision, not branch -- indexstore-db has no semver releases, only
        // per-Swift-version release/6.x branches that continue to receive patches. Re-verified
        // current (still release/6.3's and release/6.3.1's HEAD) before re-adding this for real;
        // see docs/priority-2-phase-0-spike.md for the full decision record and de-risking spike.
        .package(url: "https://github.com/swiftlang/indexstore-db.git", revision: "003ac41513ba291f10ff1a0147ae68588914668d")
    ],
    targets: [
        .executableTarget(
            name: "swift-isolation-map",
            dependencies: [
                "IsolationCore",
                "ProjectResolution",
                "OutputFormat",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        .target(name: "IsolationCore"),
        .target(
            name: "ProjectResolution",
            dependencies: ["IsolationCore", "SyntaxAnalysis"]
        ),
        .target(name: "OutputFormat"),
        .target(
            name: "SyntaxAnalysis",
            dependencies: [
                "IsolationCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax")
            ]
        ),
        .target(
            name: "IndexStoreIntegration",
            dependencies: [
                "IsolationCore",
                "ProjectResolution",
                .product(name: "IndexStoreDB", package: "indexstore-db")
            ]
        ),
        .testTarget(
            name: "IsolationCoreTests",
            dependencies: ["IsolationCore"]
        ),
        .testTarget(
            name: "ProjectResolutionTests",
            dependencies: ["ProjectResolution"]
        ),
        .testTarget(
            name: "SyntaxAnalysisTests",
            dependencies: ["SyntaxAnalysis", "IsolationCore"]
        ),
        .testTarget(
            name: "IndexStoreIntegrationTests",
            dependencies: ["IndexStoreIntegration"]
        )
    ]
)
