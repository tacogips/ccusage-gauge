import Foundation

public struct CodexUsageEventLoader: Sendable {
  public let roots: [URL]

  public init(roots: [URL]) { self.roots = roots }

  public static func production(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> CodexUsageEventLoader {
    let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
    let codexRoot = environment["CODEX_HOME"].map {
      URL(fileURLWithPath: $0, isDirectory: true)
    } ?? home.appendingPathComponent(".codex", isDirectory: true)
    return CodexUsageEventLoader(roots: [codexRoot.appendingPathComponent("sessions", isDirectory: true)])
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

  private static func loadEvents(
    roots: [URL],
    since: String?,
    until: String?,
    calendar: Calendar
  ) throws -> [TimestampedUsageEvent] {
    let formatter = dayFormatter(calendar: calendar)
    let minimumModificationDate = since.flatMap(formatter.date(from:))
    var eventsByIdentity: [String: TimestampedUsageEvent] = [:]
    for file in UsageEventLogReader.jsonlFiles(roots: roots, modifiedSince: minimumModificationDate) {
      var sessionID = file.deletingPathExtension().lastPathComponent
      var model = ""
      let relevantTypes = [
        Data(#""type":"session_meta""#.utf8),
        Data(#""type":"turn_context""#.utf8),
        Data(#""type":"token_count""#.utf8)
      ]
      try UsageEventLogReader.forEachLine(in: file, matchingAny: relevantTypes) { line in
        guard let envelope = try? JSONDecoder().decode(CodexEnvelope.self, from: line) else { return }
        if envelope.type == "session_meta", let id = envelope.payload.id { sessionID = id }
        if envelope.type == "turn_context", let nextModel = envelope.payload.model, !nextModel.isEmpty {
          model = nextModel
          return
        }
        guard envelope.type == "event_msg", envelope.payload.type == "token_count",
              !model.isEmpty,
              let timestamp = parseTimestamp(envelope.timestamp),
              let info = envelope.payload.info,
              let last = info.lastTokenUsage,
              let total = info.totalTokenUsage else { return }
        let day = formatter.string(from: timestamp)
        guard since.map({ day >= $0 }) ?? true,
              until.map({ day <= $0 }) ?? true else { return }
        let watermark = [
          total.inputTokens,
          total.cachedInputTokens,
          total.outputTokens,
          total.reasoningOutputTokens,
          total.totalTokens
        ].map(String.init).joined(separator: ":")
        let event = TimestampedUsageEvent(
          timestamp: timestamp,
          agent: "codex",
          sessionID: sessionID,
          requestID: watermark,
          messageID: "",
          model: model,
          inputTokens: max(0, last.inputTokens - last.cachedInputTokens),
          outputTokens: last.outputTokens,
          cacheCreationTokens: 0,
          cacheReadTokens: last.cachedInputTokens,
          cacheCreationFiveMinuteTokens: 0,
          cacheCreationOneHourTokens: 0
        )
        eventsByIdentity[event.identity] = event
      }
    }
    return eventsByIdentity.values.sorted {
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

private struct CodexEnvelope: Decodable {
  let timestamp: String
  let type: String
  let payload: CodexPayload
}

private struct CodexPayload: Decodable {
  let type: String?
  let id: String?
  let model: String?
  let info: CodexTokenInfo?
}

private struct CodexTokenInfo: Decodable {
  let totalTokenUsage: CodexTokenUsage?
  let lastTokenUsage: CodexTokenUsage?

  enum CodingKeys: String, CodingKey {
    case totalTokenUsage = "total_token_usage"
    case lastTokenUsage = "last_token_usage"
  }
}

private struct CodexTokenUsage: Decodable {
  let inputTokens: Int
  let cachedInputTokens: Int
  let outputTokens: Int
  let reasoningOutputTokens: Int
  let totalTokens: Int

  enum CodingKeys: String, CodingKey {
    case inputTokens = "input_tokens"
    case cachedInputTokens = "cached_input_tokens"
    case outputTokens = "output_tokens"
    case reasoningOutputTokens = "reasoning_output_tokens"
    case totalTokens = "total_tokens"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
    cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    reasoningOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
    totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
  }
}
