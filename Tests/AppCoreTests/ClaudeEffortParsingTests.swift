import CSQLite
import Foundation
import Testing
@testable import AppCore

private enum ClaudeEffortSQLiteError: Error {
  case open
  case execute
}

@Suite("ClaudeEffortParsingTests")
struct ClaudeEffortParsingTests {
  private let day = "2026-07-16"
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(secondsFromGMT: 0)!
    return value
  }

  @Test func assistantEffortIsNormalizedOntoTheUsageEvent() async throws {
    let root = try claudeEffortTemporaryDirectory()
    try write([assistantLine(request: "r1", extra: #""effort":" High ","#)], to: root)

    let events = try await ClaudeUsageEventLoader(roots: [root]).events(since: nil, until: day, calendar: calendar)

    #expect(events.map(\.effort) == ["high"])
  }

  @Test func perTurnEffortIsUsedWhenEffortIsAbsent() async throws {
    let root = try claudeEffortTemporaryDirectory()
    try write([assistantLine(request: "r1", extra: #""perTurnEffort":"medium","#)], to: root)

    let events = try await ClaudeUsageEventLoader(roots: [root]).events(since: nil, until: day, calendar: calendar)

    #expect(events.map(\.effort) == ["medium"])
  }

  @Test func malformedEffortKeepsTheUsageLineAsUnknownEffort() async throws {
    let root = try claudeEffortTemporaryDirectory()
    try write([
      assistantLine(request: "r1", extra: #""effort":7,"#),
      assistantLine(request: "r2", extra: #""effort":{"level":"high"},"#),
      assistantLine(request: "r3", extra: "")
    ], to: root)

    let events = try await ClaudeUsageEventLoader(roots: [root]).events(since: nil, until: day, calendar: calendar)

    #expect(events.count == 3)
    #expect(events.allSatisfy { $0.effort == nil })
    #expect(events.allSatisfy { $0.model == "claude-test" })
  }

  @Test func localCacheMigratedBeforeClaudeEffortResetsProvenanceOnce() async throws {
    let root = try claudeEffortTemporaryDirectory()
    let file = root.appendingPathComponent("effort-column-local.sqlite3")
    let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
    try executeClaudeEffortSQLite(at: file, sql: effortColumnSchema(timestamp: timestamp))

    let cache = UsageAggregationCache(fileURL: file, retentionDays: 365, machineID: "local")
    let first = try #require(await cache.load(now: timestamp.addingTimeInterval(3_600)))
    #expect(first.directoryCoveredRanges.isEmpty)
    #expect(first.coveredRanges == [AggregationCacheRange(since: "2026-07-15", through: "2026-07-15")])

    let newCoverage = AggregationCacheRange(since: "2026-07-16", through: "2026-07-16")
    try await cache.save(
      metrics: first.metrics,
      sessions: first.sessions,
      cachedFrom: first.cachedFrom,
      cachedThrough: "2026-07-16",
      now: timestamp.addingTimeInterval(7_200),
      coveredRanges: first.coveredRanges + [newCoverage],
      directoryCoveredRanges: [newCoverage]
    )
    let reopened = try #require(
      await UsageAggregationCache(fileURL: file, retentionDays: 365, machineID: "local")
        .load(now: timestamp.addingTimeInterval(7_200))
    )
    #expect(reopened.directoryCoveredRanges == [newCoverage])
  }

  @Test func remoteCacheMigratedBeforeClaudeEffortKeepsProvenance() async throws {
    let root = try claudeEffortTemporaryDirectory()
    let file = root.appendingPathComponent("effort-column-remote.sqlite3")
    let timestamp = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
    try executeClaudeEffortSQLite(at: file, sql: effortColumnSchema(timestamp: timestamp))

    let payload = try #require(
      await UsageAggregationCache(fileURL: file, retentionDays: 365, machineID: "build-host")
        .load(now: timestamp.addingTimeInterval(3_600))
    )

    #expect(payload.directoryCoveredRanges == [AggregationCacheRange(since: "2026-07-15", through: "2026-07-15")])
  }

  private func assistantLine(request: String, extra: String) -> String {
    [
      #"{"type":"assistant","timestamp":"2026-07-16T01:00:00.000Z","sessionId":"session-1","#,
      #""requestId":"\#(request)",\#(extra)"message":{"id":"message-\#(request)","role":"assistant","#,
      #""model":"claude-test","usage":{"input_tokens":10,"output_tokens":2,"#,
      #""cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    ].joined()
  }

  private func write(_ rows: [String], to root: URL) throws {
    try Data((rows.joined(separator: "\n") + "\n").utf8)
      .write(to: root.appendingPathComponent("session.jsonl"))
  }

  /// The schema a 0.3.0 cache has: effort column present, PRAGMA user_version still 0.
  private func effortColumnSchema(timestamp: Date) -> String {
    let instant = timestamp.timeIntervalSince1970
    return """
      CREATE TABLE cache_metadata (
        created_at REAL NOT NULL, updated_at REAL NOT NULL, cached_from TEXT,
        cached_through TEXT NOT NULL, source_configuration_fingerprint TEXT
      );
      CREATE TABLE daily_metrics (
        date TEXT NOT NULL, agent TEXT NOT NULL, model TEXT NOT NULL, cost_usd TEXT NOT NULL,
        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
        cache_creation_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL, directory TEXT
      );
      CREATE TABLE session_metrics (
        timestamp REAL NOT NULL, agent TEXT NOT NULL, model TEXT NOT NULL, cost_usd TEXT NOT NULL,
        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
        cache_creation_tokens INTEGER NOT NULL, cache_read_tokens INTEGER NOT NULL,
        data_quality TEXT NOT NULL, directory TEXT, effort TEXT
      );
      CREATE TABLE coverage_ranges (since_day TEXT NOT NULL, through_day TEXT NOT NULL);
      CREATE TABLE directory_coverage_ranges (since_day TEXT NOT NULL, through_day TEXT NOT NULL);
      INSERT INTO cache_metadata VALUES (\(instant), \(instant), '2026-07-15', '2026-07-15', NULL);
      INSERT INTO daily_metrics VALUES ('2026-07-15', 'claude', 'claude-test', '4', 10, 2, 0, 0, NULL);
      INSERT INTO session_metrics VALUES (
        \(instant), 'claude', 'claude-test', '4', 10, 2, 0, 0, 'timestamped', NULL, NULL
      );
      INSERT INTO coverage_ranges VALUES ('2026-07-15', '2026-07-15');
      INSERT INTO directory_coverage_ranges VALUES ('2026-07-15', '2026-07-15');
      """
  }
}

private func executeClaudeEffortSQLite(at file: URL, sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else {
    if let database { sqlite3_close(database) }
    throw ClaudeEffortSQLiteError.open
  }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw ClaudeEffortSQLiteError.execute
  }
}

private func claudeEffortTemporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("ccusage-claude-effort-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
