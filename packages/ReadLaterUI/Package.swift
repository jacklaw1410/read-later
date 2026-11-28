// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadLaterUI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReadLaterUI", targets: ["ReadLaterUI"])
    ],
    dependencies: [
        .package(path: "../ReadLaterCore"),
        .package(path: "../ReadLaterStore"),
    ],
    targets: [
        .target(
            name: "ReadLaterUI",
            dependencies: ["ReadLaterCore"]
        ),
        .testTarget(
            name: "ReadLaterUITests",
            dependencies: ["ReadLaterUI", "ReadLaterCore", "ReadLaterStore"]
        )
    ]
)
