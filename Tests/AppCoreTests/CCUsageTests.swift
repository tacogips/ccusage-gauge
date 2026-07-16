import Foundation
import Testing
@testable import AppCore

private actor RangeConcurrencyTracker {
  private(set) var active = 0
  private(set) var maximumActive = 0
  private(set) var progress: [(Int, Int)] = []

  func start() {
    active += 1
    maximumActive = max(maximumActive, active)
  }

  func finish() { active -= 1 }

  func record(completed: Int, total: Int) { progress.append((completed, total)) }
}

@Suite("RangeLoadConcurrencyTests") struct RangeLoadConcurrencyTests {
  @Test func limitsFiftyTwoWeeklyLoadsToTwentyConcurrentTasks() async throws {
    let tracker = RangeConcurrencyTracker()
    let results = try await boundedConcurrentMap(
      Array(0..<52),
      limit: maximumConcurrentRangeLoads,
      progress: { completed, total in await tracker.record(completed: completed, total: total) },
      operation: { value in
        await tracker.start()
        try await Task.sleep(for: .milliseconds(10))
        await tracker.finish()
        return value
      }
    )

    #expect(results.count == 52)
    #expect(await tracker.maximumActive == 20)
    let progress = await tracker.progress
    #expect(progress.count == 53)
    #expect(progress.first?.0 == 0)
    #expect(progress.first?.1 == 52)
    #expect(progress.last?.0 == 52)
    #expect(progress.last?.1 == 52)
  }
}

@Suite("CCUsageExecutableResolverTests") struct CCUsageExecutableResolverTests {
  @Test func explicitMissingPathNeverFallsBackToPath() throws {
    let root = try temporaryDirectory()
    let fake = root.appendingPathComponent("ccusage")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    #expect(throws: CCUsageError.executableMissing("/definitely/missing/ccusage")) {
      try CCUsageExecutableResolver().resolve(configuredPath: "/definitely/missing/ccusage", environment: ["PATH": root.path])
    }
  }

  @Test func searchesExplicitAdditionalDirectoriesForGUIApps() throws {
    let root = try temporaryDirectory()
    let fake = root.appendingPathComponent("ccusage")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
    let resolved = try CCUsageExecutableResolver().resolve(
      configuredPath: nil,
      environment: ["PATH": "/usr/bin:/bin"],
      additionalSearchDirectories: [root.path]
    )
    #expect(resolved == fake)
  }
}

