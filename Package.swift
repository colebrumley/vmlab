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
    .target(name: "VMLabSwitch"),
    // Names the engines so `vmlab` can register them without importing a backend module (C3).
    .target(name: "VMLabEngines", dependencies: ["VMLabCore", "VMLabQEMU", "VMLabVZ", "VMLabGDB"]),
    .target(
      name: "VMLabMCP",
      dependencies: [
        "VMLabCore", .product(name: "MCP", package: "swift-sdk"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    .executableTarget(
      name: "vmlab",
      dependencies: [
        "VMLabCore", "VMLabMCP", "VMLabEngines",
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
        "VMLabCore", "VMLabSwitch",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Logging", package: "swift-log"),
      ]
    ),
    // Spawned by StoreTests to write one VM record from a second process; not a product.
    .executableTarget(
      name: "vmlab-store-helper", dependencies: ["VMLabCore"], path: "Tests/StoreHelper"
    ),
    .testTarget(
      name: "UnitTests",
      dependencies: [
        "VMLabCore", "VMLabQEMU", "VMLabVZ", "VMLabRFB", "VMLabGDB", "VMLabMCP", "VMLabSwitch",
        "VMLabEngines", "vmlab-store-helper", "vmlab",
      ]
    ),
    .testTarget(
      name: "IntegrationTests",
      dependencies: [
        "VMLabCore", "VMLabQEMU", "VMLabVZ", "VMLabRFB", "VMLabGDB", "VMLabMCP", "VMLabEngines",
      ]
    ),
  ]
)
