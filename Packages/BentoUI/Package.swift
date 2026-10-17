// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BentoUI",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "BentoUI", targets: ["BentoUI"])
  ],
  dependencies: [
    .package(path: "../BentoData")
  ],
  targets: [
    .target(name: "BentoUI", dependencies: ["BentoData"])
  ]
)
