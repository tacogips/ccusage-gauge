import Foundation
import Testing
@testable import AppCore

private struct EffortCostSeriesRunner: CCUsageCommandRunner {
  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    ProcessResult(stdout: Data(#"{"daily":[],"session":[]}"#.utf8), stderr: Data(), exitStatus: 0)
  }
}

@Suite("EffortCostSeriesTests")
struct EffortCostSeriesTests {
  @Test func optionalBreakdownPreservesDefaultPayloadAndEffortTotals() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let timestamp = now.addingTimeInterval(-3_600)
    let sessions = [
      makeSession(timestamp: timestamp, cost: 1, effort: "high"),
      makeSession(timestamp: timestamp, cost: 2, effort: "low"),
      makeSession(timestamp: timestamp, cost: 3, effort: nil)
    ]
    let snapshot = makeSnapshot(
      now: now,
      sessions: sessions,
      metrics: [CCUsageMetricRecord(
        date: "2026-07-16",
        agent: "codex",
        model: "gpt-test",
        costUSD: 6,
        inputTokens: 3,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0
      )]
    )
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let query = DashboardQueryService(calendar: calendar)

    for granularity in ["15min", "hourly", "6hour", "daily"] {
      let omitted = try query.costSeries(
        snapshot: snapshot,
        granularity: granularity,
        range: "all",
        now: now
      )
      let explicitFalse = try query.costSeries(
        snapshot: snapshot,
        granularity: granularity,
        range: "all",
        now: now,
        effortBreakdown: false
      )
      #expect(omitted == explicitFalse)
      let encoded = try JSONEncoder().encode(omitted)
      let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      let rows = try #require(object["rows"] as? [[String: Any]])
      #expect(rows.allSatisfy { $0["effort"] == nil })
      if granularity != "daily" {
        #expect(omitted.rows.count == 1)
        #expect(omitted.totalUSD == 6)
      }
    }

