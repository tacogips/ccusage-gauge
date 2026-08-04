import CSQLite
import Foundation
import Testing
@testable import AppCore

private enum DirectoryRegressionSQLiteError: Error {
  case open
  case execute
}

private actor HistoricalDirectoryRunner: CCUsageCommandRunner {
  private var calls: [[String]] = []

  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    calls.append(arguments)
    if arguments.first == "blocks" {
      return ProcessResult(stdout: Data(#"{"blocks":[]}"#.utf8), stderr: Data(), exitStatus: 0)
    }
    let payload = #"""
      {"daily":[{"period":"2026-05-10","agents":[{"agent":"claude","modelBreakdowns":[
        {"modelName":"claude-test","cost":5,"inputTokens":10,"outputTokens":2,
         "cacheCreationTokens":0,"cacheReadTokens":0}
      ]}]}],"session":[]}
      """#
    return ProcessResult(stdout: Data(payload.utf8), stderr: Data(), exitStatus: 0)
  }

  func recordedCalls() -> [[String]] { calls }
}

private actor DirectorySnapshotSource {
  private var snapshot: CostSnapshot

  init(snapshot: CostSnapshot) {
    self.snapshot = snapshot
  }

  func load() -> CostSnapshot { snapshot }
  func replace(with snapshot: CostSnapshot) { self.snapshot = snapshot }
}

@Suite("Directory default compatibility regressions")
struct DirectoryDefaultRegressionTests {
  @Test func defaultCostSeriesCollapsesDirectoriesInStableTimestampOrder() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let earlier = now.addingTimeInterval(-7_200)
    let later = now.addingTimeInterval(-3_600)
    let sessions = [
      session(timestamp: later, directory: "/work/b", cost: 2),
      session(timestamp: earlier, directory: "/work/a", cost: 1),
      session(timestamp: later, directory: "/work/a", cost: 3)
    ]
    let snapshot = snapshot(now: now, sessions: sessions)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let response = try DashboardQueryService(calendar: calendar).costSeries(
      snapshot: snapshot,
      granularity: "hourly",
      range: "today",
      now: now
    )

    #expect(response.rows.map(\.timestamp) == [earlier, later])
    #expect(response.rows.map(\.costUSD) == [1, 5])
    #expect(response.rows.allSatisfy { $0.directory == nil })
    #expect(response.totalUSD == 6)
  }

  @Test func snapshotMergeAndCoalescingKeepEqualRowsSeparatedByDirectory() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let timestamp = now.addingTimeInterval(-3_600)
    let first = session(timestamp: timestamp, directory: "/work/a", cost: 1)
    let second = session(timestamp: timestamp, directory: "/work/b", cost: 2)
    let merged = mergingSnapshots(
      existing: snapshot(now: now, sessions: [first]),
      fresh: snapshot(now: now, sessions: [second]),
      calendar: .current
    )

    #expect(Set(merged.dashboardSessions.compactMap { $0.directory }) == ["/work/a", "/work/b"])
    #expect(merged.dashboardSessions.count == 2)
    #expect(coalescingSameKeySessions([first, second]).count == 2)
  }

  private func snapshot(
    now: Date,
    sessions: [CCUsageSessionMetricRecord]
  ) -> CostSnapshot {
    CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now.addingTimeInterval(-86_400),
      costSinceResetUSD: sessions.reduce(0) { $0 + $1.costUSD },
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: [],
      dashboardMetrics: [],
      dashboardSessions: sessions
    )
  }

  private func session(
    timestamp: Date,
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
      directory: directory
    )
  }
}

@Suite("Directory SQLite migration and atomic replacement regressions")
struct DirectorySQLiteRegressionTests {
  @Test func genuinePreChangeDatabaseMigratesAsProvenanceUnscanned() async throws {
    let root = try directoryRegressionTemporaryDirectory()
    let file = root.appendingPathComponent("legacy.sqlite3")
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    try executeSQLite(
      at: file,
      sql: legacySchemaSQL(timestamp: now.addingTimeInterval(-3_600).timeIntervalSince1970)
    )
    let cache = UsageAggregationCache(fileURL: file, retentionDays: 365)

    let payload = try #require(await cache.load(now: now))

    #expect(payload.metrics.first?.directory == nil)
    #expect(payload.sessions.first?.directory == nil)
    #expect(payload.coveredRanges == [
      AggregationCacheRange(since: "2026-07-15", through: "2026-07-15")
    ])
    #expect(payload.directoryCoveredRanges.isEmpty)
  }

  @Test func failedReplacementRollsBackRowsAndCoverageThenRetryReplacesExactlyOnce() async throws {
    let root = try directoryRegressionTemporaryDirectory()
    let file = root.appendingPathComponent("atomic.sqlite3")
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let timestamp = now.addingTimeInterval(-86_400)
    let range = AggregationCacheRange(since: "2026-07-15", through: "2026-07-15")
    let cache = UsageAggregationCache(fileURL: file, retentionDays: 365)
    try await cache.save(
      metrics: [metric(directory: nil)],
      sessions: [session(timestamp: timestamp, directory: nil)],
      cachedFrom: range.since,
      cachedThrough: range.through,
      now: now,
      directoryCoveredRanges: []
    )
    try executeSQLite(
      at: file,
      sql: """
        CREATE TRIGGER reject_attributed_session
        BEFORE INSERT ON session_metrics
        WHEN NEW.directory IS NOT NULL
        BEGIN SELECT RAISE(ABORT, 'injected failure'); END;
        """
    )

    await #expect(throws: (any Error).self) {
      try await cache.merge(
        metrics: [metric(directory: nil, cost: 99)],
        sessions: [session(timestamp: timestamp, directory: "/work/project")],
        coveredRange: range,
        now: now
      )
    }

    let afterFailure = try #require(
      await UsageAggregationCache(fileURL: file, retentionDays: 365).load(now: now)
    )
    #expect(afterFailure.sessions.count == 1)
    #expect(afterFailure.sessions.first?.directory == nil)
    #expect(afterFailure.directoryCoveredRanges.isEmpty)
    #expect(afterFailure.metrics.first?.costUSD == 4)

    try executeSQLite(at: file, sql: "DROP TRIGGER reject_attributed_session")
    let retryCache = UsageAggregationCache(fileURL: file, retentionDays: 365)
    try await retryCache.merge(
      metrics: [metric(directory: nil, cost: 99)],
      sessions: [session(timestamp: timestamp, directory: "/work/project")],
      coveredRange: range,
      now: now
    )
    let afterRetry = try #require(await retryCache.load(now: now))

    #expect(afterRetry.sessions.count == 1)
    #expect(afterRetry.sessions.first?.directory == "/work/project")
    #expect(afterRetry.directoryCoveredRanges == [range])
    #expect(afterRetry.metrics.count == 1)
    #expect(afterRetry.metrics.first?.costUSD == 4)
    #expect(afterRetry.metrics.reduce(Decimal.zero) { $0 + $1.costUSD } == 4)
  }

  private func metric(directory: String?, cost: Decimal = 4) -> CCUsageMetricRecord {
    CCUsageMetricRecord(
      date: "2026-07-15",
      agent: "codex",
      model: "gpt-test",
      costUSD: cost,
      inputTokens: 10,
      outputTokens: 2,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
      directory: directory
    )
  }

  private func session(
    timestamp: Date,
    directory: String?
  ) -> CCUsageSessionMetricRecord {
    CCUsageSessionMetricRecord(
      timestamp: timestamp,
      agent: "codex",
      model: "gpt-test",
      costUSD: 4,
      inputTokens: 10,
      outputTokens: 2,
      dataQuality: .timestamped,
      directory: directory
    )
  }

  private func legacySchemaSQL(timestamp: TimeInterval) -> String {
    """
    CREATE TABLE cache_metadata (
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      cached_from TEXT,
      cached_through TEXT NOT NULL
    );
    CREATE TABLE daily_metrics (
      date TEXT NOT NULL,
      agent TEXT NOT NULL,
      model TEXT NOT NULL,
      cost_usd TEXT NOT NULL,
      input_tokens INTEGER NOT NULL,
      output_tokens INTEGER NOT NULL,
      cache_creation_tokens INTEGER NOT NULL,
      cache_read_tokens INTEGER NOT NULL
    );
    CREATE TABLE session_metrics (
      timestamp REAL NOT NULL,
      agent TEXT NOT NULL,
      model TEXT NOT NULL,
      cost_usd TEXT NOT NULL,
      input_tokens INTEGER NOT NULL,
      output_tokens INTEGER NOT NULL,
      cache_creation_tokens INTEGER NOT NULL,
      cache_read_tokens INTEGER NOT NULL,
      data_quality TEXT NOT NULL
    );
    INSERT INTO cache_metadata VALUES (\(timestamp), \(timestamp), '2026-07-15', '2026-07-15');
    INSERT INTO daily_metrics VALUES ('2026-07-15', 'codex', 'gpt-test', '4', 10, 2, 0, 0);
    INSERT INTO session_metrics VALUES (\(timestamp), 'codex', 'gpt-test', '4', 10, 2, 0, 0, 'timestamped');
    """
  }
}

@Suite("Historical directory loading regressions")
struct HistoricalDirectoryRegressionTests {
  @Test func requestedHistoricalDayLoadsJSONLDirectoryAndMarksCoverage() async throws {
    let root = try directoryRegressionTemporaryDirectory()
    let eventRoot = root.appendingPathComponent("events", isDirectory: true)
    let projectRoot = eventRoot.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
    let event = [
      #"{"type":"assistant","timestamp":"2026-05-10T01:00:00.000Z","sessionId":"session-1","#,
      #""requestId":"request-1","cwd":"/work/historical","message":{"id":"message-1","#,
      #""role":"assistant","model":"claude-test","usage":{"input_tokens":10,"output_tokens":2,"#,
      #""cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    ].joined()
    try Data(event.utf8).write(to: projectRoot.appendingPathComponent("session.jsonl"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let requested = try #require(ISO8601DateFormatter().date(from: "2026-05-10T00:00:00Z"))
    let runner = HistoricalDirectoryRunner()
    let cache = UsageAggregationCache(
      fileURL: root.appendingPathComponent("aggregates.sqlite3"),
      retentionDays: 365
    )
    let service = SnapshotService(
      stateStore: StateStore(fileURL: root.appendingPathComponent("state.json")),
      client: CCUsageClient(commandRunner: runner, machine: "local"),
      calculator: ResetWindowCalculator(calendar: calendar),
      aggregationCache: cache,
      claudeUsageEventLoader: ClaudeUsageEventLoader(roots: [eventRoot])
    )

    let snapshot = try await service.snapshot(
      now: now,
      earliestDate: requested,
      latestDate: requested
    )

    let eventTimestamp = try #require(
      ISO8601DateFormatter().date(from: "2026-05-10T01:00:00Z")
    )
    #expect(snapshot.dashboardSessions.contains {
      $0.timestamp == eventTimestamp
        && $0.directory == "/work/historical"
        && $0.costUSD == 5
    })
    #expect(await cache.load(now: now)?.directoryCoveredRanges == [
      AggregationCacheRange(since: "2026-05-10", through: "2026-05-10")
    ])
    let dailyCalls = await runner.recordedCalls().filter { $0.first == "daily" }
    #expect(dailyCalls.contains {
      argument(after: "--since", in: $0) == "2026-05-10"
        && argument(after: "--until", in: $0) == "2026-05-10"
    })
  }

  private func argument(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option),
          arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }
}

@Suite("Directory route and inventory regressions")
struct DirectoryRouteRegressionTests {
  @Test func inventoryRefreshesAndBreakdownParametersRemainBackwardCompatible() async throws {
    let root = try directoryRegressionTemporaryDirectory()
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let source = DirectorySnapshotSource(snapshot: routeSnapshot(now: now, directories: ["/work/b", "/work/a", nil]))
    let router = DashboardRouter(
      snapshotProvider: { await source.load() },
      snapshotCacheMaxAgeSeconds: 60,
      assetResolver: StaticAssetResolver(explicitRoot: root),
      directoryNameStore: DashboardDirectoryNameStore(
        fileURL: root.appendingPathComponent("dashboard-state.sqlite3")
      )
    )

    let initial = await router.route(target: "/api/subdirectories")
    let initialPayload = try JSONDecoder().decode(SubdirectoriesResponse.self, from: initial.body)
    #expect(initial.status == 200)
    #expect(initialPayload.machines == [
      MachineSubdirectories(machine: "local", directories: ["/work/a", "/work/b"])
    ])

    let compatibility = await router.route(
      target: "/api/cost-series?range=today&granularity=hourly&directoryBreakdown=false"
    )
    let compatibilityObject = try #require(
      JSONSerialization.jsonObject(with: compatibility.body) as? [String: Any]
    )
    let compatibilityRows = try #require(compatibilityObject["rows"] as? [[String: Any]])
    #expect(compatibility.status == 200)
    #expect(compatibilityRows.allSatisfy { $0["directory"] == nil })

    let duplicate = await router.route(
      target: "/api/cost-series?directoryBreakdown=true&directoryBreakdown=false"
    )
    #expect(duplicate.status == 400)

    await source.replace(with: routeSnapshot(now: now, directories: ["/work/c", "/work/a"]))
    _ = await router.route(target: "/api/refresh")
    let refreshed = await router.route(target: "/api/subdirectories")
    let refreshedPayload = try JSONDecoder().decode(SubdirectoriesResponse.self, from: refreshed.body)
    #expect(refreshedPayload.machines.first?.directories == ["/work/a", "/work/c"])
  }

  @Test func legacyHTTPRoutesApplyDirectoryFiltersToMetricsCostAndBudget() async throws {
    let root = try directoryRegressionTemporaryDirectory()
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let snapshot = routeSnapshot(now: now, directories: ["/work/a", "/work/b", nil])
    let router = DashboardRouter(
      snapshotProvider: { snapshot },
      assetResolver: StaticAssetResolver(explicitRoot: root)
    )
    let filter = "directory=local%3A%2Fwork%2Fa"

    let metrics = await router.route(target: "/api/metrics?range=all&\(filter)")
    let metricsObject = try responseObject(metrics)
    let metricRows = try #require(metricsObject["rows"] as? [[String: Any]])
    let metricTotals = try #require(metricsObject["totals"] as? [String: Any])
    #expect(metrics.status == 200)
    #expect(metricRows.count == 1)
    #expect(metricRows.first?["directory"] as? String == "/work/a")
    #expect((metricTotals["costUSD"] as? NSNumber)?.intValue == 1)

    let cost = await router.route(
      target: "/api/cost-series?range=all&granularity=daily&directoryBreakdown=false&\(filter)"
    )
    let costObject = try responseObject(cost)
    let costRows = try #require(costObject["rows"] as? [[String: Any]])
    #expect(cost.status == 200)
    #expect(costRows.count == 1)
    #expect(costRows.first?["directory"] as? String == "/work/a")
    #expect((costObject["totalUSD"] as? NSNumber)?.intValue == 1)

    let budget = await router.route(target: "/api/budget?\(filter)")
    let budgetObject = try responseObject(budget)
    #expect(budget.status == 200)
    #expect((budgetObject["spentUSD"] as? NSNumber)?.intValue == 1)
  }

  @Test func machineRouterAppliesActiveFiltersAndIgnoresKnownOutOfScopeFilters() async throws {
    let root = try directoryRegressionTemporaryDirectory()
    let paths = AppPaths(
      configFile: root.appendingPathComponent("config/ccusage-gauge/config.json"),
      stateFile: root.appendingPathComponent("state/ccusage-gauge/state.json"),
      aggregationCacheFile: root.appendingPathComponent("cache/ccusage-gauge/aggregates.sqlite3")
    )
    let remote = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "localhost", port: 22, user: "user")
    )
    let registry = try MachineRegistry(sshMachines: [remote])
    let persistence = MachineRegistryStore(fileURL: paths.machinesFile)
    try persistence.save(registry)
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let runner = HistoricalDirectoryRunner()
    let collector = try MachineCollector(registry: registry, store: store) { descriptor in
      SnapshotService(
        stateStore: StateStore(fileURL: paths.stateFile),
        client: CCUsageClient(commandRunner: runner, machine: descriptor.id),
        aggregationCache: nil
      )
    }
    defer { Task { await collector.stop() } }
    let owner = MachineRegistryMutationOwner(
      store: persistence,
      registry: registry,
      runtime: collector
    )
    let router = MachineDashboardRouter(
      store: store,
      collector: collector,
      mutationOwner: owner,
      paths: paths
    )
    let now = Date()
    let localSnapshot = routeSnapshot(
      now: now,
      directories: ["/work/a", "/work/b"],
      machine: "local"
    )
    let remoteSnapshot = routeSnapshot(
      now: now,
      directories: ["/srv/remote"],
      machine: "remote"
    )
    await store.publish(
      machineID: "local",
      snapshot: localSnapshot,
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: now
    )
    await store.publish(
      machineID: "remote",
      snapshot: remoteSnapshot,
      coverageStart: .distantPast,
      revision: 0,
      generation: 0,
      now: now
    )

    let inventory = await router.route(
      target: "/api/subdirectories?machine=all",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let inventoryPayload = try JSONDecoder().decode(SubdirectoriesResponse.self, from: inventory.body)
    #expect(inventory.status == 200)
    #expect(inventoryPayload.machines.first(where: { $0.machine == "remote" })?.directories == [
      "/srv/remote"
    ])

    let stale = await router.route(
      target: "/api/cost-series?range=all&granularity=hourly&machine=local"
        + "&directory=remote%3A%2Fsrv%2Fremote",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let staleObject = try responseObject(stale)
    let staleRows = try #require(staleObject["rows"] as? [[String: Any]])
    #expect(stale.status == 200)
    #expect(staleRows.count == 2)
    #expect((staleObject["totalUSD"] as? NSNumber)?.intValue == 2)

    let filtered = await router.route(
      target: "/api/cost-series?range=all&granularity=daily&machine=local"
        + "&directoryBreakdown=false&directory=local%3A%2Fwork%2Fa",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let filteredObject = try responseObject(filtered)
    let filteredRows = try #require(filteredObject["rows"] as? [[String: Any]])
    #expect(filtered.status == 200)
    #expect(filteredRows.count == 1)
    #expect(filteredRows.first?["directory"] as? String == "/work/a")
    #expect((filteredObject["totalUSD"] as? NSNumber)?.intValue == 1)
  }

  private func routeSnapshot(
    now: Date,
    directories: [String?],
    machine: String = "local"
  ) -> CostSnapshot {
    let sessions = directories.enumerated().map { index, directory in
      CCUsageSessionMetricRecord(
        timestamp: now.addingTimeInterval(TimeInterval(-(index + 1) * 60)),
        agent: "codex",
        model: "gpt-test",
        costUSD: 1,
        inputTokens: 1,
        dataQuality: .timestamped,
        machine: machine,
        directory: directory
      )
    }
    return CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now.addingTimeInterval(-86_400),
      costSinceResetUSD: Decimal(sessions.count),
      budget: BudgetSummary(spentUSD: Decimal(sessions.count), budgetUSD: nil),
      resetCycle: .daily,
      points: [],
      dashboardMetrics: [],
      dashboardSessions: sessions
    )
  }

  private func responseObject(_ response: HTTPResponse) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }
}

private func executeSQLite(at file: URL, sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else {
    if let database { sqlite3_close(database) }
    throw DirectoryRegressionSQLiteError.open
  }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw DirectoryRegressionSQLiteError.execute
  }
}

private func directoryRegressionTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("ccusage-directory-regression-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
