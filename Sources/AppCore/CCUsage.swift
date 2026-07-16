import Foundation

public struct CCUsageCostRecord: Codable, Equatable, Sendable {
  public let timestamp: Date
  public let costUSD: Decimal
  public let models: [String]

  public init(timestamp: Date, costUSD: Decimal, models: [String]) {
    self.timestamp = timestamp
    self.costUSD = costUSD
    self.models = models
  }
}

public struct CCUsageDailyRecord: Codable, Equatable, Sendable {
  public let period: String
  public let costUSD: Decimal
  public let models: [String]

  public init(period: String, costUSD: Decimal, models: [String]) {
    self.period = period
    self.costUSD = costUSD
    self.models = models
  }
}

public struct CCUsageMetricRecord: Codable, Equatable, Sendable {
  public let date: String
  public let agent: String
  public let model: String
  public let costUSD: Decimal
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheCreationTokens: Int
  public let cacheReadTokens: Int
  public let totalTokens: Int

  public init(
    date: String,
    agent: String,
    model: String,
    costUSD: Decimal,
    inputTokens: Int,
    outputTokens: Int,
    cacheCreationTokens: Int,
    cacheReadTokens: Int
  ) {
    self.date = date
    self.agent = agent
    self.model = model
    self.costUSD = costUSD
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheCreationTokens = cacheCreationTokens
    self.cacheReadTokens = cacheReadTokens
    totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
  }
}

public enum UsageDataQuality: String, Codable, Equatable, Sendable {
  case timestamped
  case sessionEstimated
}

public struct CCUsageSessionMetricRecord: Codable, Equatable, Sendable {
  public let timestamp: Date
  public let agent: String
  public let model: String
  public let costUSD: Decimal
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheCreationTokens: Int
  public let cacheReadTokens: Int
  public let totalTokens: Int
  public let dataQuality: UsageDataQuality

  public init(
    timestamp: Date,
    agent: String,
    model: String,
    costUSD: Decimal,
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    cacheCreationTokens: Int = 0,
    cacheReadTokens: Int = 0,
    dataQuality: UsageDataQuality = .sessionEstimated
  ) {
    self.timestamp = timestamp
    self.agent = agent
    self.model = model
    self.costUSD = costUSD
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheCreationTokens = cacheCreationTokens
    self.cacheReadTokens = cacheReadTokens
    self.dataQuality = dataQuality
    totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
  }
}

public struct CCUsageExecutableResolver {
  public let fileManager: FileManager

  public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

  public func resolve(
    configuredPath: String?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    additionalSearchDirectories: [String] = []
  ) throws -> URL {
    if let configuredPath {
      guard configuredPath.hasPrefix("/") else { throw CCUsageError.invalidConfiguredPath }
      let url = URL(fileURLWithPath: configuredPath)
      guard fileManager.isExecutableFile(atPath: url.path) else { throw CCUsageError.executableMissing(configuredPath) }
      return url
    }
    let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    for directory in pathDirectories + additionalSearchDirectories {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent("ccusage")
      if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    throw CCUsageError.executableMissing("ccusage")
  }
}

public struct ProcessResult: Sendable {
  public let stdout: Data
  public let stderr: Data
  public let exitStatus: Int32
}

public struct CCUsageDetailedUsage: Equatable, Sendable {
  public let metrics: [CCUsageMetricRecord]
  public let sessions: [CCUsageSessionMetricRecord]

  public init(metrics: [CCUsageMetricRecord], sessions: [CCUsageSessionMetricRecord]) {
    self.metrics = metrics
    self.sessions = sessions
  }
}

public struct CCUsageProcessRunner: Sendable {
  public init() {}

