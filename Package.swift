// swift-tools-version: 6.0

import PackageDescription

var products: [Product] = [
  .library(name: "AppCore", targets: ["AppCore"]),
  .executable(name: "ccusage-gauge", targets: ["AppCLI"])
]

var targets: [Target] = [
  .systemLibrary(
    name: "CSQLite",
    providers: [
      .apt(["libsqlite3-dev"]),
      .brew(["sqlite3"])
    ]
  ),
  .target(
    name: "AppCore",
    dependencies: ["CSQLite"],
    resources: [.copy("Resources/Web")]
  ),
  .executableTarget(
    name: "AppCLI",
    dependencies: [
      "AppCore",
      .product(name: "ArgumentParser", package: "swift-argument-parser")
    ]
  ),
  .testTarget(
    name: "AppCoreTests",
    dependencies: ["AppCore"]
  ),
  .testTarget(
    name: "AppCLITests",
    dependencies: [
      "AppCLI",
      "AppCore",
      .product(name: "ArgumentParser", package: "swift-argument-parser")
    ]
  )
]

#if os(macOS)
products.append(.executable(name: "ccusage-gauge-menubar", targets: ["CCUsageGaugeMenuBar"]))
targets.append(
  .executableTarget(
    name: "CCUsageGaugeMenuBar",
    dependencies: ["AppCore"],
    linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement")]
  )
)
#endif

let package = Package(
  name: "ccusage-gauge",
  platforms: [
    .macOS(.v14)
  ],
  products: products,
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2")
  ],
  targets: targets,
  swiftLanguageModes: [.v6]
)
