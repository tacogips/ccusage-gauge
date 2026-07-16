import Foundation
import Testing
@testable import AppCore

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
    let data = Data(#"{"blocks":[{"startTime":"2026-07-15T01:00:00Z","costUSD":1.25,"models":["opus"],"future":true}]}"#.utf8)
    let records = try CCUsageDecoder.blocks(from: data)
    #expect(records.count == 1)
    #expect(records[0].costUSD == Decimal(string: "1.25"))
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
    let script = "#!/bin/sh\ncase \"$1\" in blocks) printf '%s' '{\"blocks\":[]}' ;; daily) printf '%s' '\(daily)' ;; session) printf '%s' '\(session)' ;; esac\n"
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

@Suite("CostAggregationTests") struct CostAggregationTests {
  @Test func cachedSnapshotLimitsDetailedQueriesToCurrentDate() async throws {
    let root = try temporaryDirectory()
    let executable = root.appendingPathComponent("ccusage")
    let log = root.appendingPathComponent("arguments.log")
    let blocks = #"{"blocks":[]}"#
    let daily = #"{"daily":[{"period":"2026-07-16","agents":[]}] }"#
    let sessions = #"{"session":[]}"#
    let script = """
      #!/bin/sh
      printf '%s\n' "$*" >> '\(log.path)'
      case "$1" in
        blocks) printf '%s' '\(blocks)' ;;
        daily) printf '%s' '\(daily)' ;;
        session) printf '%s' '\(sessions)' ;;
      esac
      """
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let service = SnapshotService(
      stateStore: StateStore(fileURL: root.appendingPathComponent("state.json")),
      client: CCUsageClient(executable: executable),
      calculator: ResetWindowCalculator(calendar: calendar),
      aggregationCache: UsageAggregationCache(fileURL: root.appendingPathComponent("cache/aggregates-v1.sqlite3"))
    )
    _ = try await service.snapshot(now: now)
    _ = try await service.snapshot(now: now)
    let arguments = try String(contentsOf: log, encoding: .utf8)
    #expect(arguments.contains("daily --json --by-agent --since 2026-07-16 --until 2026-07-16"))
    #expect(arguments.contains("session --json --by-agent --since 2026-07-16 --until 2026-07-16"))
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
    let script = "#!/bin/sh\ncase \"$1\" in blocks) printf '%s' '\(payload)' ;; daily) printf '%s' '\(dailyPayload)' ;; session) printf '%s' '\(sessionPayload)' ;; esac\n"
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
