// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AmazonAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AmazonAuth", targets: ["AmazonAuth"]),
    ],
    targets: [
        .target(name: "AmazonAuth"),
        .testTarget(name: "AmazonAuthTests", dependencies: ["AmazonAuth"]),
    ],
    swiftLanguageModes: [.v6]
)
