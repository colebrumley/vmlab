// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "vmlab",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "vmlab", targets: ["vmlab"]),
    .executable(name: "vmlab-vz", targets: ["vmlab-vz"]),
    .executable(name: "vmlab-switch", targets: ["vmlab-switch"]),
    .library(name: "VMLabCore", targets: ["VMLabCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.0"),
  ],
  targets: [
    .target(
      name: "VMLabCore",
      dependencies: [.product(name: "Logging", package: "swift-log")]
    ),
    .target(name: "VMLabQEMU", dependencies: ["VMLabCore"]),
    .target(name: "VMLabVZ", dependencies: ["VMLabCore"]),
    .target(name: "VMLabRFB", dependencies: ["VMLabCore"]),
    .target(name: "VMLabGDB", dependencies: ["VMLabCore"]),
    .target(
      name: "VMLabMCP",
      dependencies: ["VMLabCore", .product(name: "MCP", package: "swift-sdk")]
    ),
    .executableTarget(
      name: "vmlab",
      dependencies: [
        "VMLabCore", "VMLabMCP",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "vmlab-vz",
      dependencies: [
        "VMLabCore", "VMLabVZ",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      exclude: ["vmlab-vz.entitlements"]
    ),
    .executableTarget(
      name: "vmlab-switch",
      dependencies: [
        "VMLabCore",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "UnitTests",
      dependencies: ["VMLabCore", "VMLabQEMU", "VMLabVZ", "VMLabRFB", "VMLabGDB", "VMLabMCP"]
    ),
    .testTarget(
      name: "IntegrationTests",
      dependencies: ["VMLabCore", "VMLabQEMU", "VMLabVZ", "VMLabRFB", "VMLabGDB", "VMLabMCP"]
    ),
  ]
)
