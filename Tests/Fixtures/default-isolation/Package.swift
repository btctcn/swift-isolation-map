// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DefaultIsolationFixture",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DefaultIsolationApp", targets: ["DefaultIsolationApp"])
    ],
    targets: [
        .executableTarget(
            name: "DefaultIsolationApp",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ]
)