  public func run(executable: URL, arguments: [String], timeoutSeconds: TimeInterval = 30) async throws -> ProcessResult {
    try await Task.detached(priority: .utility) {
      let process = Process()
      let stdout = Pipe()
      let stderr = Pipe()
      process.executableURL = executable
      process.arguments = arguments
      process.standardOutput = stdout
      process.standardError = stderr
      do { try process.run() } catch { throw CCUsageError.launchFailed }

      // Drain both pipes concurrently while the process runs. Reading only after
      // exit would deadlock once ccusage output exceeds the OS pipe buffer
      // (~64 KB): the child would block writing to a full pipe and never exit.
      let outHandle = stdout.fileHandleForReading
      let errHandle = stderr.fileHandleForReading
      async let outData = Task.detached(priority: .utility) { outHandle.readDataToEndOfFile() }.value
      async let errData = Task.detached(priority: .utility) { errHandle.readDataToEndOfFile() }.value

      let deadline = Date().addingTimeInterval(timeoutSeconds)
      while process.isRunning && Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
      }
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        _ = await outData
        _ = await errData
        throw CCUsageError.timedOut
      }
      let output = await outData
      let errorOutput = await errData
      guard process.terminationStatus == 0 else { throw CCUsageError.nonzeroExit(process.terminationStatus) }
      return ProcessResult(stdout: output, stderr: errorOutput, exitStatus: process.terminationStatus)
    }.value
  }

}

public enum CCUsageDecoder {
  private struct BlocksEnvelope: Decodable { let blocks: [Block] }
  private struct Block: Decodable {
    let startTime: String
    let costUSD: Decimal
    let models: [String]
  }
  private struct DailyEnvelope: Decodable { let daily: [Day] }
  private struct Day: Decodable {
    let period: String
    let totalCost: Decimal
    let modelsUsed: [String]
    let modelBreakdowns: [Breakdown]?
  }
  private struct Breakdown: Decodable { let modelName: String; let cost: Decimal }
  private struct DetailedDailyEnvelope: Decodable { let daily: [DetailedDay] }
  private struct DetailedDay: Decodable {
    let period: String
    let agents: [DetailedAgent]
  }
  private struct DetailedAgent: Decodable {
    let agent: String
    let modelBreakdowns: [DetailedBreakdown]
  }
  private struct DetailedBreakdown: Decodable {
    let modelName: String
    let cost: Decimal
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
  }
  private struct DetailedSessionEnvelope: Decodable { let session: [DetailedSession] }
  private struct DetailedUsageEnvelope: Decodable {
    let daily: [DetailedDay]
    let session: [DetailedSession]?
  }
  private struct DetailedSession: Decodable {
    let agent: String
    let metadata: SessionMetadata
    let modelBreakdowns: [DetailedBreakdown]
  }
  private struct SessionMetadata: Decodable { let lastActivity: String }

  public static func blocks(from data: Data) throws -> [CCUsageCostRecord] {
    do {
      return try decoder.decode(BlocksEnvelope.self, from: data).blocks.map {
        guard let timestamp = parseTimestamp($0.startTime) else { throw CCUsageError.invalidJSON }
        return CCUsageCostRecord(timestamp: timestamp, costUSD: $0.costUSD, models: $0.models)
      }
    } catch { throw CCUsageError.invalidJSON }
  }

  public static func daily(from data: Data) throws -> [CCUsageDailyRecord] {
    do {
      return try decoder.decode(DailyEnvelope.self, from: data).daily.map { day in
        let cost = day.modelBreakdowns.map { $0.reduce(Decimal.zero) { $0 + $1.cost } } ?? day.totalCost
        let models = day.modelBreakdowns?.map(\.modelName) ?? day.modelsUsed
        return CCUsageDailyRecord(period: day.period, costUSD: cost, models: models)
      }
    } catch { throw CCUsageError.invalidJSON }
  }

