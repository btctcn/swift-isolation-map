// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DemoFixture",
    products: [
        .executable(name: "DemoCLI", targets: ["DemoCLI"])
    ],
    targets: [
        .executableTarget(name: "DemoCLI")
    ]
)
