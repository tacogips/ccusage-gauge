import Foundation

public struct ChartColorSchemeConfiguration: Codable, Equatable, Sendable {
  public var machines: [String: String]
  public var models: [String: String]

  private enum CodingKeys: String, CodingKey { case machines, models }

  public init(machines: [String: String] = [:], models: [String: String] = [:]) {
    self.machines = machines
    self.models = models
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    machines = try container.decodeIfPresent([String: String].self, forKey: .machines) ?? [:]
    models = try container.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
  }

  public func validate(scheme: String) throws {
    for (section, colors) in [("machines", machines), ("models", models)] {
      for (key, color) in colors {
        guard !key.isEmpty, key.utf8.count <= 256,
              !key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
          throw ConfigurationError.invalidChartColorKey(section: "\(scheme).\(section)", key: key)
        }
        guard Self.isHexColor(color) else {
          throw ConfigurationError.invalidChartColor(section: "\(scheme).\(section)", key: key, value: color)
        }
      }
    }
  }

  private static func isHexColor(_ value: String) -> Bool {
    guard value.utf8.count == 7, value.first == "#" else { return false }
    return value.dropFirst().allSatisfy { $0.isHexDigit }
  }
}

public struct ChartColorConfiguration: Codable, Equatable, Sendable {
  public var light: ChartColorSchemeConfiguration
  public var dark: ChartColorSchemeConfiguration

  private enum CodingKeys: String, CodingKey { case light, dark, machines, models }

  public init(
    light: ChartColorSchemeConfiguration = ChartColorSchemeConfiguration(),
    dark: ChartColorSchemeConfiguration = ChartColorSchemeConfiguration()
  ) {
    self.light = light
    self.dark = dark
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.light) || container.contains(.dark) {
      light = try container.decodeIfPresent(ChartColorSchemeConfiguration.self, forKey: .light)
        ?? ChartColorSchemeConfiguration()
      dark = try container.decodeIfPresent(ChartColorSchemeConfiguration.self, forKey: .dark)
        ?? ChartColorSchemeConfiguration()
    } else {
      let legacy = ChartColorSchemeConfiguration(
        machines: try container.decodeIfPresent([String: String].self, forKey: .machines) ?? [:],
        models: try container.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
      )
      light = legacy
      dark = legacy
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(light, forKey: .light)
    try container.encode(dark, forKey: .dark)
  }

