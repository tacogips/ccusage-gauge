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
