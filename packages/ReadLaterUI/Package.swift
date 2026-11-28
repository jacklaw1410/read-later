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
        // The stage probe times a stored document, so the test target needs
        // the store. The UI target itself does not depend on it.
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
