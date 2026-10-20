// swift-tools-version: 6.2

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
    // JPEG XL encoding for images kept in docs; Apple's frameworks decode it but cannot write it.
    // Pinned exactly: the package ships prebuilt libjxl binaries.
    .package(url: "https://github.com/awxkee/jxl-coder-swift", exact: "1.9.1"),
    // Renders docs and Markdown articles. Pinned exactly; math rendering (its LaTeX trait) is off.
    .package(url: "https://github.com/LiYanan2004/MarkdownView", exact: "3.0.0", traits: []),
  ],
  targets: [
    .target(
      name: "BentoUI",
      dependencies: [
        "BentoData", .product(name: "SQLiteData", package: "sqlite-data"),
        .product(name: "JxlCoder", package: "jxl-coder-swift"),
        .product(name: "MarkdownView", package: "MarkdownView"),
      ]
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
