import Foundation

struct CodexScanContext: Sendable {
  var sessionID: String
  var model: String
  var directory: String?
}

private struct ResolvedTokenCount {
  let envelope: CodexEnvelope
  let timestamp: Date
  let model: String
}

private struct CodexDecoders {
  let day: DateFormatter
  let fractional: ISO8601DateFormatter
  let wholeSeconds: ISO8601DateFormatter

  init(calendar: Calendar) {
    day = UsageEventLogReader.dayFormatter(calendar: calendar)
    fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    wholeSeconds = ISO8601DateFormatter()
  }

  func timestamp(_ text: String) -> Date? {
    fractional.date(from: text) ?? wholeSeconds.date(from: text)
  }

  func decode(_ line: Data) -> (envelope: CodexEnvelope, timestamp: Date)? {
    guard let envelope = try? JSONDecoder().decode(CodexEnvelope.self, from: line),
          let timestamp = timestamp(envelope.timestamp) else { return nil }
    return (envelope, timestamp)
  }
}

/// Per-line state machine for reading a rollout in file order: `session_meta` names the
/// session and its working directory, `turn_context` sets the model for the token counts that
/// follow. Shared by the whole-file forward scan and the incremental resume of a grown file,
/// which continues from the context the previous scan ended with.
private struct CodexForwardParser {
  var context: CodexScanContext
  private let decoders: CodexDecoders

  init(context: CodexScanContext, decoders: CodexDecoders) {
    self.context = context
    self.decoders = decoders
  }

  mutating func consume(_ line: Data) -> (day: String, event: TimestampedUsageEvent)? {
    guard let (envelope, timestamp) = decoders.decode(line) else { return nil }
    if envelope.type == "session_meta" {
      if let id = envelope.payload.id, !id.isEmpty { context.sessionID = id }
      context.directory = CodexUsageEventLoader.normalizedDirectory(envelope.payload.cwd)
      return nil
    }
    if envelope.type == "turn_context", let model = envelope.payload.model, !model.isEmpty {
      context.model = model
      return nil
    }
    guard envelope.type == "event_msg", envelope.payload.type == "token_count", !context.model.isEmpty,
          let event = CodexUsageEventLoader.event(
            envelope,
            timestamp: timestamp,
            sessionID: context.sessionID,
            model: context.model,
            directory: context.directory
          ) else { return nil }
    return (decoders.day.string(from: timestamp), event)
  }
}