  public static func detailedDaily(from data: Data) throws -> [CCUsageMetricRecord] {
    do {
      return try decoder.decode(DetailedDailyEnvelope.self, from: data).daily.flatMap { day in
        day.agents.flatMap { agent in
          agent.modelBreakdowns.map { breakdown in
            CCUsageMetricRecord(
              date: day.period,
              agent: agent.agent,
              model: breakdown.modelName,
              costUSD: breakdown.cost,
              inputTokens: breakdown.inputTokens,
              outputTokens: breakdown.outputTokens,
              cacheCreationTokens: breakdown.cacheCreationTokens,
              cacheReadTokens: breakdown.cacheReadTokens
            )
          }
        }
      }
    } catch { throw CCUsageError.invalidJSON }
  }

  public static func detailedSessions(from data: Data) throws -> [CCUsageSessionMetricRecord] {
    do {
      return try decoder.decode(DetailedSessionEnvelope.self, from: data).session.flatMap { session in
        guard let timestamp = parseTimestamp(session.metadata.lastActivity) else { throw CCUsageError.invalidJSON }
        return session.modelBreakdowns.map { breakdown in
          CCUsageSessionMetricRecord(
            timestamp: timestamp,
            agent: session.agent,
            model: breakdown.modelName,
            costUSD: breakdown.cost,
            inputTokens: breakdown.inputTokens,
            outputTokens: breakdown.outputTokens,
            cacheCreationTokens: breakdown.cacheCreationTokens,
            cacheReadTokens: breakdown.cacheReadTokens
          )
        }
      }
    } catch let error as CCUsageError {
      throw error
    } catch {
      throw CCUsageError.invalidJSON
    }
  }

  public static func detailedUsage(from data: Data) throws -> CCUsageDetailedUsage {
    do {
      let envelope = try decoder.decode(DetailedUsageEnvelope.self, from: data)
      return CCUsageDetailedUsage(
        metrics: metricRecords(from: envelope.daily),
        sessions: try sessionRecords(from: envelope.session ?? [])
      )
    } catch let error as CCUsageError {
      throw error
    } catch {
      throw CCUsageError.invalidJSON
    }
  }

  private static func metricRecords(from days: [DetailedDay]) -> [CCUsageMetricRecord] {
    days.flatMap { day in
      day.agents.flatMap { agent in
        agent.modelBreakdowns.map { breakdown in
          CCUsageMetricRecord(
            date: day.period,
            agent: agent.agent,
            model: breakdown.modelName,
            costUSD: breakdown.cost,
            inputTokens: breakdown.inputTokens,
            outputTokens: breakdown.outputTokens,
            cacheCreationTokens: breakdown.cacheCreationTokens,
            cacheReadTokens: breakdown.cacheReadTokens
          )
        }
      }
    }
  }

  private static func sessionRecords(from sessions: [DetailedSession]) throws -> [CCUsageSessionMetricRecord] {
    try sessions.flatMap { session in
      guard let timestamp = parseTimestamp(session.metadata.lastActivity) else { throw CCUsageError.invalidJSON }
      return session.modelBreakdowns.map { breakdown in
        CCUsageSessionMetricRecord(
          timestamp: timestamp,
          agent: session.agent,
          model: breakdown.modelName,
          costUSD: breakdown.cost,
          inputTokens: breakdown.inputTokens,
          outputTokens: breakdown.outputTokens,
          cacheCreationTokens: breakdown.cacheCreationTokens,
          cacheReadTokens: breakdown.cacheReadTokens
        )
      }
    }
  }

