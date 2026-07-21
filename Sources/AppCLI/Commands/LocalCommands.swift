import AppCore
import ArgumentParser
import Foundation

/// `ccusage-gauge config-check`
struct ConfigCheckCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config-check",
    abstract: "Validate the configuration and resolved ccusage executable."
  )

  func run() async throws {
    try await CommandRuntime.configCheck()
  }
}

/// `ccusage-gauge usage-snapshot [--json]`
struct UsageSnapshotCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "usage-snapshot",
    abstract: "Compute a local usage snapshot without contacting the dashboard server."
  )

  @Flag(name: .long, help: "Emit the snapshot as JSON.")
  var json = false

  func run() async throws {
    try await CommandRuntime.usageSnapshot(json: json)
  }
}

/// `ccusage-gauge serve [--port <port>] [--assets <directory>]`
struct ServeCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "serve",
    abstract: "Run the loopback dashboard server on 127.0.0.1."
  )

  @Option(name: .long, help: "Loopback port to bind. Defaults to the configured dashboardPort.")
  var port: Int?

  @Option(name: .long, help: "Serve dashboard assets from this directory instead of the bundled build.")
  var assets: String?

  func validate() throws {
    if let port, !(1...65_535).contains(port) {
      throw ValidationError("Invalid port: \(port)")
    }
  }

  func run() async throws {
    try await CommandRuntime.serve(port: port, assets: assets)
  }
}
