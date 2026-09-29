import Foundation
import Testing
@testable import AppCore

@Suite("EffortReconciliationTests")
struct EffortReconciliationTests {
  @Test func reconciliationSeparatesEffortsAndPreservesAuthoritativeTotals() async throws {
    let withEffort = try await loadSnapshot(includeEffort: true)
    let withoutEffort = try await loadSnapshot(includeEffort: false)
    let rows = withEffort.dashboardSessions.filter { $0.model == "gpt-test" }
    let legacyRows = withoutEffort.dashboardSessions.filter { $0.model == "gpt-test" }

    #expect(rows.count == 3)
    #expect(Set(rows.compactMap(\.effort)) == Set(["high", "low"]))
    #expect(rows.contains { $0.effort == nil })
    #expect(legacyRows.count == 1)
    #expect(totalCost(rows) == totalCost(legacyRows))
    #expect(totalInputTokens(rows) == totalInputTokens(legacyRows))
    #expect(totalOutputTokens(rows) == totalOutputTokens(legacyRows))
    #expect(totalCacheCreationTokens(rows) == totalCacheCreationTokens(legacyRows))
    #expect(totalCacheReadTokens(rows) == totalCacheReadTokens(legacyRows))

    let daily = try #require(withEffort.dashboardMetrics.first { $0.model == "gpt-test" })
    #expect(totalCost(rows) == daily.costUSD)
    #expect(totalInputTokens(rows) == daily.inputTokens)
    #expect(totalOutputTokens(rows) == daily.outputTokens)
    #expect(totalCacheCreationTokens(rows) == daily.cacheCreationTokens)
    #expect(totalCacheReadTokens(rows) == daily.cacheReadTokens)
  }

  @Test func coalescingSumsIdenticalEffortKeysAndKeepsOtherEfforts() {
    let timestamp = Date(timeIntervalSince1970: 1_784_160_000)
    let rows = [
      session(timestamp: timestamp, cost: 2, effort: "high"),
      session(timestamp: timestamp, cost: 3, effort: "high"),
      session(timestamp: timestamp, cost: 5, effort: "low"),
      session(timestamp: timestamp, cost: 7, effort: nil)
    ]

    let coalesced = coalescingSameKeySessions(rows)

    #expect(coalesced.count == 3)
    #expect(coalesced.first { $0.effort == "high" }?.costUSD == 5)
    #expect(coalesced.first { $0.effort == "low" }?.costUSD == 5)
    #expect(coalesced.first { $0.effort == nil }?.costUSD == 7)
  }

  @Test func snapshotMergeRetainsDistinctEffortsAndReplacesMatchingEffort() {
    let timestamp = Date(timeIntervalSince1970: 1_784_160_000)
    let existing = snapshot(sessions: [session(timestamp: timestamp, cost: 2, effort: "high")])
    let fresh = snapshot(sessions: [
      session(timestamp: timestamp, cost: 3, effort: "low"),
      session(timestamp: timestamp, cost: 5, effort: "high")
    ])

    let merged = mergingSnapshots(existing: existing, fresh: fresh, calendar: utcCalendar())

    #expect(merged.dashboardSessions.count == 2)
    #expect(merged.dashboardSessions.first { $0.effort == "high" }?.costUSD == 5)
    #expect(merged.dashboardSessions.first { $0.effort == "low" }?.costUSD == 3)
  }

