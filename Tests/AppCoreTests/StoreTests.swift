import Foundation
import Testing
@testable import AppCore

@Suite("ConfigStoreTests") struct ConfigStoreTests {
  @Test func productionPathsUseDedicatedDashboardSQLiteFile() {
    let paths = AppPaths.production(environment: ["HOME": "/tmp/ccusage-gauge-test-home"])

    #expect(paths.dashboardStateFile.path == "/tmp/ccusage-gauge-test-home/.cache/ccusage-gauge/dashboard-state.sqlite3")
    #expect(paths.dashboardStateFile != paths.aggregationCacheFile)
  }

  @Test func createsExactDefaultsAndDoesNotRewrite() throws {
    let root = try temporaryDirectory()
    let file = root.appendingPathComponent("config/ccusage-config.json")
    let store = ConfigStore(fileURL: file)
    let value = try store.loadOrCreate()
    #expect(value == AppConfiguration())
    #expect(value.pollIntervalSeconds == 20)
    #expect(value.cacheRetentionDays == 365)
    #expect(value.remoteRetryCount == 3)
    #expect(value.remoteTimeoutSeconds == 15)
    #expect(value.chartColors == ChartColorConfiguration())
    let original = try Data(contentsOf: file)
    _ = try store.loadOrCreate()
    #expect(try Data(contentsOf: file) == original)
  }

  @Test func validatesWithoutReplacingInvalidContent() throws {
    let root = try temporaryDirectory()
    let file = root.appendingPathComponent("config.json")
    let bytes = Data("{\"ccusagePath\":null,\"defaultResetTerm\":\"daily\",\"dashboardPort\":0,\"dashboardAutostart\":true,\"pollIntervalSeconds\":60}".utf8)
    try bytes.write(to: file)
    #expect(throws: ConfigurationError.invalidPort(0)) { try ConfigStore(fileURL: file).loadOrCreate() }
    #expect(try Data(contentsOf: file) == bytes)
  }

  @Test func decodesLegacyConfigWithDefaultCacheRetention() throws {
    let json = #"{"ccusagePath":null,"defaultResetTerm":"daily","dashboardPort":18081,"dashboardAutostart":true,"pollIntervalSeconds":20}"#
    let value = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
    #expect(value.cacheRetentionDays == 365)
    #expect(value.remoteRetryCount == 3)
    #expect(value.remoteTimeoutSeconds == 15)
    #expect(value.chartColors == ChartColorConfiguration())
  }

