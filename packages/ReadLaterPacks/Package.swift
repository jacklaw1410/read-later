// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadLaterPacks",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReadLaterPacks", targets: ["ReadLaterPacks"])
    ],
    targets: [
        .target(
            name: "CGzip",
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "ReadLaterPacks",
            dependencies: ["CGzip"]
        ),
        .testTarget(name: "ReadLaterPacksTests", dependencies: ["ReadLaterPacks"])
    ]
)
