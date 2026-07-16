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
    dependencies: ["AppCore"]
  ),
  .testTarget(
    name: "AppCoreTests",
    dependencies: ["AppCore"]
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
  targets: targets,
  swiftLanguageModes: [.v6]
)
