import Foundation
import Testing
@testable import AppCore

@Suite("ConfigStoreTests") struct ConfigStoreTests {
  @Test func createsExactDefaultsAndDoesNotRewrite() throws {
    let root = try temporaryDirectory()
    let file = root.appendingPathComponent("config/ccusage-config.json")
    let store = ConfigStore(fileURL: file)
    let value = try store.loadOrCreate()
    #expect(value == AppConfiguration())
    #expect(value.pollIntervalSeconds == 20)
    #expect(value.cacheRetentionDays == 365)
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
  }

  @Test func rejectsInvalidCacheRetention() {
    #expect(throws: ConfigurationError.invalidCacheRetention(0)) {
      try AppConfiguration(cacheRetentionDays: 0).validate()
    }
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
  }

  @Test func ignoresRemovedManualResetFields() async throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    let json = #"{"resetCycle":{"type":"daily"},"lastManualResetAt":"2026-07-16T03:23:33Z"}"#
    try Data(json.utf8).write(to: file)
    let state = try await StateStore(fileURL: file).load()
    #expect(state.resetCycle == .daily)
  }
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
