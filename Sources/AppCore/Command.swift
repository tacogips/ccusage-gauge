import Foundation

public struct AppCommand: Sendable {
  public enum Error: Swift.Error, Equatable, Sendable {
    case unknownArgument(String)
    case invalidValue(String)
  }

  public enum Invocation: Equatable, Sendable {
    case help
    case version
    case configCheck
    case usageSnapshot(json: Bool)
    case serve(port: Int?, assets: String?)
  }

  public let arguments: [String]

  public init(arguments: [String]) {
    self.arguments = arguments
  }

  public func run() throws -> String {
    switch try parse() {
    case .version: return Version.current
    case .help: return usage
    default: return ""
    }
  }

  public func parse() throws -> Invocation {
    guard let command = arguments.first else { return .help }
    switch command {
    case "--help", "-h", "help": return .help
    case "--version": return .version
    case "config-check":
      guard arguments.count == 1 else { throw Error.unknownArgument(arguments[1]) }
      return .configCheck
    case "usage-snapshot":
      let options = Array(arguments.dropFirst())
      guard options.allSatisfy({ $0 == "--json" }) else { throw Error.unknownArgument(options.first { $0 != "--json" }!) }
      return .usageSnapshot(json: options.contains("--json"))
    case "serve": return try parseServe(Array(arguments.dropFirst()))
    default: throw Error.unknownArgument(command)
    }
  }

  private func parseServe(_ options: [String]) throws -> Invocation {
    var port: Int?
    var assets: String?
    var index = 0
    while index < options.count {
      let option = options[index]
      guard index + 1 < options.count else { throw Error.invalidValue("Missing value for \(option)") }
      let value = options[index + 1]
      switch option {
      case "--port":
        guard let parsed = Int(value), (1...65_535).contains(parsed) else { throw Error.invalidValue("Invalid port: \(value)") }
        port = parsed
      case "--assets": assets = value
      default: throw Error.unknownArgument(option)
      }
      index += 2
    }
    return .serve(port: port, assets: assets)
  }

  public var usage: String {
    """
    Usage: ccusage-gauge <command> [options]

      ccusage-gauge --help
      ccusage-gauge --version
      ccusage-gauge config-check
      ccusage-gauge usage-snapshot [--json]
      ccusage-gauge serve [--port <port>] [--assets <directory>]
    """
  }
}
