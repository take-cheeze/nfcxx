// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "swiftfe",
  platforms: [.macOS(.v13)],
  dependencies: [
    .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "601.0.1")
  ],
  targets: [
    .executableTarget(
      name: "swiftfe",
      dependencies: [
        .product(name: "SwiftOperators", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
        .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
        .product(name: "SwiftSyntax", package: "swift-syntax"),
      ]
    )
  ]
)
