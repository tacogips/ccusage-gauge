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
  public let directory: String?

  public init(
    timestamp: Date,
    agent: String,
    sessionID: String,
    requestID: String,
    messageID: String,
    model: String,
    inputTokens: Int,
    outputTokens: Int,
    cacheCreationTokens: Int,
    cacheReadTokens: Int,
    cacheCreationFiveMinuteTokens: Int,
    cacheCreationOneHourTokens: Int,
    directory: String? = nil
  ) {
    self.timestamp = timestamp
    self.agent = agent
    self.sessionID = sessionID
    self.requestID = requestID
    self.messageID = messageID
    self.model = model
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheCreationTokens = cacheCreationTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheCreationFiveMinuteTokens = cacheCreationFiveMinuteTokens
    self.cacheCreationOneHourTokens = cacheCreationOneHourTokens
    self.directory = Self.normalizedDirectory(directory)
  }

  private static func normalizedDirectory(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
  }

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

struct ClaudeScanContext: Sendable {}

public struct ClaudeUsageEventLoader: Sendable {
  private typealias Scan = UsageEventFileScan<ClaudeScanContext>
  private static let assistantNeedle = Data(#""type":"assistant""#.utf8)
  private let rootProvider: @Sendable () -> [URL]
  private let scanCache = UsageEventFileScanCache<ClaudeScanContext>()
  private let cachePolicy: UsageEventScanCachePolicy
  private let now: @Sendable () -> Date
  public var roots: [URL] { rootProvider() }

  public init(roots: [URL]) {
    self.init(rootProvider: { roots })
  }

  public init(rootProvider: @escaping @Sendable () -> [URL]) {
    self.init(rootProvider: rootProvider, cachePolicy: UsageEventScanCachePolicy(), now: Date.init)
  }

  init(
    rootProvider: @escaping @Sendable () -> [URL],
    cachePolicy: UsageEventScanCachePolicy,
    now: @escaping @Sendable () -> Date
  ) {
    self.rootProvider = rootProvider
    self.cachePolicy = cachePolicy
    self.now = now
  }

  public static func production(
    descriptor: MachineDescriptor = .local,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ClaudeUsageEventLoader {
    ClaudeUsageEventLoader {
      (MachineSessionSourceAttempt.plan ?? MachineSessionSourcePlan(
        descriptor: descriptor,
        environment: environment
      )).eventRoots(for: .claude)
    }
  }

  public func events(
    since: String?,
    until: String?,
    calendar: Calendar
  ) async throws -> [TimestampedUsageEvent] {
    let roots = rootProvider()
    guard let since else {
      return try await Task.detached(priority: .utility) {
        try Self.loadAllEvents(roots: roots, until: until, calendar: calendar)
      }.value
    }
    let current = now()
    let cacheable = cachePolicy.isCacheable(since: since, calendar: calendar, now: current)
    let cached = cacheable ? await scanCache.snapshot() : [:]
    let outcome = try await Task.detached(priority: .utility) {
      try Self.scan(roots: roots, since: since, until: until, calendar: calendar, cached: cached)
    }.value
    if cacheable {
      await scanCache.merge(outcome, retentionFloor: cachePolicy.retentionFloor(calendar: calendar, now: current))
    }
    return outcome.events
  }

  /// Test-only view of the retained per-file scans.
  func cachedScans() async -> [URL: UsageEventFileScan<ClaudeScanContext>] {
    await scanCache.snapshot()
  }

  static func decode(line: Data) -> TimestampedUsageEvent? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return decode(line: line, fractional: fractional, wholeSeconds: ISO8601DateFormatter())
  }

  private static func decode(
    line: Data,
    fractional: ISO8601DateFormatter,
    wholeSeconds: ISO8601DateFormatter
  ) -> TimestampedUsageEvent? {
    guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: line),
          envelope.type == "assistant",
          envelope.message.role == "assistant",
          let timestamp = fractional.date(from: envelope.timestamp) ?? wholeSeconds.date(from: envelope.timestamp),
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
      cacheCreationOneHourTokens: usage.cacheCreation?.oneHourInputTokens ?? 0,
      directory: envelope.cwd
    )
  }

  private struct Decoders {
    let day: DateFormatter
    let fractional: ISO8601DateFormatter
    let wholeSeconds: ISO8601DateFormatter

    init(calendar: Calendar) {
      day = UsageEventLogReader.dayFormatter(calendar: calendar)
      fractional = ISO8601DateFormatter()
      fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      wholeSeconds = ISO8601DateFormatter()
    }

    func event(from line: Data) -> (day: String, event: TimestampedUsageEvent)? {
      guard let event = decode(line: line, fractional: fractional, wholeSeconds: wholeSeconds) else { return nil }
      return (day.string(from: event.timestamp), event)
    }
  }

  /// Unbounded forward scan used when no `since` is given; results are not cached.
  private static func loadAllEvents(
    roots: [URL],
    until: String?,
    calendar: Calendar
  ) throws -> [TimestampedUsageEvent] {
    let decoders = Decoders(calendar: calendar)
    var latestByIdentity: [String: TimestampedUsageEvent] = [:]
    for file in UsageEventLogReader.jsonlFiles(roots: roots, modifiedSince: nil) {
      try UsageEventLogReader.forEachLine(in: file.url, matchingAny: [assistantNeedle]) { line in
        guard let (day, event) = decoders.event(from: line),
              until.map({ day <= $0 }) ?? true else { return }
        if let existing = latestByIdentity[event.identity], existing.timestamp > event.timestamp { return }
        latestByIdentity[event.identity] = event
      }
    }
    return sorted(latestByIdentity)
  }

  private static func scan(
    roots: [URL],
    since: String,
    until: String?,
    calendar: Calendar,
    cached: [URL: Scan]
  ) throws -> UsageEventScanOutcome<ClaudeScanContext> {
    let decoders = Decoders(calendar: calendar)
    let minimumModificationDate = decoders.day.date(from: since)
    let scanFloor = minimumModificationDate
      .flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }
      .map(decoders.day.string(from:))
    let timeZoneIdentifier = calendar.timeZone.identifier
    var entries: [URL: Scan] = [:]
    var latestByIdentity: [String: TimestampedUsageEvent] = [:]
    for file in UsageEventLogReader.jsonlFiles(roots: roots, modifiedSince: minimumModificationDate) {
      let entry: Scan
      switch UsageEventFileScanPlanner.step(
        for: file,
        entry: cached[file.url],
        since: since,
        timeZoneIdentifier: timeZoneIdentifier
      ) {
      case .reuse(let existing):
        entry = existing
      case .resume(let existing):
        entry = try resume(existing, file: file, decoders: decoders)
          ?? rescan(file: file, since: since, scanFloor: scanFloor, timeZoneIdentifier: timeZoneIdentifier, decoders: decoders)
      case .rescan:
        entry = try rescan(file: file, since: since, scanFloor: scanFloor, timeZoneIdentifier: timeZoneIdentifier, decoders: decoders)
      }
      entries[file.url] = entry
      for cached in entry.events.values where cached.day >= since && (until.map { cached.day <= $0 } ?? true) {
        // Keep the highest-timestamp record for a given identity, matching the dedup of the
        // unbounded forward scan, so daily totals do not depend on whether `since` was supplied.
        if let existing = latestByIdentity[cached.event.identity], existing.timestamp >= cached.event.timestamp { continue }
        latestByIdentity[cached.event.identity] = cached.event
      }
    }
    return UsageEventScanOutcome(
      events: sorted(latestByIdentity),
      entries: entries,
      listingFloor: minimumModificationDate
    )
  }

  /// Reverse scan from the end of the file down to the first event dated before `since`.
  private static func rescan(
    file: UsageEventLogFile,
    since: String,
    scanFloor: String?,
    timeZoneIdentifier: String,
    decoders: Decoders
  ) throws -> Scan {
    let region = try UsageEventLogReader.region(of: file.url)
    var events: [String: CachedUsageEvent] = [:]
    try UsageEventLogReader.forEachLineFromEnd(in: file.url, endingAt: region.size, matchingAny: [assistantNeedle]) { line in
      if let rawDay = UsageEventLogReader.timestampDay(in: line), let scanFloor, rawDay < scanFloor { return false }
      guard let (day, event) = decoders.event(from: line) else { return true }
      if day < since { return false }
      if let existing = events[event.identity], existing.event.timestamp >= event.timestamp { return true }
      events[event.identity] = CachedUsageEvent(day: day, event: event)
      return true
    }
    return Scan.make(
      file: file,
      region: region,
      since: since,
      timeZoneIdentifier: timeZoneIdentifier,
      events: events,
      context: ClaudeScanContext()
    )
  }

  /// Forward parse of only the bytes appended since `entry` was taken. Returns nil when the
  /// file shrank in the meantime, in which case the caller rescans it.
  private static func resume(_ entry: Scan, file: UsageEventLogFile, decoders: Decoders) throws -> Scan? {
    let region = try UsageEventLogReader.region(of: file.url)
    guard let start = entry.scannedThrough, region.size >= start else { return nil }
    var updated = entry
    try UsageEventLogReader.forEachLine(in: file.url, from: start, to: region.size, matchingAny: [assistantNeedle]) { line in
      guard let (day, event) = decoders.event(from: line), day >= entry.since else { return }
      if let existing = updated.events[event.identity], existing.event.timestamp > event.timestamp { return }
      updated.events[event.identity] = CachedUsageEvent(day: day, event: event)
    }
    updated.advance(file: file, region: region)
    return updated
  }

  private static func sorted(_ eventsByIdentity: [String: TimestampedUsageEvent]) -> [TimestampedUsageEvent] {
    eventsByIdentity.values.sorted {
      ($0.timestamp, $0.identity) < ($1.timestamp, $1.identity)
    }
  }
}

private struct EventEnvelope: Decodable {
  let type: String
  let timestamp: String
  let sessionID: String?
  let requestID: String?
  let cwd: String?
  let message: EventMessage

  enum CodingKeys: String, CodingKey {
    case type, timestamp, cwd, message
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
