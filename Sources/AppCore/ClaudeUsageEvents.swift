import Foundation

public struct TimestampedUsageEvent: Equatable, Sendable {
  public let timestamp: Date
  public let agent: String
  public let sessionID: String
  public let requestID: String
  public let messageID: String
  public let model: String
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheCreationTokens: Int
  public let cacheReadTokens: Int
  public let cacheCreationFiveMinuteTokens: Int
  public let cacheCreationOneHourTokens: Int

  var identity: String { "\(sessionID)\u{1f}\(requestID)\u{1f}\(messageID)" }

  var relativeCostWeight: Decimal {
    if agent == "codex" {
      return Decimal(inputTokens) + Decimal(outputTokens) * 8 + Decimal(cacheReadTokens) / 10
    }
    let unclassifiedCreation = max(
      0,
      cacheCreationTokens - cacheCreationFiveMinuteTokens - cacheCreationOneHourTokens
    )
    return Decimal(inputTokens)
      + Decimal(outputTokens) * 5
      + Decimal(cacheReadTokens) / 10
      + Decimal(cacheCreationFiveMinuteTokens + unclassifiedCreation) * 5 / 4
      + Decimal(cacheCreationOneHourTokens) * 2
  }
}

actor TimestampedUsageEventLoadCoordinator {
  private var tasks: [String: Task<[TimestampedUsageEvent], Error>] = [:]

  func events(
    claudeLoader: ClaudeUsageEventLoader?,
    codexLoader: CodexUsageEventLoader?,
    since: String?,
    until: String?,
    calendar: Calendar
  ) async throws -> [TimestampedUsageEvent] {
    let key = "\(since ?? "")\u{1f}\(until ?? "")\u{1f}\(calendar.timeZone.identifier)"
    if let task = tasks[key] { return try await task.value }
    let task = Task {
      async let claudeEvents = claudeLoader?.events(since: since, until: until, calendar: calendar) ?? []
      async let codexEvents = codexLoader?.events(since: since, until: until, calendar: calendar) ?? []
      return (try await claudeEvents) + (try await codexEvents)
    }
    tasks[key] = task
    do {
      let result = try await task.value
      tasks[key] = nil
      return result
    } catch {
      tasks[key] = nil
      throw error
    }
  }
}

public struct ClaudeUsageEventLoader: Sendable {
  public let roots: [URL]

  public init(roots: [URL]) { self.roots = roots }

  public static func production(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ClaudeUsageEventLoader {
    let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
    let claudeRoot = environment["CLAUDE_CONFIG_DIR"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    } ?? home.appendingPathComponent(".claude", isDirectory: true)
    return ClaudeUsageEventLoader(roots: [claudeRoot.appendingPathComponent("projects", isDirectory: true)])
  }

  public func events(
    since: String?,
    until: String?,
    calendar: Calendar
  ) async throws -> [TimestampedUsageEvent] {
    let roots = roots
    return try await Task.detached(priority: .utility) {
      try Self.loadEvents(roots: roots, since: since, until: until, calendar: calendar)
    }.value
  }

  static func decode(line: Data) -> TimestampedUsageEvent? {
    guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: line),
          envelope.type == "assistant",
          envelope.message.role == "assistant",
          let timestamp = parseTimestamp(envelope.timestamp),
          !envelope.message.model.isEmpty else { return nil }
    let usage = envelope.message.usage
    return TimestampedUsageEvent(
      timestamp: timestamp,
      agent: "claude",
      sessionID: envelope.sessionID ?? "",
      requestID: envelope.requestID ?? envelope.message.id,
      messageID: envelope.message.id,
      model: envelope.message.model,
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      cacheCreationTokens: usage.cacheCreationInputTokens,
      cacheReadTokens: usage.cacheReadInputTokens,
      cacheCreationFiveMinuteTokens: usage.cacheCreation?.fiveMinuteInputTokens ?? 0,
      cacheCreationOneHourTokens: usage.cacheCreation?.oneHourInputTokens ?? 0
    )
  }

