// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AmazonOrders",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AmazonOrders", targets: ["AmazonOrders"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.11.2")
    ],
    targets: [
        .target(name: "AmazonOrders", dependencies: ["SwiftSoup"]),
        .testTarget(
            name: "AmazonOrdersTests",
            dependencies: ["AmazonOrders"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
