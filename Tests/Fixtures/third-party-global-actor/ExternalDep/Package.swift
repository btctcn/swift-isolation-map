// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExternalDep",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ThirdPartyActorKit", targets: ["ThirdPartyActorKit"])
    ],
    targets: [
        .target(name: "ThirdPartyActorKit")
    ]
)
