// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimpleActorFixture",
    products: [
        .executable(name: "SimpleActorApp", targets: ["SimpleActorApp"])
    ],
    targets: [
        .executableTarget(name: "SimpleActorApp")
    ]
)
