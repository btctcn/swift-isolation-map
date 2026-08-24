// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Consumer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../ExternalDep")
    ],
    targets: [
        .target(name: "Consumer", dependencies: [.product(name: "ThirdPartyActorKit", package: "ExternalDep")])
    ]
)
