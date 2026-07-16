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
    let startTime: Date
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
  private struct DetailedSession: Decodable {
    let agent: String
    let metadata: SessionMetadata
    let modelBreakdowns: [DetailedBreakdown]
  }
  private struct SessionMetadata: Decodable { let lastActivity: String }

  public static func blocks(from data: Data) throws -> [CCUsageCostRecord] {
    do {
      return try decoder.decode(BlocksEnvelope.self, from: data).blocks.map {
        CCUsageCostRecord(timestamp: $0.startTime, costUSD: $0.costUSD, models: $0.models)
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

public struct CCUsageClient: Sendable {
  public let executable: URL
  public let runner: CCUsageProcessRunner

  public init(executable: URL, runner: CCUsageProcessRunner = CCUsageProcessRunner()) {
    self.executable = executable
    self.runner = runner
  }

  public func blocks() async throws -> [CCUsageCostRecord] {
    let result = try await runner.run(executable: executable, arguments: ["blocks", "--json"])
    return try CCUsageDecoder.blocks(from: result.stdout)
  }

  public func daily() async throws -> [CCUsageDailyRecord] {
    let result = try await runner.run(executable: executable, arguments: ["daily", "--json"])
    return try CCUsageDecoder.daily(from: result.stdout)
  }

  public func detailedDaily(since: String? = nil, until: String? = nil) async throws -> [CCUsageMetricRecord] {
    let result = try await runner.run(
      executable: executable,
      arguments: filteredArguments(command: "daily", since: since, until: until)
    )
    return try CCUsageDecoder.detailedDaily(from: result.stdout)
  }

  public func detailedSessions(since: String? = nil, until: String? = nil) async throws -> [CCUsageSessionMetricRecord] {
    let result = try await runner.run(
      executable: executable,
      arguments: filteredArguments(command: "session", since: since, until: until)
    )
    return try CCUsageDecoder.detailedSessions(from: result.stdout)
  }

  private func filteredArguments(command: String, since: String?, until: String?) -> [String] {
    var arguments = [command, "--json", "--by-agent"]
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
