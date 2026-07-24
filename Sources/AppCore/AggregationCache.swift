import Foundation
import CSQLite

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct CacheMetadata {
  let createdAt: Date
  let updatedAt: Date
  let cachedFrom: String?
  let cachedThrough: String
}

public struct AggregationCachePayload: Equatable, Sendable {
  public let createdAt: Date
  public let updatedAt: Date
  public let cachedFrom: String
  public let cachedThrough: String
  public let metrics: [CCUsageMetricRecord]
  public let sessions: [CCUsageSessionMetricRecord]
  public let coveredRanges: [AggregationCacheRange]

  public init(
    createdAt: Date,
    updatedAt: Date,
    cachedFrom: String,
    cachedThrough: String,
    metrics: [CCUsageMetricRecord],
    sessions: [CCUsageSessionMetricRecord],
    coveredRanges: [AggregationCacheRange]? = nil
  ) {
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.cachedFrom = cachedFrom
    self.cachedThrough = cachedThrough
    self.metrics = metrics
    self.sessions = sessions
    self.coveredRanges = coveredRanges ?? [AggregationCacheRange(since: cachedFrom, through: cachedThrough)]
  }
}

public struct AggregationCacheRange: Codable, Equatable, Hashable, Sendable {
  public let since: String
  public let through: String

  public init(since: String, through: String) {
    self.since = since
    self.through = through
  }
}

public struct AggregationCacheJob: Equatable, Hashable, Sendable {
  public let since: String
  public let through: String

  public init(since: String, through: String) {
    self.since = since
    self.through = through
  }
}

