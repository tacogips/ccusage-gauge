import Foundation

public struct CCUsageCostRecord: Codable, Equatable, Sendable {
  public let timestamp: Date
  public let costUSD: Decimal
  public let models: [String]
  public let machine: String

  public init(timestamp: Date, costUSD: Decimal, models: [String], machine: String = "local") {
    self.timestamp = timestamp
    self.costUSD = costUSD
    self.models = models
    self.machine = machine
  }

  private enum CodingKeys: String, CodingKey { case timestamp, costUSD, models, machine }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    timestamp = try values.decode(Date.self, forKey: .timestamp)
    costUSD = try values.decode(Decimal.self, forKey: .costUSD)
    models = try values.decode([String].self, forKey: .models)
    machine = try values.decodeIfPresent(String.self, forKey: .machine) ?? "local"
    guard !machine.isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .machine, in: values, debugDescription: "machine must not be empty")
    }
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
  public let machine: String

  public init(
    date: String,
    agent: String,
    model: String,
    costUSD: Decimal,
    inputTokens: Int,
    outputTokens: Int,
    cacheCreationTokens: Int,
    cacheReadTokens: Int,
    machine: String = "local"
  ) {
    self.date = date
    self.agent = agent
    self.model = model
    self.costUSD = costUSD
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheCreationTokens = cacheCreationTokens
    self.cacheReadTokens = cacheReadTokens
    self.machine = machine
    totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
  }

  private enum CodingKeys: String, CodingKey {
    case date, agent, model, costUSD, inputTokens, outputTokens
    case cacheCreationTokens, cacheReadTokens, totalTokens, machine
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    date = try values.decode(String.self, forKey: .date)
    agent = try values.decode(String.self, forKey: .agent)
    model = try values.decode(String.self, forKey: .model)
    costUSD = try values.decode(Decimal.self, forKey: .costUSD)
    inputTokens = try values.decode(Int.self, forKey: .inputTokens)
    outputTokens = try values.decode(Int.self, forKey: .outputTokens)
    cacheCreationTokens = try values.decode(Int.self, forKey: .cacheCreationTokens)
    cacheReadTokens = try values.decode(Int.self, forKey: .cacheReadTokens)
    totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    machine = try values.decodeIfPresent(String.self, forKey: .machine) ?? "local"
    guard !machine.isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .machine, in: values, debugDescription: "machine must not be empty")
    }
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
  public let machine: String

  public init(
    timestamp: Date,
    agent: String,
    model: String,
    costUSD: Decimal,
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    cacheCreationTokens: Int = 0,
    cacheReadTokens: Int = 0,
    dataQuality: UsageDataQuality = .sessionEstimated,
    machine: String = "local"
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
    self.machine = machine
    totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
  }

  private enum CodingKeys: String, CodingKey {
    case timestamp, agent, model, costUSD, inputTokens, outputTokens
    case cacheCreationTokens, cacheReadTokens, totalTokens, dataQuality, machine
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    timestamp = try values.decode(Date.self, forKey: .timestamp)
    agent = try values.decode(String.self, forKey: .agent)
    model = try values.decode(String.self, forKey: .model)
    costUSD = try values.decode(Decimal.self, forKey: .costUSD)
    inputTokens = try values.decode(Int.self, forKey: .inputTokens)
    outputTokens = try values.decode(Int.self, forKey: .outputTokens)
    cacheCreationTokens = try values.decode(Int.self, forKey: .cacheCreationTokens)
    cacheReadTokens = try values.decode(Int.self, forKey: .cacheReadTokens)
    dataQuality = try values.decode(UsageDataQuality.self, forKey: .dataQuality)
    totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    machine = try values.decodeIfPresent(String.self, forKey: .machine) ?? "local"
    guard !machine.isEmpty else {
      throw DecodingError.dataCorruptedError(forKey: .machine, in: values, debugDescription: "machine must not be empty")
    }
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

public struct CCUsageDetailedUsage: Equatable, Sendable {
  public let metrics: [CCUsageMetricRecord]
  public let sessions: [CCUsageSessionMetricRecord]

  public init(metrics: [CCUsageMetricRecord], sessions: [CCUsageSessionMetricRecord]) {
    self.metrics = metrics
    self.sessions = sessions
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

  private struct RangeKey: Hashable {
    let since: String?
    let until: String?
    let timezone: String?
  }

  private struct CachedUsage: Sendable {
    let usage: CCUsageDetailedUsage
    let loadedAt: Date
  }

  private var argumentMode: ArgumentMode?
  private var cachedUsage: [RangeKey: CachedUsage] = [:]
  private var inFlight: [RangeKey: Task<LoadedUsage, Error>] = [:]

  func load(
    runner: any CCUsageCommandRunner,
    since: String? = nil,
    until: String? = nil,
    timezone: String? = nil,
    maxAgeSeconds: TimeInterval = 1
  ) async throws -> CCUsageDetailedUsage {
    let key = RangeKey(since: since, until: until, timezone: timezone)
    let now = Date()
    if let cached = cachedUsage[key], now.timeIntervalSince(cached.loadedAt) <= maxAgeSeconds {
      return cached.usage
    }
    if let existing = inFlight[key] { return try await existing.value.usage }
    let preferredMode = argumentMode
    let task = Task {
      try await Self.load(runner: runner, since: since, until: until, timezone: timezone, preferredMode: preferredMode)
    }
    inFlight[key] = task
    do {
      let loaded = try await task.value
      // Only lock in the detected argument mode when the response actually contained rows.
      // A scoped range with no usage decodes successfully via the flag-free path without ever
      // exercising the per-row `agents` field, so caching `.flagFree` from an empty response
      // would wrongly suppress the `--by-agent` fallback for a later non-empty range on a
      // ccusage build whose flag-free daily rows omit `agents`. Leaving the mode inconclusive
      // lets the next non-empty range re-probe flag-free-then-byAgent.
      if !isEmptyUsage(loaded.usage) {
        argumentMode = loaded.mode
      }
      cachedUsage[key] = CachedUsage(usage: loaded.usage, loadedAt: Date())
      pruneExpiredCache(maxAgeSeconds: maxAgeSeconds)
      inFlight[key] = nil
      return loaded.usage
    } catch {
      inFlight[key] = nil
      throw error
    }
  }

  private func isEmptyUsage(_ usage: CCUsageDetailedUsage) -> Bool {
    usage.metrics.isEmpty && usage.sessions.isEmpty
  }

  private func pruneExpiredCache(maxAgeSeconds: TimeInterval) {
    let now = Date()
    cachedUsage = cachedUsage.filter { now.timeIntervalSince($0.value.loadedAt) <= maxAgeSeconds }
  }

  private static func load(
    runner: any CCUsageCommandRunner,
    since: String?,
    until: String?,
    timezone: String?,
    preferredMode: ArgumentMode?
  ) async throws -> LoadedUsage {
    if preferredMode == .byAgent {
      return try await load(runner: runner, since: since, until: until, timezone: timezone, mode: .byAgent)
    }
    if preferredMode == .flagFree {
      return try await load(runner: runner, since: since, until: until, timezone: timezone, mode: .flagFree)
    }
    do {
      return try await load(runner: runner, since: since, until: until, timezone: timezone, mode: .flagFree)
    } catch CCUsageError.invalidJSON {
      return try await load(runner: runner, since: since, until: until, timezone: timezone, mode: .byAgent)
    }
  }

  private static func load(
    runner: any CCUsageCommandRunner,
    since: String?,
    until: String?,
    timezone: String?,
    mode: ArgumentMode
  ) async throws -> LoadedUsage {
    var arguments = ["daily", "--json", "--sections", "daily,session"]
    if mode == .byAgent { arguments.insert("--by-agent", at: 2) }
    if let since { arguments += ["--since", since] }
    if let until { arguments += ["--until", until] }
    if let timezone { arguments += ["--timezone", timezone] }
    let result = try await runner.run(arguments: arguments, timeoutSeconds: 30)
    return LoadedUsage(usage: try CCUsageDecoder.detailedUsage(from: result.stdout), mode: mode)
  }
}

private actor CCUsageBlocksLoader {
  private struct CachedBlocks: Sendable {
    let since: String?
    let until: String?
    let timezone: String?
    let records: [CCUsageCostRecord]
    let loadedAt: Date
  }

  private struct InFlightBlocks: Sendable {
    let since: String?
    let until: String?
    let timezone: String?
    let task: Task<[CCUsageCostRecord], Error>
  }

  private var cached: CachedBlocks?
  private var inFlight: InFlightBlocks?

  func load(
    runner: any CCUsageCommandRunner,
    since: String?,
    until: String?,
    timezone: String? = nil,
    maxAgeSeconds: TimeInterval = 1
  ) async throws -> [CCUsageCostRecord] {
    let now = Date()
    if let cached,
       cached.since == since,
       cached.until == until,
       cached.timezone == timezone,
       now.timeIntervalSince(cached.loadedAt) <= maxAgeSeconds {
      return cached.records
    }
    if let inFlight, inFlight.since == since, inFlight.until == until, inFlight.timezone == timezone {
      return try await inFlight.task.value
    }
    let task = Task {
      var arguments = ["blocks", "--json"]
      if let since { arguments += ["--since", since] }
      if let until { arguments += ["--until", until] }
      if let timezone { arguments += ["--timezone", timezone] }
      let result = try await runner.run(arguments: arguments, timeoutSeconds: 30)
      return try CCUsageDecoder.blocks(from: result.stdout)
    }
    inFlight = InFlightBlocks(since: since, until: until, timezone: timezone, task: task)
    do {
      let records = try await task.value
      cached = CachedBlocks(since: since, until: until, timezone: timezone, records: records, loadedAt: Date())
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
    runner: any CCUsageCommandRunner,
    arguments: [String]
  ) async throws -> [CCUsageMetricRecord] {
    if argumentMode == .flagFree {
      return try await loadFlagFree(runner: runner, arguments: arguments)
    }
    if argumentMode == .byAgent {
      return try await loadWithByAgent(runner: runner, arguments: arguments)
    }

    do {
      let records = try await loadFlagFree(runner: runner, arguments: arguments)
      // Do not lock in the mode from an empty (rowless) response: it never exercises the
      // per-row `agents` field, so a later non-empty scoped range must stay free to re-probe
      // and fall back to `--by-agent`. Same hazard as CCUsageDetailedUsageLoader.
      if !records.isEmpty { argumentMode = .flagFree }
      return records
    } catch CCUsageError.invalidJSON {
      let records = try await loadWithByAgent(runner: runner, arguments: arguments)
      if !records.isEmpty { argumentMode = .byAgent }
      return records
    }
  }

  private func loadFlagFree(
    runner: any CCUsageCommandRunner,
    arguments: [String]
  ) async throws -> [CCUsageMetricRecord] {
    let result = try await runner.run(arguments: arguments, timeoutSeconds: 30)
    return try CCUsageDecoder.detailedDaily(from: result.stdout)
  }

  private func loadWithByAgent(
    runner: any CCUsageCommandRunner,
    arguments: [String]
  ) async throws -> [CCUsageMetricRecord] {
    var compatibleArguments = arguments
    compatibleArguments.insert("--by-agent", at: 2)
    let result = try await runner.run(arguments: compatibleArguments, timeoutSeconds: 30)
    return try CCUsageDecoder.detailedDaily(from: result.stdout)
  }
}

public struct CCUsageClient: Sendable {
  private let runner: any CCUsageCommandRunner
  public let machine: String
  private let detailedDailyLoader: CCUsageDetailedDailyLoader
  private let detailedUsageLoader: CCUsageDetailedUsageLoader
  private let blocksLoader: CCUsageBlocksLoader

  public init(executable: URL, runner: CCUsageProcessRunner = CCUsageProcessRunner(), machine: String = "local") {
    self.runner = LocalCCUsageCommandRunner(executable: executable, processRunner: runner)
    self.machine = machine
    detailedDailyLoader = CCUsageDetailedDailyLoader()
    detailedUsageLoader = CCUsageDetailedUsageLoader()
    blocksLoader = CCUsageBlocksLoader()
  }

  public init(commandRunner: any CCUsageCommandRunner, machine: String) {
    runner = commandRunner
    self.machine = machine
    detailedDailyLoader = CCUsageDetailedDailyLoader()
    detailedUsageLoader = CCUsageDetailedUsageLoader()
    blocksLoader = CCUsageBlocksLoader()
  }

  public func blocks(since: String? = nil, until: String? = nil, timezone: String? = nil) async throws -> [CCUsageCostRecord] {
    do {
      let records = try await blocksLoader.load(
        runner: runner,
        since: since,
        until: until,
        timezone: timezone
      )
      return records.map {
        CCUsageCostRecord(timestamp: $0.timestamp, costUSD: $0.costUSD, models: $0.models, machine: machine)
      }
    } catch let failure as CCUsageCommandFailure {
      throw CCUsageError.commandFailed(failure)
    }
  }

  public func daily() async throws -> [CCUsageDailyRecord] {
    let result = try await run(["daily", "--json"])
    return try CCUsageDecoder.daily(from: result.stdout)
  }

  public func detailedDaily(since: String? = nil, until: String? = nil, timezone: String? = nil) async throws -> [CCUsageMetricRecord] {
    do {
      return try await detailedDailyLoader.load(
        runner: runner,
        arguments: filteredArguments(command: "daily", since: since, until: until, timezone: timezone)
      ).map { row in
        CCUsageMetricRecord(
          date: row.date,
          agent: row.agent,
          model: row.model,
          costUSD: row.costUSD,
          inputTokens: row.inputTokens,
          outputTokens: row.outputTokens,
          cacheCreationTokens: row.cacheCreationTokens,
          cacheReadTokens: row.cacheReadTokens,
          machine: machine
        )
      }
    } catch let failure as CCUsageCommandFailure {
      throw CCUsageError.commandFailed(failure)
    }
  }

  public func detailedSessions(since: String? = nil, until: String? = nil, timezone: String? = nil) async throws -> [CCUsageSessionMetricRecord] {
    let result = try await run(filteredArguments(command: "session", since: since, until: until, timezone: timezone))
    return try CCUsageDecoder.detailedSessions(from: result.stdout).map { row in
      CCUsageSessionMetricRecord(
        timestamp: row.timestamp,
        agent: row.agent,
        model: row.model,
        costUSD: row.costUSD,
        inputTokens: row.inputTokens,
        outputTokens: row.outputTokens,
        cacheCreationTokens: row.cacheCreationTokens,
        cacheReadTokens: row.cacheReadTokens,
        dataQuality: row.dataQuality,
        machine: machine
      )
    }
  }

  public func detailedUsage(since: String? = nil, until: String? = nil, timezone: String? = nil) async throws -> CCUsageDetailedUsage {
    do {
      let usage = try await detailedUsageLoader.load(runner: runner, since: since, until: until, timezone: timezone)
      return CCUsageDetailedUsage(
        metrics: usage.metrics.map { row in
          CCUsageMetricRecord(
            date: row.date,
            agent: row.agent,
            model: row.model,
            costUSD: row.costUSD,
            inputTokens: row.inputTokens,
            outputTokens: row.outputTokens,
            cacheCreationTokens: row.cacheCreationTokens,
            cacheReadTokens: row.cacheReadTokens,
            machine: machine
          )
        },
        sessions: usage.sessions.map { row in
          CCUsageSessionMetricRecord(
            timestamp: row.timestamp,
            agent: row.agent,
            model: row.model,
            costUSD: row.costUSD,
            inputTokens: row.inputTokens,
            outputTokens: row.outputTokens,
            cacheCreationTokens: row.cacheCreationTokens,
            cacheReadTokens: row.cacheReadTokens,
            dataQuality: row.dataQuality,
            machine: machine
          )
        }
      )
    } catch let failure as CCUsageCommandFailure {
      throw CCUsageError.commandFailed(failure)
    }
  }

  private func filteredArguments(command: String, since: String?, until: String?, timezone: String? = nil) -> [String] {
    var arguments = [command, "--json"]
    if let since { arguments += ["--since", since] }
    if let until { arguments += ["--until", until] }
    if let timezone { arguments += ["--timezone", timezone] }
    return arguments
  }

  private func run(_ arguments: [String]) async throws -> ProcessResult {
    do {
      return try await runner.run(arguments: arguments, timeoutSeconds: 30)
    } catch let failure as CCUsageCommandFailure {
      throw CCUsageError.commandFailed(failure)
    }
  }
}

public enum CCUsageError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidConfiguredPath
  case executableMissing(String)
  case commandFailed(CCUsageCommandFailure)
  case invalidJSON

  public var description: String {
    switch self {
    case .invalidConfiguredPath: "Configured ccusagePath must be absolute."
    case .executableMissing(let path): "ccusage executable is unavailable at \(path). Install ccusage or correct ccusagePath."
    case .commandFailed(let failure): "ccusage command failed during \(failure.phase.rawValue)."
    case .invalidJSON: "ccusage returned unsupported JSON."
    }
  }
}