public struct CodexUsageEventLoader: Sendable {
  private typealias Scan = UsageEventFileScan<CodexScanContext>
  private static let relevantTypes = [
    Data(#""type":"session_meta""#.utf8),
    Data(#""type":"turn_context""#.utf8),
    Data(#""type":"token_count""#.utf8)
  ]
  private let rootProvider: @Sendable () -> [URL]
  private let scanCache = UsageEventFileScanCache<CodexScanContext>()
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
  ) -> CodexUsageEventLoader {
    CodexUsageEventLoader {
      (MachineSessionSourceAttempt.plan ?? MachineSessionSourcePlan(
        descriptor: descriptor,
        environment: environment
      )).eventRoots(for: .codex)
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
  func cachedScans() async -> [URL: UsageEventFileScan<CodexScanContext>] {
    await scanCache.snapshot()
  }

  /// Unbounded forward scan used when no `since` is given; results are not cached.
  private static func loadAllEvents(
    roots: [URL],
    until: String?,
    calendar: Calendar
  ) throws -> [TimestampedUsageEvent] {
    let decoders = CodexDecoders(calendar: calendar)
    var eventsByIdentity: [String: TimestampedUsageEvent] = [:]
    for file in UsageEventLogReader.jsonlFiles(roots: roots, modifiedSince: nil) {
      var parser = CodexForwardParser(context: initialContext(for: file), decoders: decoders)
      try UsageEventLogReader.forEachLine(in: file.url, matchingAny: relevantTypes) { line in
        guard let (day, event) = parser.consume(line), until.map({ day <= $0 }) ?? true else { return }
        eventsByIdentity[event.identity] = event
      }
    }
    return sorted(eventsByIdentity)
  }

  private static func scan(
    roots: [URL],
    since: String,
    until: String?,
    calendar: Calendar,
    cached: [URL: Scan]
  ) throws -> UsageEventScanOutcome<CodexScanContext> {
    let decoders = CodexDecoders(calendar: calendar)
    let minimumModificationDate = decoders.day.date(from: since)
    let scanFloor = minimumModificationDate
      .flatMap { calendar.date(byAdding: .day, value: -1, to: $0) }
      .map(decoders.day.string(from:))
    let timeZoneIdentifier = calendar.timeZone.identifier
    var entries: [URL: Scan] = [:]
    var eventsByIdentity: [String: TimestampedUsageEvent] = [:]
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
        if eventsByIdentity[cached.event.identity] == nil { eventsByIdentity[cached.event.identity] = cached.event }
      }
    }
    return UsageEventScanOutcome(
      events: sorted(eventsByIdentity),
      entries: entries,
      listingFloor: minimumModificationDate
    )
  }

  /// Reverse scan from the end of the file. Token counts are held until the `turn_context`
  /// that precedes them names their model, and the scan keeps going past the requested day
  /// only as far as needed to learn the model in effect at the end of the file, so a resume
  /// can attribute token counts appended to the same turn.
  private static func rescan(
    file: UsageEventLogFile,
    since: String,
    scanFloor: String?,
    timeZoneIdentifier: String,
    decoders: CodexDecoders
  ) throws -> Scan {
    let region = try UsageEventLogReader.region(of: file.url)
    var context = initialContext(for: file)
    applySessionMetadata(from: file.url, region: region, decoders: decoders, to: &context)
    var events: [String: CachedUsageEvent] = [:]
    var pending: [(envelope: CodexEnvelope, timestamp: Date)] = []
    var resolved: [ResolvedTokenCount] = []
    var contextModel: String?
    var stopRequested = false
    func flush() {
      for item in resolved {
        guard let event = event(
          item.envelope,
          timestamp: item.timestamp,
          sessionID: context.sessionID,
          model: item.model,
          directory: context.directory
        ), events[event.identity] == nil else { continue }
        events[event.identity] = CachedUsageEvent(day: decoders.day.string(from: item.timestamp), event: event)
      }
      resolved.removeAll(keepingCapacity: true)
    }
    try UsageEventLogReader.forEachLineFromEnd(in: file.url, endingAt: region.size, matchingAny: relevantTypes) { line in
      if !stopRequested, let rawDay = UsageEventLogReader.timestampDay(in: line), let scanFloor,
         rawDay < scanFloor, pending.isEmpty, resolved.isEmpty {
        stopRequested = true
      }
      if stopRequested, contextModel != nil { return false }
      guard let (envelope, timestamp) = decoders.decode(line) else { return true }
      let day = decoders.day.string(from: timestamp)
      if envelope.type == "event_msg", envelope.payload.type == "token_count" {
        guard !stopRequested else { return true }
        if day < since {
          guard pending.isEmpty else { return true }
          stopRequested = true
          return contextModel == nil
        }
        pending.append((envelope, timestamp))
        return true
      }
      if envelope.type == "turn_context", let model = envelope.payload.model, !model.isEmpty {
        if contextModel == nil { contextModel = model }
        resolved.append(contentsOf: pending.map { ResolvedTokenCount(envelope: $0.envelope, timestamp: $0.timestamp, model: model) })
        pending.removeAll(keepingCapacity: true)
        if day < since, resolved.isEmpty { stopRequested = true }
        return !stopRequested
      }
      if envelope.type == "session_meta" {
        if let id = envelope.payload.id, !id.isEmpty { context.sessionID = id }
        context.directory = normalizedDirectory(envelope.payload.cwd)
        flush()
        if day < since, pending.isEmpty { stopRequested = true }
        return !stopRequested || contextModel == nil
      }
      return true
    }
    flush()
    context.model = contextModel ?? ""
    return Scan.make(
      file: file,
      region: region,
      since: since,
      timeZoneIdentifier: timeZoneIdentifier,
      events: events,
      context: context
    )
  }

  /// Forward parse of only the bytes appended since `entry` was taken. Returns nil when the
  /// file shrank in the meantime, in which case the caller rescans it.
  private static func resume(_ entry: Scan, file: UsageEventLogFile, decoders: CodexDecoders) throws -> Scan? {
    let region = try UsageEventLogReader.region(of: file.url)
    guard let start = entry.scannedThrough, region.size >= start else { return nil }
    var updated = entry
    var parser = CodexForwardParser(context: entry.context, decoders: decoders)
    try UsageEventLogReader.forEachLine(in: file.url, from: start, to: region.size, matchingAny: relevantTypes) { line in
      guard let (day, event) = parser.consume(line), day >= entry.since else { return }
      updated.events[event.identity] = CachedUsageEvent(day: day, event: event)
    }
    updated.context = parser.context
    updated.advance(file: file, region: region)
    return updated
  }

  private static func initialContext(for file: UsageEventLogFile) -> CodexScanContext {
    CodexScanContext(sessionID: file.url.deletingPathExtension().lastPathComponent, model: "", directory: nil)
  }

  /// A rollout opens with its `session_meta` line. Reading it directly keeps the session id
  /// and working directory identical however far back the reverse scan happens to reach.
  private static func applySessionMetadata(
    from url: URL,
    region: UsageEventLogRegion,
    decoders: CodexDecoders,
    to context: inout CodexScanContext
  ) {
    let probe = Int(min(region.size, UInt64(UsageEventLogReader.defaultReverseChunkSize)))
    guard probe > 0, let head = try? UsageEventLogReader.bytes(in: url, from: 0, count: probe) else { return }
    let line = head.firstIndex(of: 0x0A).map { head[head.startIndex..<$0] } ?? head[...]
    guard let (envelope, _) = decoders.decode(Data(line)), envelope.type == "session_meta" else { return }
    if let id = envelope.payload.id, !id.isEmpty { context.sessionID = id }
    context.directory = normalizedDirectory(envelope.payload.cwd)
  }

  fileprivate static func event(
    _ envelope: CodexEnvelope,
    timestamp: Date,
    sessionID: String,
    model: String,
    directory: String?
  ) -> TimestampedUsageEvent? {
    guard let info = envelope.payload.info,
          let last = info.lastTokenUsage,
          let total = info.totalTokenUsage else { return nil }
    let watermark = [
      total.inputTokens,
      total.cachedInputTokens,
      total.outputTokens,
      total.reasoningOutputTokens,
      total.totalTokens
    ].map(String.init).joined(separator: ":")
    return TimestampedUsageEvent(
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
      cacheCreationOneHourTokens: 0,
      directory: directory
    )
  }

  private static func sorted(_ eventsByIdentity: [String: TimestampedUsageEvent]) -> [TimestampedUsageEvent] {
    eventsByIdentity.values.sorted {
      ($0.timestamp, $0.identity) < ($1.timestamp, $1.identity)
    }
  }

  fileprivate static func normalizedDirectory(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
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
  let cwd: String?
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
