// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReadLaterCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReadLaterCore", targets: ["ReadLaterCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0")
    ],
    targets: [
        .target(
            name: "ReadLaterCore",
            dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]
        ),
        .testTarget(name: "ReadLaterCoreTests", dependencies: ["ReadLaterCore"])
    ]
)
