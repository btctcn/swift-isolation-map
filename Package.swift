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
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
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
        .target(name: "ProjectResolution"),
        .target(name: "OutputFormat"),
        .testTarget(
            name: "IsolationCoreTests",
            dependencies: ["IsolationCore"]
        ),
        .testTarget(
            name: "ProjectResolutionTests",
            dependencies: ["ProjectResolution"]
        )
    ]
)