  private static func loadEvents(
    roots: [URL],
    since: String?,
    until: String?,
    calendar: Calendar
  ) throws -> [TimestampedUsageEvent] {
    let formatter = dayFormatter(calendar: calendar)
    let minimumModificationDate = since.flatMap(formatter.date(from:))
    var latestByIdentity: [String: TimestampedUsageEvent] = [:]
    for file in UsageEventLogReader.jsonlFiles(roots: roots, modifiedSince: minimumModificationDate) {
      try UsageEventLogReader.forEachLine(in: file) { line in
        guard let event = decode(line: line) else { return }
        let day = formatter.string(from: event.timestamp)
        guard since.map({ day >= $0 }) ?? true,
              until.map({ day <= $0 }) ?? true else { return }
        if let existing = latestByIdentity[event.identity], existing.timestamp > event.timestamp { return }
        latestByIdentity[event.identity] = event
      }
    }
    return latestByIdentity.values.sorted {
      ($0.timestamp, $0.identity) < ($1.timestamp, $1.identity)
    }
  }

  private static func dayFormatter(calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  private static func parseTimestamp(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
  }
}

enum UsageEventLogReader {
  static func jsonlFiles(roots: [URL], modifiedSince: Date?) -> [URL] {
    let manager = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
    return roots.flatMap { root -> [URL] in
      guard let enumerator = manager.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: [.skipsPackageDescendants, .skipsHiddenFiles]
      ) else { return [] }
      return enumerator.compactMap { item in
        guard let url = item as? URL, url.pathExtension == "jsonl",
              let values = try? url.resourceValues(forKeys: Set(keys)),
              values.isRegularFile == true else { return nil }
        if let modifiedSince, let modified = values.contentModificationDate, modified < modifiedSince { return nil }
        return url
      }
    }.sorted { $0.path < $1.path }
  }

  static func forEachLine(
    in url: URL,
    matchingAny needles: [Data] = [],
    body: (Data) -> Void
  ) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var pending = Data()
    while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
      pending.append(chunk)
      while let newline = pending.firstIndex(of: 0x0A) {
        let lineRange = pending.startIndex..<newline
        if newline > pending.startIndex,
           needles.isEmpty || needles.contains(where: { pending.range(of: $0, in: lineRange) != nil }) {
          body(Data(pending[lineRange]))
        }
        pending.removeSubrange(...newline)
      }
    }
    if !pending.isEmpty { body(pending) }
  }

}

private struct EventEnvelope: Decodable {
  let type: String
  let timestamp: String
  let sessionID: String?
  let requestID: String?
  let message: EventMessage

  enum CodingKeys: String, CodingKey {
    case type, timestamp, message
    case sessionID = "sessionId"
    case requestID = "requestId"
  }
}

private struct EventMessage: Decodable {
  let id: String
  let role: String
  let model: String
  let usage: EventUsage
}

private struct EventUsage: Decodable {
  let inputTokens: Int
  let outputTokens: Int
  let cacheCreationInputTokens: Int
  let cacheReadInputTokens: Int
  let cacheCreation: CacheCreationUsage?

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case outputTokens = "output_tokens"
    case cacheCreationInputTokens = "cache_creation_input_tokens"
    case cacheReadInputTokens = "cache_read_input_tokens"
    case cacheCreation = "cache_creation"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    cacheCreationInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens) ?? 0
    cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens) ?? 0
    cacheCreation = try container.decodeIfPresent(CacheCreationUsage.self, forKey: .cacheCreation)
  }
}

private struct CacheCreationUsage: Decodable {
  let fiveMinuteInputTokens: Int
  let oneHourInputTokens: Int

  enum CodingKeys: String, CodingKey {
    case fiveMinuteInputTokens = "ephemeral_5m_input_tokens"
    case oneHourInputTokens = "ephemeral_1h_input_tokens"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fiveMinuteInputTokens = try container.decodeIfPresent(Int.self, forKey: .fiveMinuteInputTokens) ?? 0
    oneHourInputTokens = try container.decodeIfPresent(Int.self, forKey: .oneHourInputTokens) ?? 0
  }
}
