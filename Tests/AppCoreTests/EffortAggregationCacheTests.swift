import CSQLite
import Foundation
import Testing
@testable import AppCore

private enum EffortCacheSQLiteError: Error {
  case open
  case execute
}

@Suite("EffortAggregationCacheTests")
struct EffortAggregationCacheTests {
  @Test func localLegacyMigrationClearsDirectoryCoverageOnly() async throws {
    let root = try effortCacheTemporaryDirectory()
    let file = root.appendingPathComponent("legacy-local.sqlite3")
    let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
    try executeEffortCacheSQLite(at: file, sql: effortLegacySchema(timestamp: timestamp))
    let cache = UsageAggregationCache(fileURL: file, retentionDays: 365, machineID: "local")

    let payload = try #require(await cache.load(now: timestamp.addingTimeInterval(3_600)))

    #expect(payload.coveredRanges == [AggregationCacheRange(since: "2026-07-15", through: "2026-07-15")])
    #expect(payload.directoryCoveredRanges.isEmpty)
    #expect(payload.metrics == [effortMetric()])
    #expect(payload.sessions.count == 1)
    #expect(payload.sessions.first?.directory == nil)
    #expect(payload.sessions.first?.effort == nil)
  }

  @Test func remoteLegacyMigrationPreservesDirectoryCoverage() async throws {
    let root = try effortCacheTemporaryDirectory()
    let file = root.appendingPathComponent("legacy-remote.sqlite3")
    let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
    try executeEffortCacheSQLite(at: file, sql: effortLegacySchema(timestamp: timestamp))
    let cache = UsageAggregationCache(fileURL: file, retentionDays: 365, machineID: "build-host")

    let payload = try #require(await cache.load(now: timestamp.addingTimeInterval(3_600)))

    #expect(payload.directoryCoveredRanges == [
      AggregationCacheRange(since: "2026-07-15", through: "2026-07-15")
    ])
    #expect(payload.sessions.first?.effort == nil)
  }

  @Test func localMigrationDoesNotClearNewCoverageOnSecondOpen() async throws {
    let root = try effortCacheTemporaryDirectory()
    let file = root.appendingPathComponent("legacy-idempotent.sqlite3")
    let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
    try executeEffortCacheSQLite(at: file, sql: effortLegacySchema(timestamp: timestamp))
    let initialCache = UsageAggregationCache(fileURL: file, retentionDays: 365, machineID: "local")
    let initial = try #require(await initialCache.load(now: timestamp.addingTimeInterval(3_600)))
    let newCoverage = AggregationCacheRange(since: "2026-07-16", through: "2026-07-16")
    try await initialCache.save(
      metrics: initial.metrics,
      sessions: initial.sessions,
      cachedFrom: initial.cachedFrom,
      cachedThrough: "2026-07-16",
      now: timestamp.addingTimeInterval(7_200),
      coveredRanges: initial.coveredRanges + [newCoverage],
      directoryCoveredRanges: [newCoverage]
    )

    let reopened = try #require(
      await UsageAggregationCache(fileURL: file, retentionDays: 365, machineID: "local")
        .load(now: timestamp.addingTimeInterval(7_200))
    )

    #expect(reopened.directoryCoveredRanges == [newCoverage])
  }

  @Test func sessionEffortRoundTripsAndNilEffortRemainsDistinct() async throws {
    let root = try effortCacheTemporaryDirectory()
    let file = root.appendingPathComponent("effort.sqlite3")
    let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
    let rows = [effortSession(timestamp: timestamp, effort: "high"), effortSession(timestamp: timestamp, effort: nil)]
    let cache = UsageAggregationCache(fileURL: file, retentionDays: 365)
    try await cache.save(
      metrics: [effortMetric()],
      sessions: rows,
      cachedFrom: "2026-07-15",
      cachedThrough: "2026-07-15",
      now: timestamp
    )

    let payload = try #require(
      await UsageAggregationCache(fileURL: file, retentionDays: 365).load(now: timestamp)
    )

    #expect(payload.sessions.count == 2)
    #expect(Set(payload.sessions.compactMap(\.effort)) == ["high"])
    #expect(payload.sessions.filter { $0.effort == nil }.count == 1)
  }

  private func effortLegacySchema(timestamp: Date) -> String {
    let instant = timestamp.timeIntervalSince1970
    return """
      CREATE TABLE cache_metadata (
        created_at REAL NOT NULL, updated_at REAL NOT NULL, cached_from TEXT,
        cached_through TEXT NOT NULL
      );
      CREATE TABLE daily_metrics (
        date TEXT NOT NULL, agent TEXT NOT NULL, model TEXT NOT NULL, cost_usd TEXT NOT NULL,
        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
        cache_creation_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL
      );
      CREATE TABLE session_metrics (
        timestamp REAL NOT NULL, agent TEXT NOT NULL, model TEXT NOT NULL, cost_usd TEXT NOT NULL,
        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
        cache_creation_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL,
        data_quality TEXT NOT NULL
      );
      CREATE TABLE coverage_ranges (since_day TEXT NOT NULL, through_day TEXT NOT NULL);
      CREATE TABLE directory_coverage_ranges (since_day TEXT NOT NULL, through_day TEXT NOT NULL);
      INSERT INTO cache_metadata VALUES (\(instant), \(instant), '2026-07-15', '2026-07-15');
      INSERT INTO daily_metrics VALUES ('2026-07-15', 'codex', 'gpt-test', '4', 10, 2, 0, 0);
      INSERT INTO session_metrics VALUES (\(instant), 'codex', 'gpt-test', '4', 10, 2, 0, 0, 'timestamped');
      INSERT INTO coverage_ranges VALUES ('2026-07-15', '2026-07-15');
      INSERT INTO directory_coverage_ranges VALUES ('2026-07-15', '2026-07-15');
      """
  }

  private func effortMetric() -> CCUsageMetricRecord {
    CCUsageMetricRecord(
      date: "2026-07-15",
      agent: "codex",
      model: "gpt-test",
      costUSD: 4,
      inputTokens: 10,
      outputTokens: 2,
      cacheCreationTokens: 0,
      cacheReadTokens: 0
    )
  }

  private func effortSession(timestamp: Date, effort: String?) -> CCUsageSessionMetricRecord {
    CCUsageSessionMetricRecord(
      timestamp: timestamp,
      agent: "codex",
      model: "gpt-test",
      costUSD: 4,
      inputTokens: 10,
      outputTokens: 2,
      dataQuality: .timestamped,
      effort: effort
    )
  }
}

private func executeEffortCacheSQLite(at file: URL, sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else {
    if let database { sqlite3_close(database) }
    throw EffortCacheSQLiteError.open
  }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw EffortCacheSQLiteError.execute
  }
}

private func effortCacheTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("ccusage-effort-cache-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
