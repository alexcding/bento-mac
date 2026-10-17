// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BentoData",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "BentoData", targets: ["BentoData"])
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.12.1"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.0"),
  ],
  targets: [
    .target(
      name: "BentoData",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "SQLiteData", package: "sqlite-data"),
      ]
    ),
    .testTarget(
      name: "BentoDataTests",
      dependencies: ["BentoData"]
    ),
  ]
)