public actor UsageAggregationCache {
  public let fileURL: URL
  public let retentionDays: Int
  public let machineID: String
  private let fileManager: FileManager
  private var memoryPayload: AggregationCachePayload?

  public init(
    fileURL: URL,
    retentionDays: Int = AppConfiguration.defaultCacheRetentionDays,
    machineID: String = "local",
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.retentionDays = retentionDays
    self.machineID = machineID
    self.fileManager = fileManager
  }

  public func load(now: Date = Date()) -> AggregationCachePayload? {
    guard retentionDays > 0 else { return nil }
    if let memoryPayload {
      guard isRetained(memoryPayload, now: now) else {
        purge()
        return nil
      }
      return memoryPayload
    }
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    do {
      let payload = try readDatabase()
      guard isRetained(payload, now: now) else {
        purge()
        return nil
      }
      memoryPayload = payload
      return payload
    } catch {
      purge()
      return nil
    }
  }

  public func save(
    metrics: [CCUsageMetricRecord],
    sessions: [CCUsageSessionMetricRecord],
    cachedFrom: String,
    cachedThrough: String,
    createdAt: Date? = nil,
    now: Date = Date(),
    coveredRanges: [AggregationCacheRange]? = nil
  ) throws {
    let payload = AggregationCachePayload(
      createdAt: createdAt ?? now,
      updatedAt: now,
      cachedFrom: cachedFrom,
      cachedThrough: cachedThrough,
      metrics: metrics,
      sessions: sessions,
      coveredRanges: coveredRanges
    )
    try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileURL.deletingLastPathComponent().path)
    try writeDatabase(payload)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    memoryPayload = payload
  }

  public func merge(
    metrics: [CCUsageMetricRecord],
    sessions: [CCUsageSessionMetricRecord],
    coveredRange: AggregationCacheRange,
    calendar: Calendar = .current,
    now: Date = Date()
  ) throws {
    let current = load(now: now)
    let retainedMetrics = (current?.metrics ?? []).filter {
      $0.date < coveredRange.since || $0.date > coveredRange.through
    }
    let retainedSessions = (current?.sessions ?? []).filter {
      let day = Self.dayString($0.timestamp, calendar: calendar)
      return day < coveredRange.since || day > coveredRange.through
    }
    let ranges = Self.normalizedRanges((current?.coveredRanges ?? []) + [coveredRange])
    guard let cachedFrom = ranges.map(\.since).min(),
          let cachedThrough = ranges.map(\.through).max() else { return }
    try save(
      metrics: (retainedMetrics + metrics).sorted(by: metricsInIncreasingOrder),
      sessions: (retainedSessions + sessions).sorted(by: sessionsInIncreasingOrder),
      cachedFrom: cachedFrom,
      cachedThrough: cachedThrough,
      createdAt: current?.createdAt,
      now: now,
      coveredRanges: ranges
    )
  }

  public func purge() {
    memoryPayload = nil
    for suffix in ["", "-journal", "-shm", "-wal"] {
      try? fileManager.removeItem(atPath: fileURL.path + suffix)
    }
  }

  public func beginJob(_ job: AggregationCacheJob) throws {
    guard job.since <= job.through else { return }
    try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    let statement = try prepare(
      "INSERT OR REPLACE INTO pending_range_jobs(since_day, through_day) VALUES (?, ?)",
      in: database
    )
    defer { sqlite3_finalize(statement) }
    try bind(job.since, to: 1, in: statement)
    try bind(job.through, to: 2, in: statement)
    try stepDone(statement)
  }

  public func finishJob(_ job: AggregationCacheJob) throws {
    guard fileManager.fileExists(atPath: fileURL.path) else { return }
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    let statement = try prepare(
      "DELETE FROM pending_range_jobs WHERE since_day = ? AND through_day = ?",
      in: database
    )
    defer { sqlite3_finalize(statement) }
    try bind(job.since, to: 1, in: statement)
    try bind(job.through, to: 2, in: statement)
    try stepDone(statement)
  }

  public func pendingJobs() throws -> [AggregationCacheJob] {
    guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    let statement = try prepare(
      "SELECT since_day, through_day FROM pending_range_jobs ORDER BY since_day, through_day",
      in: database
    )
    defer { sqlite3_finalize(statement) }
    var jobs: [AggregationCacheJob] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      jobs.append(AggregationCacheJob(
        since: try text(statement, column: 0),
        through: try text(statement, column: 1)
      ))
    }
    return jobs
  }

  private func readDatabase() throws -> AggregationCachePayload {
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    let metadata = try readMetadata(from: database)
    let metrics = try readMetrics(from: database)
    let sessions = try readSessions(from: database)
    return AggregationCachePayload(
      createdAt: metadata.createdAt,
      updatedAt: metadata.updatedAt,
      cachedFrom: metadata.cachedFrom ?? metrics.map(\.date).min() ?? metadata.cachedThrough,
      cachedThrough: metadata.cachedThrough,
      metrics: metrics,
      sessions: sessions,
      coveredRanges: try readCoveredRanges(from: database, fallback: metadata)
    )
  }

  private func writeDatabase(_ payload: AggregationCachePayload) throws {
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try execute("BEGIN IMMEDIATE", in: database)
    do {
      try execute(
        "DELETE FROM cache_metadata; DELETE FROM daily_metrics; DELETE FROM session_metrics; DELETE FROM coverage_ranges",
        in: database
      )
      try insertMetadata(payload, into: database)
      try insertMetrics(payload.metrics, into: database)
      try insertSessions(payload.sessions, into: database)
      try insertCoveredRanges(payload.coveredRanges, into: database)
      try execute("COMMIT", in: database)
    } catch {
      try? execute("ROLLBACK", in: database)
      throw error
    }
  }

  private func openDatabase() throws -> OpaquePointer {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
      if let database { sqlite3_close(database) }
      throw AggregationCacheError.databaseUnavailable
    }
    return database
  }

  private func createSchema(in database: OpaquePointer) throws {
    try execute("""
      PRAGMA journal_mode = DELETE;
      PRAGMA synchronous = NORMAL;
      CREATE TABLE IF NOT EXISTS cache_metadata (
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        cached_from TEXT,
        cached_through TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS daily_metrics (
        date TEXT NOT NULL,
        agent TEXT NOT NULL,
        model TEXT NOT NULL,
        cost_usd TEXT NOT NULL,
        input_tokens INTEGER NOT NULL,
        output_tokens INTEGER NOT NULL,
        cache_creation_tokens INTEGER NOT NULL,
        cache_read_tokens INTEGER NOT NULL
      );
      CREATE TABLE IF NOT EXISTS session_metrics (
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
      CREATE INDEX IF NOT EXISTS daily_metrics_date_idx ON daily_metrics(date);
      CREATE INDEX IF NOT EXISTS session_metrics_timestamp_idx ON session_metrics(timestamp);
      CREATE TABLE IF NOT EXISTS coverage_ranges (
        since_day TEXT NOT NULL,
        through_day TEXT NOT NULL,
        PRIMARY KEY(since_day, through_day)
      );
      CREATE TABLE IF NOT EXISTS pending_range_jobs (
        since_day TEXT NOT NULL,
        through_day TEXT NOT NULL,
        PRIMARY KEY(since_day, through_day)
      );
      """, in: database)
    if try !hasColumn("cached_from", in: "cache_metadata", database: database) {
      try execute("ALTER TABLE cache_metadata ADD COLUMN cached_from TEXT", in: database)
    }
  }

  private func readCoveredRanges(
    from database: OpaquePointer,
    fallback metadata: CacheMetadata
  ) throws -> [AggregationCacheRange] {
    let statement = try prepare(
      "SELECT since_day, through_day FROM coverage_ranges ORDER BY since_day, through_day",
      in: database
    )
    defer { sqlite3_finalize(statement) }
    var ranges: [AggregationCacheRange] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      ranges.append(AggregationCacheRange(
        since: try text(statement, column: 0),
        through: try text(statement, column: 1)
      ))
    }
    if ranges.isEmpty, let cachedFrom = metadata.cachedFrom {
      return [AggregationCacheRange(since: cachedFrom, through: metadata.cachedThrough)]
    }
    return Self.normalizedRanges(ranges)
  }

  private func readMetadata(from database: OpaquePointer) throws -> CacheMetadata {
    let statement = try prepare(
      "SELECT created_at, updated_at, cached_from, cached_through FROM cache_metadata LIMIT 1",
      in: database
    )
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw AggregationCacheError.invalidDatabase }
    return CacheMetadata(
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
      cachedFrom: optionalText(statement, column: 2),
      cachedThrough: try text(statement, column: 3)
    )
  }

  private func readMetrics(from database: OpaquePointer) throws -> [CCUsageMetricRecord] {
    let statement = try prepare("""
      SELECT date, agent, model, cost_usd, input_tokens, output_tokens,
             cache_creation_tokens, cache_read_tokens
      FROM daily_metrics ORDER BY date, agent, model
      """, in: database)
    defer { sqlite3_finalize(statement) }
    var rows: [CCUsageMetricRecord] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let cost = Decimal(string: try text(statement, column: 3)) else {
        throw AggregationCacheError.invalidDatabase
      }
      rows.append(CCUsageMetricRecord(
        date: try text(statement, column: 0),
        agent: try text(statement, column: 1),
        model: try text(statement, column: 2),
        costUSD: cost,
        inputTokens: Int(sqlite3_column_int64(statement, 4)),
        outputTokens: Int(sqlite3_column_int64(statement, 5)),
        cacheCreationTokens: Int(sqlite3_column_int64(statement, 6)),
        cacheReadTokens: Int(sqlite3_column_int64(statement, 7)),
        machine: machineID
      ))
    }
    return rows
  }

  private func readSessions(from database: OpaquePointer) throws -> [CCUsageSessionMetricRecord] {
    let statement = try prepare("""
      SELECT timestamp, agent, model, cost_usd, input_tokens, output_tokens,
             cache_creation_tokens, cache_read_tokens, data_quality
      FROM session_metrics ORDER BY timestamp, agent, model
      """, in: database)
    defer { sqlite3_finalize(statement) }
    var rows: [CCUsageSessionMetricRecord] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let cost = Decimal(string: try text(statement, column: 3)) else {
        throw AggregationCacheError.invalidDatabase
      }
      guard let dataQuality = UsageDataQuality(rawValue: try text(statement, column: 8)) else {
        throw AggregationCacheError.invalidDatabase
      }
      rows.append(CCUsageSessionMetricRecord(
        timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
        agent: try text(statement, column: 1),
        model: try text(statement, column: 2),
        costUSD: cost,
        inputTokens: Int(sqlite3_column_int64(statement, 4)),
        outputTokens: Int(sqlite3_column_int64(statement, 5)),
        cacheCreationTokens: Int(sqlite3_column_int64(statement, 6)),
        cacheReadTokens: Int(sqlite3_column_int64(statement, 7)),
        dataQuality: dataQuality,
        machine: machineID
      ))
    }
    return rows
  }

  private func insertMetadata(_ payload: AggregationCachePayload, into database: OpaquePointer) throws {
    let statement = try prepare(
      "INSERT INTO cache_metadata(created_at, updated_at, cached_from, cached_through) VALUES (?, ?, ?, ?)",
      in: database
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, payload.createdAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 2, payload.updatedAt.timeIntervalSince1970)
    try bind(payload.cachedFrom, to: 3, in: statement)
    try bind(payload.cachedThrough, to: 4, in: statement)
    try stepDone(statement)
  }

  private func insertMetrics(_ metrics: [CCUsageMetricRecord], into database: OpaquePointer) throws {
    let statement = try prepare("""
      INSERT INTO daily_metrics(
        date, agent, model, cost_usd, input_tokens, output_tokens,
        cache_creation_tokens, cache_read_tokens
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """, in: database)
    defer { sqlite3_finalize(statement) }
    for row in metrics {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      try bind(row.date, to: 1, in: statement)
      try bind(row.agent, to: 2, in: statement)
      try bind(row.model, to: 3, in: statement)
      try bind(decimalText(row.costUSD), to: 4, in: statement)
      sqlite3_bind_int64(statement, 5, sqlite3_int64(row.inputTokens))
      sqlite3_bind_int64(statement, 6, sqlite3_int64(row.outputTokens))
      sqlite3_bind_int64(statement, 7, sqlite3_int64(row.cacheCreationTokens))
      sqlite3_bind_int64(statement, 8, sqlite3_int64(row.cacheReadTokens))
      try stepDone(statement)
    }
  }

  private func insertSessions(_ sessions: [CCUsageSessionMetricRecord], into database: OpaquePointer) throws {
    let statement = try prepare("""
      INSERT INTO session_metrics(
        timestamp, agent, model, cost_usd, input_tokens, output_tokens,
        cache_creation_tokens, cache_read_tokens, data_quality
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      """, in: database)
    defer { sqlite3_finalize(statement) }
    for row in sessions {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      sqlite3_bind_double(statement, 1, row.timestamp.timeIntervalSince1970)
      try bind(row.agent, to: 2, in: statement)
      try bind(row.model, to: 3, in: statement)
      try bind(decimalText(row.costUSD), to: 4, in: statement)
      sqlite3_bind_int64(statement, 5, sqlite3_int64(row.inputTokens))
      sqlite3_bind_int64(statement, 6, sqlite3_int64(row.outputTokens))
      sqlite3_bind_int64(statement, 7, sqlite3_int64(row.cacheCreationTokens))
      sqlite3_bind_int64(statement, 8, sqlite3_int64(row.cacheReadTokens))
      try bind(row.dataQuality.rawValue, to: 9, in: statement)
      try stepDone(statement)
    }
  }

  private func insertCoveredRanges(
    _ ranges: [AggregationCacheRange],
    into database: OpaquePointer
  ) throws {
    let statement = try prepare(
      "INSERT INTO coverage_ranges(since_day, through_day) VALUES (?, ?)",
      in: database
    )
    defer { sqlite3_finalize(statement) }
    for range in Self.normalizedRanges(ranges) {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      try bind(range.since, to: 1, in: statement)
      try bind(range.through, to: 2, in: statement)
      try stepDone(statement)
    }
  }

  private func execute(_ sql: String, in database: OpaquePointer) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw AggregationCacheError.invalidDatabase
    }
  }

  private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { throw AggregationCacheError.invalidDatabase }
    return statement
  }

  private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
    guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
      throw AggregationCacheError.invalidDatabase
    }
  }

  private func text(_ statement: OpaquePointer, column: Int32) throws -> String {
    guard let value = sqlite3_column_text(statement, column) else {
      throw AggregationCacheError.invalidDatabase
    }
    return String(cString: value)
  }

  private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard let value = sqlite3_column_text(statement, column) else { return nil }
    return String(cString: value)
  }

  private func hasColumn(_ column: String, in table: String, database: OpaquePointer) throws -> Bool {
    let statement = try prepare("PRAGMA table_info(\(table))", in: database)
    defer { sqlite3_finalize(statement) }
    while sqlite3_step(statement) == SQLITE_ROW {
      if optionalText(statement, column: 1) == column { return true }
    }
    return false
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw AggregationCacheError.invalidDatabase }
  }

  private func decimalText(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }

  private func isRetained(_ payload: AggregationCachePayload, now: Date) -> Bool {
    now.timeIntervalSince(payload.createdAt) < TimeInterval(retentionDays) * 86_400
  }

  private static func normalizedRanges(_ ranges: [AggregationCacheRange]) -> [AggregationCacheRange] {
    let valid = ranges.filter { $0.since <= $0.through }.sorted {
      ($0.since, $0.through) < ($1.since, $1.through)
    }
    var result: [AggregationCacheRange] = []
    let calendar = Calendar(identifier: .gregorian)
    for range in valid {
      guard let previous = result.last else {
        result.append(range)
        continue
      }
      let adjacent = day(after: previous.through, calendar: calendar).map { $0 >= range.since } ?? false
      if range.since <= previous.through || adjacent {
        result[result.count - 1] = AggregationCacheRange(
          since: previous.since,
          through: max(previous.through, range.through)
        )
      } else {
        result.append(range)
      }
    }
    return result
  }

  private static func day(after value: String, calendar: Calendar) -> String? {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value),
          let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
    return formatter.string(from: next)
  }

  private static func dayString(_ date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

}

public enum AggregationCacheError: Error, Sendable {
  case databaseUnavailable
  case invalidDatabase
}
