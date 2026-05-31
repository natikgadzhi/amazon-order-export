// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "TelemetryScrub",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "TelemetryScrub", targets: ["TelemetryScrub"])
  ],
  targets: [
    .target(name: "TelemetryScrub"),
    .testTarget(name: "TelemetryScrubTests", dependencies: ["TelemetryScrub"]),
  ],
  swiftLanguageModes: [.v6]
)