  @Test func rejectsInvalidCacheRetention() {
    #expect(throws: ConfigurationError.invalidCacheRetention(0)) {
      try AppConfiguration(cacheRetentionDays: 0).validate()
    }
  }

  @Test func rejectsInvalidRemoteRetryAndTimeoutSettings() {
    #expect(throws: ConfigurationError.invalidRemoteRetryCount(11)) {
      try AppConfiguration(remoteRetryCount: 11).validate()
    }
    #expect(throws: ConfigurationError.invalidRemoteTimeout(0)) {
      try AppConfiguration(remoteTimeoutSeconds: 0).validate()
    }
  }

  @Test func decodesAndValidatesChartColorOverrides() throws {
    let json = ##"""
      {"ccusagePath":null,"defaultResetTerm":"daily","dashboardPort":18081,"dashboardAutostart":true,
      "pollIntervalSeconds":20,"chartColors":{"light":{"machines":{"local":"#123ABC"}},
      "dark":{"models":{"gpt-next":"#abcdef"}}}}
      """##
    let value = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))

    try value.validate()
    #expect(value.chartColors.light.machines["local"] == "#123ABC")
    #expect(value.chartColors.dark.models["gpt-next"] == "#abcdef")
  }

  @Test func rejectsInvalidChartColorOverrides() {
    #expect(throws: ConfigurationError.invalidChartColor(section: "dark.models", key: "gpt", value: "red")) {
      try AppConfiguration(chartColors: ChartColorConfiguration(
        dark: ChartColorSchemeConfiguration(models: ["gpt": "red"])
      )).validate()
    }
  }

  @Test func allowsConfiguringOnlyOneChartColorNamespace() throws {
    let colors = try JSONDecoder().decode(
      ChartColorSchemeConfiguration.self,
      from: Data(##"{"models":{"future-model":"#123ABC"}}"##.utf8)
    )

    #expect(colors.machines.isEmpty)
    #expect(colors.models == ["future-model": "#123ABC"])
  }

  @Test func migratesLegacyFlatChartColorsToBothSchemes() throws {
    let colors = try JSONDecoder().decode(
      ChartColorConfiguration.self,
      from: Data(##"{"machines":{"local":"#123ABC"},"models":{"gpt":"#abcdef"}}"##.utf8)
    )

    #expect(colors.light == colors.dark)
    #expect(colors.light.machines == ["local": "#123ABC"])
    #expect(colors.light.models == ["gpt": "#abcdef"])
  }
}

@Suite("UsageAggregationCacheTests") struct UsageAggregationCacheTests {
  @Test func roundTripsAndPurgesFromCreationDate() async throws {
    let file = try temporaryDirectory().appendingPathComponent("cache/aggregates.sqlite3")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let cache = UsageAggregationCache(fileURL: file, retentionDays: 365)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let metrics = [CCUsageMetricRecord(
      date: "2026-07-15",
      agent: "codex",
      model: "gpt",
      costUSD: 1,
      inputTokens: 2,
      outputTokens: 3,
      cacheCreationTokens: 4,
      cacheReadTokens: 5
    )]
    let sessions = [CCUsageSessionMetricRecord(
      timestamp: createdAt,
      agent: "codex",
      model: "gpt",
      costUSD: 1,
      inputTokens: 2,
      dataQuality: .timestamped
    )]
    try await cache.save(
      metrics: metrics,
      sessions: sessions,
      cachedFrom: "2026-06-01",
      cachedThrough: "2026-07-15",
      now: createdAt
    )
    let header = Data(try Data(contentsOf: file).prefix(16))
    #expect(String(data: header, encoding: .utf8) == "SQLite format 3\0")
    #expect(await cache.load(now: createdAt.addingTimeInterval(364 * 86_400))?.metrics == metrics)
    #expect(await cache.load(now: createdAt.addingTimeInterval(364 * 86_400))?.sessions == sessions)
    #expect(await cache.load(now: createdAt.addingTimeInterval(364 * 86_400))?.cachedFrom == "2026-06-01")
    #expect(await cache.load(now: createdAt.addingTimeInterval(365 * 86_400)) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }
}

@Suite("StateStoreTests") struct StateStoreTests {
  @Test func roundTripsEveryField() async throws {
    let file = try temporaryDirectory().appendingPathComponent("state/state.json")
    let store = StateStore(fileURL: file)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let state = AppState(
      budgetUSD: Decimal(string: "42.50"),
      budgetMachineIDs: ["local", "build-host"],
      resetCycle: .customHours(12),
      baseline: ResetBaseline(
        scheduledBoundaryAt: now.addingTimeInterval(-3600),
        activeBoundaryAt: now.addingTimeInterval(-3600), cycle: .customHours(12),
        calendarIdentifier: "gregorian", timeZoneIdentifier: "UTC", computedAt: now
      ),
      refreshIntervalSeconds: 15
    )
    try await store.save(state)
    #expect(try await store.load() == state)
  }

  @Test func rejectsInvalidRefreshInterval() async throws {
    let store = StateStore(fileURL: try temporaryDirectory().appendingPathComponent("state.json"))
    await #expect(throws: StateError.invalidRefreshInterval(0)) {
      try await store.save(AppState(refreshIntervalSeconds: 0))
    }
  }

  @Test func corruptStateIsReportedAndNotReplaced() async throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    let bytes = Data("not json".utf8)
    try bytes.write(to: file)
    await #expect(throws: (any Error).self) { try await StateStore(fileURL: file).load() }
    #expect(try Data(contentsOf: file) == bytes)
  }

  @Test func decodesStateCreatedBeforeRefreshIntervalOverride() async throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    try Data(#"{"resetCycle":{"type":"daily"}}"#.utf8).write(to: file)
    let state = try await StateStore(fileURL: file).load()
    #expect(state.refreshIntervalSeconds == nil)
    #expect(state.budgetMachineIDs.isEmpty)
  }

  @Test func emptyBudgetMachineSelectionRepresentsAllEnabledMachines() async throws {
    let store = StateStore(fileURL: try temporaryDirectory().appendingPathComponent("state.json"))
    try await store.save(AppState(budgetMachineIDs: []))
    #expect(try await store.load().budgetMachineIDs.isEmpty)
  }

  @Test func rejectsDuplicateBudgetMachineSelection() async throws {
    let store = StateStore(fileURL: try temporaryDirectory().appendingPathComponent("state.json"))
    await #expect(throws: StateError.invalidBudgetMachines) {
      try await store.save(AppState(budgetMachineIDs: ["local", "local"]))
    }
  }

  @Test func ignoresRemovedManualResetFields() async throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    let json = #"{"resetCycle":{"type":"daily"},"lastManualResetAt":"2026-07-16T03:23:33Z"}"#
    try Data(json.utf8).write(to: file)
    let state = try await StateStore(fileURL: file).load()
    #expect(state.resetCycle == .daily)
  }
}

@Suite("DashboardStateStoreTests") struct DashboardStateStoreTests {
  @Test func roundTripsStateInDedicatedSQLiteFile() async throws {
    let file = try temporaryDirectory().appendingPathComponent("cache/dashboard-state.sqlite3")
    let store = DashboardStateStore(fileURL: file)
    let state = DashboardUIState(
      range: "custom",
      customStart: "2026-07-01",
      customEnd: "2026-07-17",
      selectedModels: ["gpt-5"],
      selectedAgents: ["codex"],
      selectedMachines: ["local", "build-host"],
      granularity: "6hour",
      chartMetric: "totalTokens",
      stackBy: "machine"
    )

    try await store.save(state)

    #expect(try await store.load() == state)
    let header = Data(try Data(contentsOf: file).prefix(16))
    #expect(String(data: header, encoding: .utf8) == "SQLite format 3\0")
  }

  @Test func decodesStateSavedBeforeMachineFiltersWereAdded() throws {
    let data = Data(#"{"range":"week","customStart":"2026-07-01","customEnd":"2026-07-17","selectedModels":["gpt-5"],"selectedAgents":["codex"],"granularity":"daily","chartMetric":"inputTokens"}"#.utf8)

    let state = try JSONDecoder().decode(DashboardUIState.self, from: data)

    #expect(state.selectedMachines.isEmpty)
    #expect(state.stackBy == "model")
  }

  @Test func rejectsInvalidStateWithoutCreatingDatabase() async throws {
    let file = try temporaryDirectory().appendingPathComponent("cache/dashboard-state.sqlite3")
    let store = DashboardStateStore(fileURL: file)
    let state = DashboardUIState(
      range: "unknown",
      customStart: "2026-07-01",
      customEnd: "2026-07-17",
      selectedModels: [],
      selectedAgents: [],
      granularity: "hourly",
      chartMetric: "costUSD"
    )

    await #expect(throws: DashboardStateError.invalidState) { try await store.save(state) }
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
