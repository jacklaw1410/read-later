// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadLaterStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReadLaterStore", targets: ["ReadLaterStore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(path: "../ReadLaterCore"),
    ],
    targets: [
        .target(
            name: "ReadLaterStore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "ReadLaterCore",
            ]
        ),
        .testTarget(
            name: "ReadLaterStoreTests",
            dependencies: [
                "ReadLaterStore", "ReadLaterCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