@Suite("CCUsageDecoderTests") struct CCUsageDecoderTests {
  @Test func decodesObservedBlocksShapeAndIgnoresUnknownFields() throws {
    let data = Data(#"{"blocks":[{"startTime":"2026-07-15T01:00:00.123Z","costUSD":1.25,"models":["opus"],"future":true}]}"#.utf8)
    let records = try CCUsageDecoder.blocks(from: data)
    #expect(records.count == 1)
    #expect(records[0].costUSD == Decimal(string: "1.25"))
    let wholeSecond = ISO8601DateFormatter().date(from: "2026-07-15T01:00:00Z")!
    #expect(abs(records[0].timestamp.timeIntervalSince(wholeSecond) - 0.123) < 0.001)
  }

  @Test func sumsModelBreakdownsExactlyOnce() throws {
    let json = #"{"daily":[{"period":"2026-07-15","totalCost":99,"modelsUsed":["a","b"],"modelBreakdowns":[{"modelName":"a","cost":1.2},{"modelName":"b","cost":2.3}]}]}"#
    let data = Data(json.utf8)
    let records = try CCUsageDecoder.daily(from: data)
    #expect(records[0].costUSD == Decimal(string: "3.5"))
  }

  @Test func decodesDetailedMetricsByAgentAndModel() throws {
    let json = #"""
      {"daily":[{"period":"2026-07-16","agents":[
        {"agent":"codex","modelBreakdowns":[
          {"modelName":"gpt-5.6-sol","cost":2.5,"inputTokens":10,"outputTokens":3,"cacheCreationTokens":0,"cacheReadTokens":20}
        ]},
        {"agent":"claude","modelBreakdowns":[
          {"modelName":"claude-opus-4-8","cost":1.25,"inputTokens":4,"outputTokens":2,"cacheCreationTokens":5,"cacheReadTokens":8}
        ]}
      ]}]}
      """#
    let records = try CCUsageDecoder.detailedDaily(from: Data(json.utf8))
    #expect(records.count == 2)
    #expect(records[0].agent == "codex")
    #expect(records[0].model == "gpt-5.6-sol")
    #expect(records[0].inputTokens == 10)
    #expect(records[0].outputTokens == 3)
    #expect(records[0].cacheReadTokens == 20)
    #expect(records[0].totalTokens == 33)
    #expect(records[1].costUSD == Decimal(string: "1.25"))
  }

  @Test func decodesSessionCostAtLastActivity() throws {
    let json = #"""
      {"session":[{"agent":"codex","metadata":{"lastActivity":"2026-07-16T01:23:45.678Z"},"modelBreakdowns":[
        {"modelName":"gpt-5.6-sol","cost":2.5,"inputTokens":10,"outputTokens":3,"cacheCreationTokens":0,"cacheReadTokens":20}
      ]}]}
      """#
    let records = try CCUsageDecoder.detailedSessions(from: Data(json.utf8))
    #expect(records.count == 1)
    #expect(records[0].agent == "codex")
    #expect(records[0].model == "gpt-5.6-sol")
    #expect(records[0].inputTokens == 10)
    #expect(records[0].outputTokens == 3)
    #expect(records[0].cacheReadTokens == 20)
    #expect(records[0].totalTokens == 33)
    let wholeSecond = ISO8601DateFormatter().date(from: "2026-07-16T01:23:45Z")!
    #expect(abs(records[0].timestamp.timeIntervalSince(wholeSecond) - 0.678) < 0.001)
  }

  @Test func decodesCombinedDailyAndSessionSections() throws {
    let json = #"""
      {
        "daily":[{"period":"2026-07-16","agents":[{"agent":"codex","modelBreakdowns":[
          {"modelName":"gpt-test","cost":2.5,"inputTokens":10,"outputTokens":3,"cacheCreationTokens":0,"cacheReadTokens":20}
        ]}]}],
        "session":[{"agent":"codex","metadata":{"lastActivity":"2026-07-16T01:00:00Z"},"modelBreakdowns":[
          {"modelName":"gpt-test","cost":2.5,"inputTokens":10,"outputTokens":3,"cacheCreationTokens":0,"cacheReadTokens":20}
        ]}]
      }
      """#
    let usage = try CCUsageDecoder.detailedUsage(from: Data(json.utf8))
    #expect(usage.metrics.count == 1)
    #expect(usage.sessions.count == 1)
    #expect(usage.metrics[0].model == usage.sessions[0].model)
  }
}

@Suite("ClaudeUsageEventTests") struct ClaudeUsageEventTests {
  @Test func loadsFinalStreamingSnapshotAndRetainsExactUsageTimestamp() async throws {
    let root = try temporaryDirectory()
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let log = project.appendingPathComponent("session.jsonl")
    let rows = [
      claudeEvent(timestamp: "2026-07-16T01:00:00.000Z", request: "request-1", message: "message-1", input: 10),
      claudeEvent(timestamp: "2026-07-16T01:00:02.000Z", request: "request-1", message: "message-1", input: 20),
      claudeEvent(timestamp: "2026-07-16T01:15:00.000Z", request: "request-2", message: "message-2", input: 40)
    ]
    try Data(rows.joined(separator: "\n").utf8).write(to: log)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let events = try await ClaudeUsageEventLoader(roots: [root]).events(
      since: "2026-07-16",
      until: "2026-07-16",
      calendar: calendar
    )

    try #require(events.count == 2)
    #expect(events[0].inputTokens == 20)
    #expect(events[0].timestamp == ISO8601DateFormatter().date(from: "2026-07-16T01:00:02Z"))
    #expect(events[1].model == "claude-fable-5")
  }

  @Test func snapshotDistributesAuthoritativeClaudeDailyCostAcrossRawEvents() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let projects = root.appendingPathComponent("claude-projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let events = [
      claudeEvent(timestamp: "2026-07-16T01:00:00.000Z", request: "request-1", message: "message-1", input: 10),
      claudeEvent(timestamp: "2026-07-16T01:05:00.000Z", request: "request-2", message: "message-2", input: 10),
      claudeEvent(timestamp: "2026-07-16T01:15:00.000Z", request: "request-3", message: "message-3", input: 20)
    ]
    try Data(events.joined(separator: "\n").utf8).write(to: projects.appendingPathComponent("session.jsonl"))
    let daily = #"""
      {"daily":[{"period":"2026-07-16","agents":[{"agent":"claude","modelBreakdowns":[
        {"modelName":"claude-fable-5","cost":12,"inputTokens":40,"outputTokens":0,
         "cacheCreationTokens":0,"cacheReadTokens":0}
      ]}]}]}
      """#
    let session = #"""
      {"session":[{"agent":"codex","metadata":{"lastActivity":"2026-07-16T02:00:00Z"},"modelBreakdowns":[
        {"modelName":"gpt-test","cost":2,"inputTokens":5,"outputTokens":0,
         "cacheCreationTokens":0,"cacheReadTokens":0}
      ]}]}
      """#
    let detailedUsage = "{\"daily\":\(String(daily.dropFirst(9).dropLast())),\"session\":\(String(session.dropFirst(11).dropLast()))}"
    let script = "#!/bin/sh\ncase \"$1\" in blocks) printf '%s' '{\"blocks\":[]}' ;; daily) printf '%s' '\(detailedUsage)' ;; session) printf '%s' '\(session)' ;; esac\n"
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let service = SnapshotService(
      stateStore: StateStore(fileURL: root.appendingPathComponent("state.json")),
      client: CCUsageClient(executable: executable),
      calculator: ResetWindowCalculator(calendar: calendar),
      claudeUsageEventLoader: ClaudeUsageEventLoader(roots: [projects])
    )

    let snapshot = try await service.snapshot(now: ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!)
    let claude = snapshot.dashboardSessions.filter { $0.agent == "claude" }

    #expect(claude.count == 2)
    #expect(claude[0].costUSD == 6)
    #expect(claude[0].inputTokens == 20)
    #expect(claude[1].costUSD == 6)
    #expect(claude.reduce(Decimal.zero) { $0 + $1.costUSD } == 12)
    #expect(snapshot.dashboardSessions.contains { $0.agent == "codex" && $0.costUSD == 2 })
  }

  private func claudeEvent(
    timestamp: String,
    request: String,
    message: String,
    input: Int
  ) -> String {
    [
      #"{"type":"assistant","timestamp":"\#(timestamp)","sessionId":"session-1","requestId":"\#(request)","#,
      #""message":{"id":"\#(message)","role":"assistant","model":"claude-fable-5","usage":{"#,
      #""input_tokens":\#(input),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    ].joined()
  }
}

@Suite("CodexUsageEventTests") struct CodexUsageEventTests {
  @Test func reverseScanRetainsModelContextImmediatelyBeforeRequestedDay() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("rollout.jsonl")
    let rows = [
      #"{"timestamp":"2026-07-01T00:00:00.000Z","type":"session_meta","payload":{"id":"session-1"}}"#,
      #"{"timestamp":"2026-07-15T23:59:59.000Z","type":"turn_context","payload":{"model":"gpt-boundary"}}"#,
      codexTokenEvent(timestamp: "2026-07-16T00:00:01.000Z", total: 100, input: 80, cached: 50, output: 20)
    ]
    try Data(rows.joined(separator: "\n").utf8).write(to: log)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let events = try await CodexUsageEventLoader(roots: [root]).events(
      since: "2026-07-16",
      until: "2026-07-16",
      calendar: calendar
    )

    #expect(events.count == 1)
    #expect(events.first?.model == "gpt-boundary")
  }

  @Test func tracksTurnModelAndDeduplicatesCumulativeTokenWatermarks() async throws {
    let root = try temporaryDirectory()
    let log = root.appendingPathComponent("rollout.jsonl")
    let rows = [
      #"{"timestamp":"2026-07-16T01:00:00.000Z","type":"session_meta","payload":{"id":"session-1"}}"#,
      #"{"timestamp":"2026-07-16T01:00:01.000Z","type":"turn_context","payload":{"model":"gpt-test"}}"#,
      codexTokenEvent(timestamp: "2026-07-16T01:05:00.000Z", total: 100, input: 80, cached: 50, output: 20),
      codexTokenEvent(timestamp: "2026-07-16T01:05:01.000Z", total: 100, input: 80, cached: 50, output: 20),
      codexTokenEvent(timestamp: "2026-07-16T01:20:00.000Z", total: 160, input: 45, cached: 30, output: 15)
    ]
    try Data(rows.joined(separator: "\n").utf8).write(to: log)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let events = try await CodexUsageEventLoader(roots: [root]).events(
      since: "2026-07-16",
      until: "2026-07-16",
      calendar: calendar
    )

    try #require(events.count == 2)
    #expect(events.allSatisfy { $0.agent == "codex" && $0.model == "gpt-test" })
    #expect(events[0].inputTokens == 30)
    #expect(events[0].cacheReadTokens == 50)
    #expect(events[1].outputTokens == 15)
  }

  private func codexTokenEvent(
    timestamp: String,
    total: Int,
    input: Int,
    cached: Int,
    output: Int
  ) -> String {
    let totalInput = total - output
    return [
      #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"#,
      #""total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":0,"output_tokens":\#(output),"#,
      #""reasoning_output_tokens":0,"total_tokens":\#(total)},"#,
      #""last_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"#,
      #""reasoning_output_tokens":0,"total_tokens":\#(input + output)}}}}"#
    ].joined()
  }
}

@Suite("CostAggregationTests", .serialized) struct CostAggregationTests {
  @Test func menuBarSnapshotLoadsOnlyCycleRequiredDailyData() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let log = root.appendingPathComponent("arguments.log")
    let daily = #"{"daily":[{"period":"2026-07-16","agents":[{"agent":"codex","modelBreakdowns":[{"modelName":"gpt-test","cost":2.5,"inputTokens":10,"outputTokens":3,"cacheCreationTokens":0,"cacheReadTokens":20}]}]}]}"#
    let script = """
      #!/bin/sh
      printf '%s\n' "$*" >> '\(log.path)'
      case "$1" in
        daily) printf '%s' '\(daily)' ;;
        *) exit 64 ;;
      esac
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let service = SnapshotService(
      stateStore: StateStore(fileURL: root.appendingPathComponent("state.json")),
      client: CCUsageClient(executable: executable),
      calculator: ResetWindowCalculator(calendar: calendar)
    )