  private func loadSnapshot(includeEffort: Bool) async throws -> CostSnapshot {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ccusage-effort-reconciliation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let log = root.appendingPathComponent("rollout.jsonl")
    let executable = root.appendingPathComponent("ccusage")
    let effortContexts = includeEffort ? ["high", "high", "low", nil] : [nil, nil, nil, nil]
    var events = [#"{"timestamp":"2026-07-16T00:00:00.000Z","type":"session_meta","payload":{"id":"session-1"}}"#]
    let timestamps = [
      "2026-07-16T01:00:01.000Z",
      "2026-07-16T01:05:01.000Z",
      "2026-07-16T01:10:01.000Z",
      "2026-07-16T01:12:01.000Z"
    ]
    for (index, timestamp) in timestamps.enumerated() {
      events.append(turnContextEvent(effort: effortContexts[index]))
      events.append(
        codexTokenEvent(timestamp: timestamp, index: index)
      )
    }
    try Data(events.joined(separator: "\n").utf8).write(to: log)

    let usage = detailedUsageJSON()
    let script = "#!/bin/sh\ncase \"$1\" in blocks) printf '%s' '{\"blocks\":[]}' ;; *) printf '%s' '\(usage)' ;; esac\n"
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let service = SnapshotService(
      stateStore: StateStore(fileURL: root.appendingPathComponent("state.json")),
      client: CCUsageClient(executable: executable),
      calculator: ResetWindowCalculator(calendar: utcCalendar()),
      codexUsageEventLoader: CodexUsageEventLoader(roots: [root])
    )
    return try await service.snapshot(
      now: ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z")!
    )
  }

  private func codexTokenEvent(timestamp: String, index: Int) -> String {
    let input = 10 + (index * 5)
    let output = 2 + index
    let total = input + output
    let usage: [String: Int] = [
      "input_tokens": input,
      "cached_input_tokens": 0,
      "output_tokens": output,
      "reasoning_output_tokens": 0,
      "total_tokens": total
    ]
    let object: [String: Any] = [
      "timestamp": timestamp,
      "type": "event_msg",
      "payload": [
        "type": "token_count",
        "info": ["total_token_usage": usage, "last_token_usage": usage]
      ]
    ]
    let data = try? JSONSerialization.data(withJSONObject: object)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  private func turnContextEvent(effort: String?) -> String {
    var payload: [String: String] = ["model": "gpt-test"]
    if let effort { payload["effort"] = effort }
    let object: [String: Any] = [
      "timestamp": "2026-07-16T00:59:00.000Z",
      "type": "turn_context",
      "payload": payload
    ]
    let data = try? JSONSerialization.data(withJSONObject: object)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  private func detailedUsageJSON() -> String {
    let breakdown: [String: Any] = [
      "modelName": "gpt-test",
      "cost": 12,
      "inputTokens": 100,
      "outputTokens": 20,
      "cacheCreationTokens": 8,
      "cacheReadTokens": 40
    ]
    let agent: [String: Any] = ["agent": "codex", "modelBreakdowns": [breakdown]]
    let day: [String: Any] = ["period": "2026-07-16", "agents": [agent]]
    let object: [String: Any] = ["daily": [day], "session": [[String: String]]()]
    let data = try? JSONSerialization.data(withJSONObject: object)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  private func session(timestamp: Date, cost: Decimal, effort: String?) -> CCUsageSessionMetricRecord {
    CCUsageSessionMetricRecord(
      timestamp: timestamp,
      agent: "codex",
      model: "gpt-test",
      costUSD: cost,
      inputTokens: 1,
      dataQuality: .timestamped,
      effort: effort
    )
  }

  private func snapshot(sessions: [CCUsageSessionMetricRecord]) -> CostSnapshot {
    let now = Date(timeIntervalSince1970: 1_784_163_600)
    return CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now.addingTimeInterval(-86_400),
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: 100),
      resetCycle: .daily,
      points: [],
      dashboardMetrics: [],
      dashboardSessions: sessions
    )
  }

  private func totalCost(_ rows: [CCUsageSessionMetricRecord]) -> Decimal {
    rows.reduce(Decimal.zero) { $0 + $1.costUSD }
  }

  private func totalInputTokens(_ rows: [CCUsageSessionMetricRecord]) -> Int {
    rows.reduce(0) { $0 + $1.inputTokens }
  }

  private func totalOutputTokens(_ rows: [CCUsageSessionMetricRecord]) -> Int {
    rows.reduce(0) { $0 + $1.outputTokens }
  }

  private func totalCacheCreationTokens(_ rows: [CCUsageSessionMetricRecord]) -> Int {
    rows.reduce(0) { $0 + $1.cacheCreationTokens }
  }

  private func totalCacheReadTokens(_ rows: [CCUsageSessionMetricRecord]) -> Int {
    rows.reduce(0) { $0 + $1.cacheReadTokens }
  }

  private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }
}