  public func validate() throws {
    try light.validate(scheme: "light")
    try dark.validate(scheme: "dark")
  }
}

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
  public static let defaultRemoteRetryCount = 3
  public static let defaultRemoteTimeoutSeconds = 15

  public var ccusagePath: String?
  public var defaultResetTerm: String
  public var dashboardPort: Int
  public var dashboardAutostart: Bool
  public var pollIntervalSeconds: Int
  public var cacheRetentionDays: Int
  public var remoteRetryCount: Int
  public var remoteTimeoutSeconds: Int
  public var chartColors: ChartColorConfiguration

  public init(
    ccusagePath: String? = nil,
    defaultResetTerm: String = "daily",
    dashboardPort: Int = 18_081,
    dashboardAutostart: Bool = true,
    pollIntervalSeconds: Int = AppConfiguration.defaultPollIntervalSeconds,
    cacheRetentionDays: Int = AppConfiguration.defaultCacheRetentionDays,
    remoteRetryCount: Int = AppConfiguration.defaultRemoteRetryCount,
    remoteTimeoutSeconds: Int = AppConfiguration.defaultRemoteTimeoutSeconds,
    chartColors: ChartColorConfiguration = ChartColorConfiguration()
  ) {
    self.ccusagePath = ccusagePath
    self.defaultResetTerm = defaultResetTerm
    self.dashboardPort = dashboardPort
    self.dashboardAutostart = dashboardAutostart
    self.pollIntervalSeconds = pollIntervalSeconds
    self.cacheRetentionDays = cacheRetentionDays
    self.remoteRetryCount = remoteRetryCount
    self.remoteTimeoutSeconds = remoteTimeoutSeconds
    self.chartColors = chartColors
  }

  private enum CodingKeys: String, CodingKey {
    case ccusagePath, defaultResetTerm, dashboardPort, dashboardAutostart
    case pollIntervalSeconds, cacheRetentionDays, remoteRetryCount, remoteTimeoutSeconds, chartColors
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
    remoteRetryCount = try container.decodeIfPresent(Int.self, forKey: .remoteRetryCount)
      ?? AppConfiguration.defaultRemoteRetryCount
    remoteTimeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .remoteTimeoutSeconds)
      ?? AppConfiguration.defaultRemoteTimeoutSeconds
    chartColors = try container.decodeIfPresent(ChartColorConfiguration.self, forKey: .chartColors)
      ?? ChartColorConfiguration()
  }

  public func validate() throws {
    _ = try ResetCycle(term: defaultResetTerm)
    guard (1...65_535).contains(dashboardPort) else { throw ConfigurationError.invalidPort(dashboardPort) }
    guard pollIntervalSeconds > 0 else { throw ConfigurationError.invalidPollInterval(pollIntervalSeconds) }
    guard cacheRetentionDays > 0 else { throw ConfigurationError.invalidCacheRetention(cacheRetentionDays) }
    guard (0...10).contains(remoteRetryCount) else {
      throw ConfigurationError.invalidRemoteRetryCount(remoteRetryCount)
    }
    guard (1...600).contains(remoteTimeoutSeconds) else {
      throw ConfigurationError.invalidRemoteTimeout(remoteTimeoutSeconds)
    }
    if let ccusagePath, !ccusagePath.hasPrefix("/") { throw ConfigurationError.pathMustBeAbsolute }
    try chartColors.validate()
  }
}

public enum ConfigurationError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidResetTerm(String)
  case invalidPort(Int)
  case invalidPollInterval(Int)
  case invalidCacheRetention(Int)
  case invalidRemoteRetryCount(Int)
  case invalidRemoteTimeout(Int)
  case invalidChartColorKey(section: String, key: String)
  case invalidChartColor(section: String, key: String, value: String)
  case pathMustBeAbsolute

  public var description: String {
    switch self {
    case .invalidResetTerm(let value): "Unsupported reset term: \(value)"
    case .invalidPort(let value): "Dashboard port must be between 1 and 65535 (received \(value))"
    case .invalidPollInterval(let value): "Poll interval must be positive (received \(value))"
    case .invalidCacheRetention(let value): "Cache retention days must be positive (received \(value))"
    case .invalidRemoteRetryCount(let value): "Remote retry count must be between 0 and 10 (received \(value))"
    case .invalidRemoteTimeout(let value): "Remote timeout must be between 1 and 600 seconds (received \(value))"
    case .invalidChartColorKey(let section, let key): "Chart color key in \(section) is invalid: \(key.debugDescription)"
    case .invalidChartColor(let section, let key, let value): "Chart color for \(section).\(key) must use #RRGGBB (received \(value))"
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
  public let logDirectory: URL

  public init(
    configFile: URL,
    stateFile: URL,
    aggregationCacheFile: URL,
    dashboardStateFile: URL? = nil,
    machinesFile: URL? = nil,
    logDirectory: URL? = nil
  ) {
    self.configFile = configFile
    self.stateFile = stateFile
    self.aggregationCacheFile = aggregationCacheFile
    self.dashboardStateFile = dashboardStateFile
      ?? aggregationCacheFile.deletingLastPathComponent().appendingPathComponent("dashboard-state.sqlite3")
    self.machinesFile = machinesFile ?? configFile.deletingLastPathComponent().appendingPathComponent("machines.json")
    self.logDirectory = logDirectory
      ?? stateFile.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
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

  public static func defaultLogDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    let home = URL(fileURLWithPath: environment["CCUSAGE_GAUGE_HOME"] ?? environment["HOME"] ?? NSHomeDirectory())
    return home.appendingPathComponent(".local/ccusage-gauge/logs", isDirectory: true)
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
