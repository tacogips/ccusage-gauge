import Foundation
import Testing
@testable import AppCore

@Suite("Usage directory event and compatibility tests")
struct UsageDirectoryEventTests {
  @Test func legacyRecordsDecodeWithoutDirectoryAndNilIsOmitted() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacyJSON = """
      {"timestamp":"2026-07-16T01:00:00Z","agent":"codex","model":"gpt","costUSD":1,
      "inputTokens":1,"outputTokens":2,"cacheCreationTokens":0,"cacheReadTokens":3,
      "totalTokens":6,"dataQuality":"timestamped","machine":"local"}
      """
    let record = try decoder.decode(
      CCUsageSessionMetricRecord.self,
      from: Data(legacyJSON.utf8)
    )
    #expect(record.directory == nil)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let object = try #require(
      JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any]
    )
    #expect(object["directory"] == nil)
  }

  @Test func claudeCwdIsOpaqueAndEmptyCwdBecomesNil() throws {
    let withDirectory = ClaudeUsageEventLoader.decode(line: Data(
      claudeEvent(cwd: "/Users/example/my-project").utf8
    ))
    let emptyDirectory = ClaudeUsageEventLoader.decode(line: Data(
      claudeEvent(cwd: "   ").utf8
    ))

    #expect(withDirectory?.directory == "/Users/example/my-project")
    #expect(emptyDirectory?.directory == nil)
  }

  @Test func codexForwardAndReverseScansAssociateSessionCwdIdentically() async throws {
    let root = try temporaryDirectory()
    let rows = [
      #"{"timestamp":"2026-07-01T00:00:00.000Z","type":"session_meta","payload":{"id":"session-1","cwd":"/work/codex-project"}}"#,
      #"{"timestamp":"2026-07-15T23:59:59.000Z","type":"turn_context","payload":{"model":"gpt-test"}}"#,
      codexTokenEvent(timestamp: "2026-07-16T00:00:01.000Z")
    ]
    try Data(rows.joined(separator: "\n").utf8)
      .write(to: root.appendingPathComponent("rollout.jsonl"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let loader = CodexUsageEventLoader(roots: [root])

    let forward = try await loader.events(since: nil, until: "2026-07-16", calendar: calendar)
    let reverse = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: calendar)

    #expect(forward.count == 1)
    #expect(reverse.count == 1)
    #expect(forward.first?.directory == "/work/codex-project")
    #expect(reverse.first?.directory == forward.first?.directory)
    #expect(reverse.first?.sessionID == "session-1")
  }

  @Test func codexForwardAndReverseScansPreserveMultipleModelContexts() async throws {
    let root = try temporaryDirectory()
    let rows = [
      #"{"timestamp":"2026-07-01T00:00:00.000Z","type":"session_meta","payload":{"id":"session-1","cwd":"/work/codex-project"}}"#,
      #"{"timestamp":"2026-07-16T00:00:00.000Z","type":"turn_context","payload":{"model":"gpt-first"}}"#,
      codexTokenEvent(timestamp: "2026-07-16T00:00:01.000Z", totalInput: 10),
      #"{"timestamp":"2026-07-16T00:05:00.000Z","type":"turn_context","payload":{"model":"gpt-second"}}"#,
      codexTokenEvent(timestamp: "2026-07-16T00:05:01.000Z", totalInput: 20)
    ]
    try Data(rows.joined(separator: "\n").utf8)
      .write(to: root.appendingPathComponent("rollout.jsonl"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let loader = CodexUsageEventLoader(roots: [root])

    let forward = try await loader.events(since: nil, until: "2026-07-16", calendar: calendar)
    let reverse = try await loader.events(since: "2026-07-16", until: "2026-07-16", calendar: calendar)

    #expect(forward.map(\.model) == ["gpt-first", "gpt-second"])
    #expect(reverse.map(\.model) == forward.map(\.model))
    #expect(reverse.allSatisfy { $0.directory == "/work/codex-project" })
  }

  private func claudeEvent(cwd: String) -> String {
    [
      #"{"type":"assistant","timestamp":"2026-07-16T01:00:00.000Z","sessionId":"session-1","#,
      #""requestId":"request-1","cwd":"\#(cwd)","message":{"id":"message-1","role":"assistant","#,
      #""model":"claude-test","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":0,"#,
      #""cache_read_input_tokens":3}}}"#
    ].joined()
  }

  private func codexTokenEvent(timestamp: String, totalInput: Int = 10) -> String {
    [
      #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"#,
      #""total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":3,"output_tokens":2,"#,
      #""reasoning_output_tokens":0,"total_tokens":\#(totalInput + 2)},"last_token_usage":{"input_tokens":\#(totalInput),"#,
      #""cached_input_tokens":3,"output_tokens":2,"reasoning_output_tokens":0,"total_tokens":\#(totalInput + 2)}}}}"#
    ].joined()
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ccusage-directory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

@Suite("Directory-aware dashboard query tests")
struct DashboardDirectoryQueryTests {
  @Test func filtersOnlyAddressedMachineAndExcludesItsUnattributedRows() throws {
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let snapshot = directorySnapshot(now: now)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let query = DashboardQueryService(calendar: calendar)

    let response = try query.costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "today",
      now: now,
      directorySelections: ["local": ["/work/a"]]
    )

    #expect(response.rows.contains { $0.machine == "local" && $0.directory == "/work/a" })
    #expect(!response.rows.contains { $0.machine == "local" && $0.directory == nil })
    #expect(response.rows.contains { $0.machine == "remote" && $0.directory == nil })
    #expect(response.totalUSD == 5)
  }

  @Test func directoryBreakdownPreservesTotalsAndDefaultPathCollapsesDirectories() throws {
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let snapshot = directorySnapshot(now: now)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let query = DashboardQueryService(calendar: calendar)

    let unchanged = try query.costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "today",
      now: now
    )
    let breakdown = try query.costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "today",
      now: now,
      directoryBreakdown: true
    )
    let daily = try query.costSeries(
      snapshot: snapshot,
      granularity: "daily",
      range: "today",
      now: now,
      directoryBreakdown: true
    )

    #expect(unchanged.totalUSD == breakdown.totalUSD)
    #expect(unchanged.rows.allSatisfy { $0.directory == nil })
    #expect(breakdown.rows.map(\.directory).contains("/work/a"))
    #expect(daily.totalUSD == breakdown.totalUSD)
  }

  @Test func filteredBudgetUsesDirectoryResolvedSpentValues() {
    let now = ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    let snapshot = directorySnapshot(now: now)
    let response = DashboardQueryService().budget(
      snapshot: snapshot,
      directorySelections: ["local": ["/work/a"]]
    )

    #expect(response.spentUSD == 5)
    #expect(response.remainingUSD == 5)
  }

  private func directorySnapshot(now: Date) -> CostSnapshot {
    let timestamp = now.addingTimeInterval(-3_600)
    let sessions = [
      session(timestamp: timestamp, machine: "local", directory: "/work/a", cost: 1),
      session(timestamp: timestamp, machine: "local", directory: "/work/b", cost: 2),
      session(timestamp: timestamp, machine: "local", directory: nil, cost: 3),
      session(timestamp: timestamp, machine: "remote", directory: nil, cost: 4)
    ]
    return CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now.addingTimeInterval(-7_200),
      costSinceResetUSD: 10,
      budget: BudgetSummary(spentUSD: 10, budgetUSD: 10),
      resetCycle: .daily,
      points: [],
      dashboardMetrics: [],
      dashboardSessions: sessions
    )
  }

  private func session(
    timestamp: Date,
    machine: String,
    directory: String?,
    cost: Decimal
  ) -> CCUsageSessionMetricRecord {
    CCUsageSessionMetricRecord(
      timestamp: timestamp,
      agent: "codex",
      model: "gpt-test",
      costUSD: cost,
      inputTokens: 1,
      dataQuality: .timestamped,
      machine: machine,
      directory: directory
    )
  }
}