    let snapshot = try await service.menuBarSnapshot(now: now)
    let arguments = try String(contentsOf: log, encoding: .utf8)

    #expect(snapshot.costSinceResetUSD == Decimal(string: "2.5"))
    #expect(arguments.contains("daily --json --sections daily,session"))
    #expect(!arguments.contains("blocks"))
    #expect(!arguments.split(separator: "\n").contains { $0.hasPrefix("session ") })
  }

  @Test func menuBarSnapshotUsesCachedHistoryForLongCalendarCycle() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let log = root.appendingPathComponent("arguments.log")
    let daily = #"{"daily":[{"period":"2026-07-16","agents":[{"agent":"codex","modelBreakdowns":[{"modelName":"gpt-test","cost":2.5,"inputTokens":10,"outputTokens":3,"cacheCreationTokens":0,"cacheReadTokens":20}]}]}]}"#
    let script = """
      #!/bin/sh
      printf '%s\n' "$*" >> '\(log.path)'
      case "$1" in daily) printf '%s' '\(daily)' ;; *) exit 64 ;; esac
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let cache = UsageAggregationCache(fileURL: root.appendingPathComponent("cache/aggregates.sqlite3"))
    try await cache.save(
      metrics: [CCUsageMetricRecord(
        date: "2026-07-10",
        agent: "codex",
        model: "gpt-test",
        costUSD: 4,
        inputTokens: 1,
        outputTokens: 1,
        cacheCreationTokens: 0,
        cacheReadTokens: 0
      )],
      sessions: [],
      cachedFrom: "2026-07-01",
      cachedThrough: "2026-07-15",
      now: now
    )
    let service = SnapshotService(
      stateStore: StateStore(fileURL: root.appendingPathComponent("state.json")),
      client: CCUsageClient(executable: executable),
      calculator: ResetWindowCalculator(calendar: calendar),
      aggregationCache: cache
    )

    let snapshot = try await service.menuBarSnapshot(now: now, defaultCycle: .monthly)
    let arguments = try String(contentsOf: log, encoding: .utf8)

    #expect(snapshot.costSinceResetUSD == Decimal(string: "6.5"))
    #expect(arguments.contains("daily --json --sections daily,session"))
    #expect(!arguments.contains("blocks"))
    #expect(!arguments.split(separator: "\n").contains { $0.hasPrefix("session ") })
  }

  @Test func snapshotLoadsCurrentWeekThenBackfillsOlderHistoryInWeeklyRanges() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let log = root.appendingPathComponent("arguments.log")
    let blocks = #"{"blocks":[]}"#
    let daily = #"{"daily":[{"period":"2026-07-16","agents":[]}],"session":[]}"#
    let script = """
      #!/bin/sh
      printf '%s\n' "$*" >> '\(log.path)'
      case "$1" in
        blocks) printf '%s' '\(blocks)' ;;
        daily) printf '%s' '\(daily)' ;;
        session) printf '%s' '{"session":[]}' ;;
      esac
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let cache = UsageAggregationCache(fileURL: root.appendingPathComponent("cache/aggregates-v1.sqlite3"))
    let service = SnapshotService(
      stateStore: StateStore(fileURL: root.appendingPathComponent("state.json")),
      client: CCUsageClient(executable: executable),
      calculator: ResetWindowCalculator(calendar: calendar),
      aggregationCache: cache
    )
    _ = try await service.snapshot(now: now)
    _ = try await service.snapshot(now: now)
    let olderDate = ISO8601DateFormatter().date(from: "2026-05-10T00:00:00Z")!
    _ = try await service.snapshot(now: now, earliestDate: olderDate)
    let arguments = try String(contentsOf: log, encoding: .utf8)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let weekStart = try #require(calendar.dateInterval(of: .weekOfYear, for: now)?.start)
    let weekStartText = formatter.string(from: weekStart)
    #expect(arguments.contains("blocks --json --since \(weekStartText) --until 2026-07-16"))
    #expect(!arguments.contains("blocks --json --since 2026-05-10 --until 2026-07-16"))
    #expect(arguments.components(separatedBy: "daily --json --sections daily,session").count - 1 == 1)
    #expect(!arguments.contains("session --json"))
    #expect(!arguments.contains("daily --json --since"))
    #expect(!arguments.contains("--by-agent"))
    #expect(await cache.load(now: now)?.cachedFrom == "2026-05-10")
  }

  @Test func detailedDailyFallsBackToAndCachesCCUsageTwentyZeroSeventeenArguments() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let log = root.appendingPathComponent("arguments.log")
    let unified = #"{"daily":[{"period":"2026-07-16","totalCost":2.5,"modelsUsed":["gpt-test"]}]}"#
    let byAgent = #"""
      {"daily":[{"period":"2026-07-16","agents":[{"agent":"codex","modelBreakdowns":[
        {"modelName":"gpt-test","cost":2.5,"inputTokens":10,"outputTokens":3,
         "cacheCreationTokens":0,"cacheReadTokens":20}
      ]}]}]}
      """#
    let script = """
      #!/bin/sh
      printf '%s\n' "$*" >> '\(log.path)'
      case " $* " in
        *" --by-agent "*) printf '%s' '\(byAgent)' ;;
        *) printf '%s' '\(unified)' ;;
      esac
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let client = CCUsageClient(executable: executable)

    let first = try await client.detailedDaily(since: "2026-07-16", until: "2026-07-16")
    let second = try await client.detailedDaily(since: "2026-07-16", until: "2026-07-16")
    let arguments = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")

    #expect(first == second)
    #expect(first.first?.agent == "codex")
    #expect(arguments.count == 3)
    #expect(!arguments[0].contains("--by-agent"))
    #expect(arguments[1].contains("--by-agent"))
    #expect(arguments[2].contains("--by-agent"))
  }

  @Test func detailedDailyCachesFlagFreeCCUsageTwentyOneArguments() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let count = root.appendingPathComponent("count")
    let log = root.appendingPathComponent("arguments.log")
    let detailed = #"{"daily":[{"period":"2026-07-16","agents":[]}] }"#
    let script = """
      #!/bin/sh
      current=$(cat '\(count.path)' 2>/dev/null || printf '0')
      current=$((current + 1))
      printf '%s' "$current" > '\(count.path)'
      printf '%s\n' "$*" >> '\(log.path)'
      if [ "$current" -eq 1 ]; then
        printf '%s' '\(detailed)'
      else
        printf '%s' '{"daily":[{"period":"2026-07-16","totalCost":0,"modelsUsed":[]}]}'
      fi
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let client = CCUsageClient(executable: executable)

    _ = try await client.detailedDaily()
    await #expect(throws: CCUsageError.invalidJSON) {
      try await client.detailedDaily()
    }
    let arguments = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")

    #expect(arguments.count == 2)
    #expect(arguments.allSatisfy { !$0.contains("--by-agent") })
  }

  @Test func detailedUsageCoalescesConcurrentFlagFreeScans() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let count = root.appendingPathComponent("count")
    let detailed = #"{"daily":[{"period":"2026-07-16","agents":[]}],"session":[]}"#
    let script = """
      #!/bin/sh
      current=$(cat '\(count.path)' 2>/dev/null || printf '0')
      printf '%s' "$((current + 1))" > '\(count.path)'
      sleep 0.1
      printf '%s' '\(detailed)'
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let client = CCUsageClient(executable: executable)

    async let first = client.detailedUsage()
    async let second = client.detailedUsage()
    let results = try await [first, second]

    #expect(results[0] == results[1])
    #expect(try String(contentsOf: count, encoding: .utf8) == "1")
  }

  @Test func detailedUsageFallsBackToAndCachesByAgentArguments() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let log = root.appendingPathComponent("arguments.log")
    let unified = #"{"daily":[{"period":"2026-07-16","totalCost":2.5,"modelsUsed":["gpt-test"]}],"session":[]}"#
    let detailed = #"{"daily":[{"period":"2026-07-16","agents":[{"agent":"codex","modelBreakdowns":[]}]}],"session":[]}"#
    let script = """
      #!/bin/sh
      printf '%s\n' "$*" >> '\(log.path)'
      case " $* " in
        *" --by-agent "*) printf '%s' '\(detailed)' ;;
        *) printf '%s' '\(unified)' ;;
      esac
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let client = CCUsageClient(executable: executable)

    _ = try await client.detailedUsage()
    _ = try await client.detailedUsage()
    let arguments = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")

    #expect(arguments.count == 2)
    #expect(!arguments[0].contains("--by-agent"))
    #expect(arguments[1].contains("--by-agent"))
    #expect(arguments.allSatisfy { $0.contains("--sections daily,session") })
  }

  @Test func snapshotUsesClosedBoundaryAndExcludesFuture() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let payload = """
      {"blocks":[\
      {"startTime":"2026-07-15T00:00:00Z","costUSD":1,"models":["a"]},\
      {"startTime":"2026-07-15T12:00:00Z","costUSD":2,"models":["b"]},\
      {"startTime":"2026-07-15T12:00:01Z","costUSD":4,"models":["c"]}]}
      """
    let dailyPayload = """
      {"daily":[{"period":"2026-07-15","agents":[{"agent":"codex","modelBreakdowns":[{"modelName":"gpt-5.6-sol","cost":3,"inputTokens":10,"outputTokens":2,"cacheCreationTokens":0,"cacheReadTokens":20}]}]}]}
      """
    let sessionPayload = """
      {"session":[{"agent":"codex","metadata":{"lastActivity":"2026-07-15T11:00:00Z"},"modelBreakdowns":[
        {"modelName":"gpt-5.6-sol","cost":99,"inputTokens":10,"outputTokens":2,"cacheCreationTokens":0,"cacheReadTokens":20}
      ]}]}
      """
    let detailedUsage = "{\"daily\":\(String(dailyPayload.dropFirst(9).dropLast())),\"session\":\(String(sessionPayload.dropFirst(11).dropLast()))}"
    let script = "#!/bin/sh\ncase \"$1\" in blocks) printf '%s' '\(payload)' ;; daily) printf '%s' '\(detailedUsage)' ;; session) printf '%s' '\(sessionPayload)' ;; esac\n"
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let store = StateStore(fileURL: root.appendingPathComponent("state.json"))
    let now = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let service = SnapshotService(
      stateStore: store,
      client: CCUsageClient(executable: executable),
      calculator: ResetWindowCalculator(calendar: calendar),
      defaultRefreshIntervalSeconds: 45
    )
    let snapshot = try await service.snapshot(now: now)
    #expect(snapshot.costSinceResetUSD == 3)
    #expect(snapshot.refreshIntervalSeconds == 45)
    #expect(snapshot.dashboardMetrics.first?.model == "gpt-5.6-sol")
    #expect(snapshot.dashboardSessions.first?.costUSD == 99)
  }
}
