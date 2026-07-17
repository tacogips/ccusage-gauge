import Foundation

public enum ResetCycle: Codable, Equatable, Sendable {
  case hourly
  case daily
  case weekly
  case monthly
  case customHours(Int)

  private enum CodingKeys: String, CodingKey { case type, hours }
  private enum Kind: String, Codable { case hourly, daily, weekly, monthly, customHours }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .type) {
    case .hourly: self = .hourly
    case .daily: self = .daily
    case .weekly: self = .weekly
    case .monthly: self = .monthly
    case .customHours:
      let hours = try container.decode(Int.self, forKey: .hours)
      guard hours > 0 else {
        throw DecodingError.dataCorruptedError(forKey: .hours, in: container, debugDescription: "hours must be positive")
      }
      self = .customHours(hours)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .hourly: try container.encode(Kind.hourly, forKey: .type)
    case .daily: try container.encode(Kind.daily, forKey: .type)
    case .weekly: try container.encode(Kind.weekly, forKey: .type)
    case .monthly: try container.encode(Kind.monthly, forKey: .type)
    case .customHours(let hours):
      try container.encode(Kind.customHours, forKey: .type)
      try container.encode(hours, forKey: .hours)
    }
  }

  public init(term: String) throws {
    switch term {
    case "hourly": self = .hourly
    case "daily": self = .daily
    case "weekly": self = .weekly
    case "monthly": self = .monthly
    default: throw ConfigurationError.invalidResetTerm(term)
    }
  }

  public var label: String {
    switch self {
    case .hourly: "hourly"
    case .daily: "daily"
    case .weekly: "weekly"
    case .monthly: "monthly"
    case .customHours(let hours): "customHours(\(hours))"
    }
  }
}

public struct AppConfiguration: Codable, Equatable, Sendable {
  public static let defaultPollIntervalSeconds = 20
  public static let defaultCacheRetentionDays = 365

  public var ccusagePath: String?
  public var defaultResetTerm: String
  public var dashboardPort: Int
  public var dashboardAutostart: Bool
  public var pollIntervalSeconds: Int
  public var cacheRetentionDays: Int

  public init(
    ccusagePath: String? = nil,
    defaultResetTerm: String = "daily",
    dashboardPort: Int = 18_081,
    dashboardAutostart: Bool = true,
    pollIntervalSeconds: Int = AppConfiguration.defaultPollIntervalSeconds,
    cacheRetentionDays: Int = AppConfiguration.defaultCacheRetentionDays
  ) {
    self.ccusagePath = ccusagePath
    self.defaultResetTerm = defaultResetTerm
    self.dashboardPort = dashboardPort
    self.dashboardAutostart = dashboardAutostart
    self.pollIntervalSeconds = pollIntervalSeconds
    self.cacheRetentionDays = cacheRetentionDays
  }

  private enum CodingKeys: String, CodingKey {
    case ccusagePath, defaultResetTerm, dashboardPort, dashboardAutostart
    case pollIntervalSeconds, cacheRetentionDays
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ccusagePath = try container.decodeIfPresent(String.self, forKey: .ccusagePath)
    defaultResetTerm = try container.decode(String.self, forKey: .defaultResetTerm)
    dashboardPort = try container.decode(Int.self, forKey: .dashboardPort)
    dashboardAutostart = try container.decode(Bool.self, forKey: .dashboardAutostart)
    pollIntervalSeconds = try container.decode(Int.self, forKey: .pollIntervalSeconds)
    cacheRetentionDays = try container.decodeIfPresent(Int.self, forKey: .cacheRetentionDays)
      ?? AppConfiguration.defaultCacheRetentionDays
  }

  public func validate() throws {
    _ = try ResetCycle(term: defaultResetTerm)
    guard (1...65_535).contains(dashboardPort) else { throw ConfigurationError.invalidPort(dashboardPort) }
    guard pollIntervalSeconds > 0 else { throw ConfigurationError.invalidPollInterval(pollIntervalSeconds) }
    guard cacheRetentionDays > 0 else { throw ConfigurationError.invalidCacheRetention(cacheRetentionDays) }
    if let ccusagePath, !ccusagePath.hasPrefix("/") { throw ConfigurationError.pathMustBeAbsolute }
  }
}

public enum ConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidResetTerm(String)
  case invalidPort(Int)
  case invalidPollInterval(Int)
  case invalidCacheRetention(Int)
  case pathMustBeAbsolute

  public var description: String {
    switch self {
    case .invalidResetTerm(let value): "Unsupported reset term: \(value)"
    case .invalidPort(let value): "Dashboard port must be between 1 and 65535 (received \(value))"
    case .invalidPollInterval(let value): "Poll interval must be positive (received \(value))"
    case .invalidCacheRetention(let value): "Cache retention days must be positive (received \(value))"
    case .pathMustBeAbsolute: "Configured ccusagePath must be an absolute path"
    }
  }
}

public struct AppPaths: Sendable {
  public let configFile: URL
  public let stateFile: URL
  public let aggregationCacheFile: URL
  public let dashboardStateFile: URL
  public let machinesFile: URL

  public init(
    configFile: URL,
    stateFile: URL,
    aggregationCacheFile: URL,
    dashboardStateFile: URL? = nil,
    machinesFile: URL? = nil
  ) {
    self.configFile = configFile
    self.stateFile = stateFile
    self.aggregationCacheFile = aggregationCacheFile
    self.dashboardStateFile = dashboardStateFile
      ?? aggregationCacheFile.deletingLastPathComponent().appendingPathComponent("dashboard-state.sqlite3")
    self.machinesFile = machinesFile ?? configFile.deletingLastPathComponent().appendingPathComponent("machines.json")
  }

  public func aggregationCacheFile(forMachine machineID: String) -> URL {
    aggregationCacheFile.deletingLastPathComponent().appendingPathComponent("aggregates-\(machineID).sqlite3")
  }

  public static func production(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
    let home = URL(fileURLWithPath: environment["CCUSAGE_GAUGE_HOME"] ?? environment["HOME"] ?? NSHomeDirectory())
    let configRoot = environment["CCUSAGE_GAUGE_CONFIG_HOME"].map(URL.init(fileURLWithPath:))
      ?? home.appendingPathComponent(".config", isDirectory: true)
    let stateRoot = environment["CCUSAGE_GAUGE_STATE_HOME"].map(URL.init(fileURLWithPath:))
      ?? home.appendingPathComponent(".local", isDirectory: true)
    let cacheRoot = environment["CCUSAGE_GAUGE_CACHE_HOME"].map(URL.init(fileURLWithPath:))
      ?? home.appendingPathComponent(".cache", isDirectory: true)
    return AppPaths(
      configFile: configRoot.appendingPathComponent("ccusage-gauge/ccusage-config.json"),
      stateFile: stateRoot.appendingPathComponent("ccusage-gauge/state.json"),
      aggregationCacheFile: cacheRoot.appendingPathComponent("ccusage-gauge/aggregates.sqlite3"),
      dashboardStateFile: cacheRoot.appendingPathComponent("ccusage-gauge/dashboard-state.sqlite3")
    )
  }
}

public struct ConfigStore {
  public let fileURL: URL
  private let fileManager: FileManager

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public func loadOrCreate() throws -> AppConfiguration {
    if !fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(AppConfiguration())
      data.append(0x0A)
      try data.write(to: fileURL, options: .atomic)
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: fileURL))
    try configuration.validate()
    return configuration
  }
}