    let defaultRows = try query.costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "all",
      now: now
    )
    let effortRows = try query.costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "all",
      now: now,
      effortBreakdown: true
    )
    #expect(effortRows.rows.count == 3)
    #expect(Set(effortRows.rows.compactMap(\.effort)) == ["high", "low"])
    #expect(effortRows.rows.filter { $0.effort == nil }.count == 1)
    #expect(effortRows.totalUSD == defaultRows.totalUSD)

    let dailyEffortRows = try query.costSeries(
      snapshot: snapshot,
      granularity: "daily",
      range: "all",
      now: now,
      effortBreakdown: true
    )
    #expect(dailyEffortRows.rows.count == 3)
    #expect(dailyEffortRows.totalUSD == defaultRows.totalUSD)
  }

  @Test func directoryFilterAndDirectoryBreakdownComposeWithEffort() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let timestamp = now.addingTimeInterval(-3_600)
    let sessions = [
      makeSession(timestamp: timestamp, cost: 1, effort: "high", directory: "/work/a"),
      makeSession(timestamp: timestamp, cost: 2, effort: "low", directory: "/work/a"),
      makeSession(timestamp: timestamp, cost: 3, effort: nil, directory: "/work/a"),
      makeSession(timestamp: timestamp, cost: 7, effort: "high", directory: "/work/b")
    ]
    let snapshot = makeSnapshot(now: now, sessions: sessions)
    let query = DashboardQueryService()
    let filtered = try query.costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "all",
      now: now,
      directorySelections: ["local": ["/work/a"]],
      directoryBreakdown: true,
      effortBreakdown: true
    )
    #expect(filtered.rows.count == 3)
    #expect(filtered.rows.allSatisfy { $0.directory == "/work/a" })
    #expect(filtered.totalUSD == 6)

    let filteredCollapsed = try query.costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "all",
      now: now,
      directorySelections: ["local": ["/work/a"]]
    )
    #expect(filteredCollapsed.rows.count == 1)
    #expect(filteredCollapsed.rows.first?.directory == "/work/a")
    #expect(filteredCollapsed.totalUSD == filtered.totalUSD)

    let directoryCollapsed = try query.costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "all",
      now: now,
      directoryBreakdown: true
    )
    #expect(directoryCollapsed.rows.count == 2)
    #expect(directoryCollapsed.totalUSD == 13)

    let collapsed = try query.costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "all",
      now: now,
      directorySelections: ["local": ["/work/a"]],
      directoryBreakdown: true
    )
    #expect(collapsed.rows.count == 1)
    #expect(collapsed.rows.first?.effort == nil)
    #expect(collapsed.totalUSD == filtered.totalUSD)
  }

  @Test func requestParserUsesDistinctBreakdownErrors() throws {
    let valid = try #require(URLComponents(string: "http://localhost/api/cost-series?effortBreakdown=true"))
    let parsed = try dashboardDirectoryRequest(
      valid,
      descriptors: [.local],
      requestedMachines: "local",
      acceptsBreakdown: true
    )
    #expect(parsed.effortBreakdown)

    for path in [
      "http://localhost/api/cost-series?effortBreakdown=maybe",
      "http://localhost/api/cost-series?effortBreakdown=true&effortBreakdown=false",
      "http://localhost/api/metrics?effortBreakdown=true"
    ] {
      let components = try #require(URLComponents(string: path))
      #expect(throws: DashboardDirectoryRequestError.invalidBreakdown) {
        try dashboardDirectoryRequest(
          components,
          descriptors: [.local],
          requestedMachines: "local",
          acceptsBreakdown: components.path == "/api/cost-series"
        )
      }
    }

    let invalidDirectory = try #require(URLComponents(
      string: "http://localhost/api/cost-series?directoryBreakdown=maybe"
    ))
    #expect(throws: DashboardDirectoryRequestError.invalid) {
      try dashboardDirectoryRequest(
        invalidDirectory,
        descriptors: [.local],
        requestedMachines: "local",
        acceptsBreakdown: true
      )
    }
  }

  @Test func localHTTPRoutesExposeEffortAndStableErrorCodes() async throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let snapshot = makeSnapshot(
      now: now,
      sessions: [makeSession(timestamp: now.addingTimeInterval(-60), cost: 2, effort: "high")]
    )
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let router = DashboardRouter(
      snapshotProvider: { snapshot },
      assetResolver: StaticAssetResolver(explicitRoot: root)
    )

    let success = await router.route(target: "/api/cost-series?range=all&effortBreakdown=true")
    #expect(success.status == 200)
    #expect((String(bytes: success.body, encoding: .utf8) ?? "").contains("\"effort\":\"high\""))
    for target in [
      "/api/cost-series?effortBreakdown=maybe",
      "/api/cost-series?effortBreakdown=true&effortBreakdown=false",
      "/api/metrics?effortBreakdown=true"
    ] {
      let invalid = await router.route(target: target)
      #expect(invalid.status == 400)
      #expect((String(bytes: invalid.body, encoding: .utf8) ?? "").contains("invalid_breakdown"))
    }
    let invalidDirectory = await router.route(
      target: "/api/cost-series?directoryBreakdown=maybe"
    )
    #expect(invalidDirectory.status == 400)
    #expect((String(bytes: invalidDirectory.body, encoding: .utf8) ?? "").contains("invalid_directory"))
  }

  @Test func machineHTTPRouteForwardsEffortAndBreakdownErrors() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(
      configFile: root.appendingPathComponent("config/ccusage-gauge/config.json"),
      stateFile: root.appendingPathComponent("state/ccusage-gauge/state.json"),
      aggregationCacheFile: root.appendingPathComponent("cache/ccusage-gauge/aggregates.sqlite3")
    )
    let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
    let registry = try registryStore.load()
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let collector = try MachineCollector(registry: registry, store: store) { descriptor in
      SnapshotService(
        stateStore: StateStore(fileURL: paths.stateFile),
        client: CCUsageClient(commandRunner: EffortCostSeriesRunner(), machine: descriptor.id),
        aggregationCache: nil
      )
    }
    defer { Task { await collector.stop() } }
    let owner = MachineRegistryMutationOwner(store: registryStore, registry: registry, runtime: collector)
    let router = MachineDashboardRouter(store: store, collector: collector, mutationOwner: owner, paths: paths)
    let now = Date()
    await store.publish(
      machineID: "local",
      snapshot: makeSnapshot(
        now: now,
        sessions: [makeSession(timestamp: now.addingTimeInterval(-60), cost: 2, effort: "high")]
      ),
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: now
    )

    let success = await router.route(
      target: "/api/cost-series?machine=local&range=all&effortBreakdown=true",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    #expect(success.status == 200)
    #expect((String(bytes: success.body, encoding: .utf8) ?? "").contains("\"effort\":\"high\""))
    for (target, expectedCode) in [
      ("/api/cost-series?machine=local&effortBreakdown=maybe", "invalid_breakdown"),
      (
        "/api/cost-series?machine=local&effortBreakdown=true&effortBreakdown=false",
        "invalid_breakdown"
      ),
      ("/api/metrics?machine=local&effortBreakdown=true", "invalid_breakdown"),
      ("/api/cost-series?machine=local&directoryBreakdown=maybe", "invalid_directory")
    ] {
      let invalid = await router.route(
        target: target,
        method: "GET",
        headers: [:],
        body: Data(),
        listenerPort: 18_081
      )
      #expect(invalid.status == 400)
      #expect((String(bytes: invalid.body, encoding: .utf8) ?? "").contains(expectedCode))
    }
  }

  private func makeSnapshot(
    now: Date,
    sessions: [CCUsageSessionMetricRecord],
    metrics: [CCUsageMetricRecord] = []
  ) -> CostSnapshot {
    CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now.addingTimeInterval(-86_400),
      costSinceResetUSD: sessions.reduce(0) { $0 + $1.costUSD },
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: [],
      dashboardMetrics: metrics,
      dashboardSessions: sessions
    )
  }

  private func makeSession(
    timestamp: Date,
    cost: Decimal,
    effort: String?,
    directory: String? = "/work/a"
  ) -> CCUsageSessionMetricRecord {
    CCUsageSessionMetricRecord(
      timestamp: timestamp,
      agent: "codex",
      model: "gpt-test",
      costUSD: cost,
      inputTokens: 1,
      dataQuality: .timestamped,
      machine: "local",
      directory: directory,
      effort: effort
    )
  }
}