@Suite("Directory API request tests")
struct MachineDirectoryAPITests {
  @Test func parsesEncodedSelectionsAndBreakdown() throws {
    let components = try #require(URLComponents(
      string: "http://127.0.0.1/api/cost-series?machine=local&directory=local%3A%2Fwork%2Fa&directoryBreakdown=true"
    ))
    let request = try dashboardDirectoryRequest(
      components,
      descriptors: [.local],
      requestedMachines: "local",
      acceptsBreakdown: true
    )

    #expect(request.selections == ["local": ["/work/a"]])
    #expect(request.breakdown)
  }

  @Test func rejectsMalformedAndUnknownMachineWithoutRetainingDirectoryText() {
    let malformed = URLComponents(string: "http://127.0.0.1/api/metrics?directory=local")!
    let unknown = URLComponents(
      string: "http://127.0.0.1/api/metrics?directory=unknown%3A%2Fsensitive%2Fpath"
    )!

    #expect(throws: DashboardDirectoryRequestError.invalid) {
      try dashboardDirectoryRequest(
        malformed,
        descriptors: [.local],
        requestedMachines: "local",
        acceptsBreakdown: false
      )
    }
    #expect(throws: DashboardDirectoryRequestError.machineNotFound) {
      try dashboardDirectoryRequest(
        unknown,
        descriptors: [.local],
        requestedMachines: "local",
        acceptsBreakdown: false
      )
    }
  }
}

@Suite("Directory cache migration and persistence tests")
struct DirectoryCacheMigrationTests {
  @Test func roundTripsDirectoryAndMarksNewlySavedCoverage() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ccusage-directory-cache-\(UUID().uuidString)", isDirectory: true)
    let cache = UsageAggregationCache(fileURL: root.appendingPathComponent("aggregates.sqlite3"))
    let timestamp = ISO8601DateFormatter().date(from: "2026-07-16T01:00:00Z")!
    let row = CCUsageSessionMetricRecord(
      timestamp: timestamp,
      agent: "codex",
      model: "gpt",
      costUSD: 1,
      inputTokens: 1,
      dataQuality: .timestamped,
      directory: "/work/project"
    )

    try await cache.save(
      metrics: [],
      sessions: [row],
      cachedFrom: "2026-07-16",
      cachedThrough: "2026-07-16"
    )
    let payload = await cache.load()

    #expect(payload?.sessions.first?.directory == "/work/project")
    #expect(payload?.directoryCoveredRanges == [
      AggregationCacheRange(since: "2026-07-16", through: "2026-07-16")
    ])
  }

  @Test func persistedStateAcceptsSubdirectoryStacking() throws {
    let state = DashboardUIState(
      range: "today",
      customStart: "2026-07-16",
      customEnd: "2026-07-16",
      selectedModels: [],
      selectedAgents: [],
      granularity: "hourly",
      chartMetric: "costUSD",
      stackBy: "subdirectory"
    )

    try state.validate()
  }

  @Test func unknownPersistedStackValueFallsBackToModel() throws {
    let json = """
      {"range":"today","customStart":"2026-07-16","customEnd":"2026-07-16",
      "selectedModels":[],"selectedAgents":[],"selectedMachines":[],"granularity":"hourly",
      "chartMetric":"costUSD","stackBy":"future-value"}
      """
    let state = try JSONDecoder().decode(
      DashboardUIState.self,
      from: Data(json.utf8)
    )

    #expect(state.stackBy == "model")
    try state.validate()
  }
}