  private static func parseTimestamp(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

private actor CCUsageDetailedUsageLoader {
  private enum ArgumentMode {
    case flagFree
    case byAgent
  }

  private struct LoadedUsage: Sendable {
    let usage: CCUsageDetailedUsage
    let mode: ArgumentMode
  }

  private var argumentMode: ArgumentMode?
  private var cachedUsage: CCUsageDetailedUsage?
  private var cachedAt: Date?
  private var inFlight: Task<LoadedUsage, Error>?

  func load(
    executable: URL,
    runner: CCUsageProcessRunner,
    maxAgeSeconds: TimeInterval = 1
  ) async throws -> CCUsageDetailedUsage {
    let now = Date()
    if let cachedUsage, let cachedAt, now.timeIntervalSince(cachedAt) <= maxAgeSeconds {
      return cachedUsage
    }
    if let inFlight { return try await inFlight.value.usage }
    let preferredMode = argumentMode
    let task = Task {
      try await Self.load(executable: executable, runner: runner, preferredMode: preferredMode)
    }
    inFlight = task
    do {
      let loaded = try await task.value
      argumentMode = loaded.mode
      cachedUsage = loaded.usage
      cachedAt = Date()
      inFlight = nil
      return loaded.usage
    } catch {
      inFlight = nil
      throw error
    }
  }

  private static func load(
    executable: URL,
    runner: CCUsageProcessRunner,
    preferredMode: ArgumentMode?
  ) async throws -> LoadedUsage {
    if preferredMode == .byAgent {
      return try await load(executable: executable, runner: runner, mode: .byAgent)
    }
    if preferredMode == .flagFree {
      return try await load(executable: executable, runner: runner, mode: .flagFree)
    }
    do {
      return try await load(executable: executable, runner: runner, mode: .flagFree)
    } catch CCUsageError.invalidJSON {
      return try await load(executable: executable, runner: runner, mode: .byAgent)
    }
  }

  private static func load(
    executable: URL,
    runner: CCUsageProcessRunner,
    mode: ArgumentMode
  ) async throws -> LoadedUsage {
    var arguments = ["daily", "--json", "--sections", "daily,session"]
    if mode == .byAgent { arguments.insert("--by-agent", at: 2) }
    let result = try await runner.run(executable: executable, arguments: arguments)
    return LoadedUsage(usage: try CCUsageDecoder.detailedUsage(from: result.stdout), mode: mode)
  }
}

private actor CCUsageBlocksLoader {
  private struct CachedBlocks: Sendable {
    let since: String?
    let until: String?
    let records: [CCUsageCostRecord]
    let loadedAt: Date
  }

  private struct InFlightBlocks: Sendable {
    let since: String?
    let until: String?
    let task: Task<[CCUsageCostRecord], Error>
  }

  private var cached: CachedBlocks?
  private var inFlight: InFlightBlocks?

  func load(
    executable: URL,
    runner: CCUsageProcessRunner,
    since: String?,
    until: String?,
    maxAgeSeconds: TimeInterval = 1
  ) async throws -> [CCUsageCostRecord] {
    let now = Date()
    if let cached,
       cached.since == since,
       cached.until == until,
       now.timeIntervalSince(cached.loadedAt) <= maxAgeSeconds {
      return cached.records
    }
    if let inFlight, inFlight.since == since, inFlight.until == until {
      return try await inFlight.task.value
    }
    let task = Task {
      var arguments = ["blocks", "--json"]
      if let since { arguments += ["--since", since] }
      if let until { arguments += ["--until", until] }
      let result = try await runner.run(executable: executable, arguments: arguments)
      return try CCUsageDecoder.blocks(from: result.stdout)
    }
    inFlight = InFlightBlocks(since: since, until: until, task: task)
    do {
      let records = try await task.value
      cached = CachedBlocks(since: since, until: until, records: records, loadedAt: Date())
      inFlight = nil
      return records
    } catch {
      inFlight = nil
      throw error
    }
  }
}

private actor CCUsageDetailedDailyLoader {
  private enum ArgumentMode {
    case flagFree
    case byAgent
  }

  private var argumentMode: ArgumentMode?

  func load(
    executable: URL,
    runner: CCUsageProcessRunner,
    arguments: [String]
  ) async throws -> [CCUsageMetricRecord] {
    if argumentMode == .flagFree {
      return try await loadFlagFree(executable: executable, runner: runner, arguments: arguments)
    }
    if argumentMode == .byAgent {
      return try await loadWithByAgent(executable: executable, runner: runner, arguments: arguments)
    }

    do {
      let records = try await loadFlagFree(executable: executable, runner: runner, arguments: arguments)
      argumentMode = .flagFree
      return records
    } catch CCUsageError.invalidJSON {
      let records = try await loadWithByAgent(executable: executable, runner: runner, arguments: arguments)
      argumentMode = .byAgent
      return records
    }
  }

  private func loadFlagFree(
    executable: URL,
    runner: CCUsageProcessRunner,
    arguments: [String]
  ) async throws -> [CCUsageMetricRecord] {
    let result = try await runner.run(executable: executable, arguments: arguments)
    return try CCUsageDecoder.detailedDaily(from: result.stdout)
  }

  private func loadWithByAgent(
    executable: URL,
    runner: CCUsageProcessRunner,
    arguments: [String]
  ) async throws -> [CCUsageMetricRecord] {
    var compatibleArguments = arguments
    compatibleArguments.insert("--by-agent", at: 2)
    let result = try await runner.run(executable: executable, arguments: compatibleArguments)
    return try CCUsageDecoder.detailedDaily(from: result.stdout)
  }
}

public struct CCUsageClient: Sendable {
  public let executable: URL
  public let runner: CCUsageProcessRunner
  private let detailedDailyLoader: CCUsageDetailedDailyLoader
  private let detailedUsageLoader: CCUsageDetailedUsageLoader
  private let blocksLoader: CCUsageBlocksLoader

  public init(executable: URL, runner: CCUsageProcessRunner = CCUsageProcessRunner()) {
    self.executable = executable
    self.runner = runner
    detailedDailyLoader = CCUsageDetailedDailyLoader()
    detailedUsageLoader = CCUsageDetailedUsageLoader()
    blocksLoader = CCUsageBlocksLoader()
  }

  public func blocks(since: String? = nil, until: String? = nil) async throws -> [CCUsageCostRecord] {
    try await blocksLoader.load(
      executable: executable,
      runner: runner,
      since: since,
      until: until
    )
  }

  public func daily() async throws -> [CCUsageDailyRecord] {
    let result = try await runner.run(executable: executable, arguments: ["daily", "--json"])
    return try CCUsageDecoder.daily(from: result.stdout)
  }

  public func detailedDaily(since: String? = nil, until: String? = nil) async throws -> [CCUsageMetricRecord] {
    try await detailedDailyLoader.load(
      executable: executable,
      runner: runner,
      arguments: filteredArguments(command: "daily", since: since, until: until)
    )
  }

  public func detailedSessions(since: String? = nil, until: String? = nil) async throws -> [CCUsageSessionMetricRecord] {
    let result = try await runner.run(
      executable: executable,
      arguments: filteredArguments(command: "session", since: since, until: until)
    )
    return try CCUsageDecoder.detailedSessions(from: result.stdout)
  }

  public func detailedUsage() async throws -> CCUsageDetailedUsage {
    try await detailedUsageLoader.load(executable: executable, runner: runner)
  }

  private func filteredArguments(command: String, since: String?, until: String?) -> [String] {
    var arguments = [command, "--json"]
    if let since { arguments += ["--since", since] }
    if let until { arguments += ["--until", until] }
    return arguments
  }
}

public enum CCUsageError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidConfiguredPath
  case executableMissing(String)
  case launchFailed
  case timedOut
  case nonzeroExit(Int32)
  case invalidJSON

  public var description: String {
    switch self {
    case .invalidConfiguredPath: "Configured ccusagePath must be absolute."
    case .executableMissing(let path): "ccusage executable is unavailable at \(path). Install ccusage or correct ccusagePath."
    case .launchFailed: "ccusage could not be launched."
    case .timedOut: "ccusage timed out."
    case .nonzeroExit(let status): "ccusage exited with status \(status)."
    case .invalidJSON: "ccusage returned unsupported JSON."
    }
  }
}
