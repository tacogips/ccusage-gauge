// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ccusage-gauge",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AppCore", targets: ["AppCore"]),
    .executable(name: "ccusage-gauge", targets: ["AppCLI"])
  ],
  targets: [
    .target(name: "AppCore"),
    .executableTarget(
      name: "AppCLI",
      dependencies: ["AppCore"]
    ),
    .testTarget(
      name: "AppCoreTests",
      dependencies: ["AppCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
