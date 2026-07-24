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
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2")
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
        )
    ]
)
