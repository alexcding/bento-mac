// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "BentoUI",
  platforms: [.macOS(.v15), .iOS(.v18)],
  products: [
    .library(name: "BentoUI", targets: ["BentoUI"])
  ],
  dependencies: [
    .package(path: "../BentoData"),
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.12.1"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.0"),
  ],
  targets: [
    .target(
      name: "BentoUI",
      dependencies: ["BentoData", .product(name: "SQLiteData", package: "sqlite-data")]
    ),
    .testTarget(
      name: "BentoUITests",
      dependencies: [
        "BentoUI",
        .product(name: "DependenciesTestSupport", package: "swift-dependencies"),
      ]
    ),
  ]
)
