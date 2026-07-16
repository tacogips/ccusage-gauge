// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ccusage-gauge",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AppCore", targets: ["AppCore"]),
    .executable(name: "ccusage-gauge", targets: ["AppCLI"]),
    .executable(name: "ccusage-gauge-menubar", targets: ["CCUsageGaugeMenuBar"])
  ],
  targets: [
    .target(
      name: "AppCore",
      resources: [.copy("Resources/Web")],
      linkerSettings: [.linkedFramework("Network"), .linkedLibrary("sqlite3")]
    ),
    .executableTarget(
      name: "AppCLI",
      dependencies: ["AppCore"]
    ),
    .executableTarget(
      name: "CCUsageGaugeMenuBar",
      dependencies: ["AppCore"],
      linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]
    ),
    .testTarget(
      name: "AppCoreTests",
      dependencies: ["AppCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
