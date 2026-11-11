// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "blockplan",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../packages/ReadLaterCore")
    ],
    targets: [
        .executableTarget(
            name: "blockplan",
            dependencies: [
                .product(name: "ReadLaterCore", package: "ReadLaterCore")
            ]
        )
    ]
)
