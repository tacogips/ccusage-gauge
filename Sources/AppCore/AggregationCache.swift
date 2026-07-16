import Foundation
import CSQLite

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct CacheMetadata {
  let createdAt: Date
  let updatedAt: Date
  let cachedThrough: String
}

public struct AggregationCachePayload: Equatable, Sendable {
  public let createdAt: Date
  public let updatedAt: Date
  public let cachedThrough: String
  public let metrics: [CCUsageMetricRecord]
  public let sessions: [CCUsageSessionMetricRecord]

  public init(
    createdAt: Date,
    updatedAt: Date,
    cachedThrough: String,
    metrics: [CCUsageMetricRecord],
    sessions: [CCUsageSessionMetricRecord]
  ) {
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.cachedThrough = cachedThrough
    self.metrics = metrics
    self.sessions = sessions
  }
}

public actor UsageAggregationCache {
  public let fileURL: URL
  public let retentionDays: Int
  private let fileManager: FileManager
  private var memoryPayload: AggregationCachePayload?

  public init(
    fileURL: URL,
    retentionDays: Int = AppConfiguration.defaultCacheRetentionDays,
    fileManager: FileManager = .default
  ) {
    self.fileURL = fileURL
    self.retentionDays = retentionDays
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
    cachedThrough: String,
    createdAt: Date? = nil,
    now: Date = Date()
  ) throws {
    let payload = AggregationCachePayload(
      createdAt: createdAt ?? now,
      updatedAt: now,
      cachedThrough: cachedThrough,
      metrics: metrics,
      sessions: sessions
    )
    try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeDatabase(payload)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    memoryPayload = payload
  }

  public func purge() {
    memoryPayload = nil
    for suffix in ["", "-journal", "-shm", "-wal"] {
      try? fileManager.removeItem(atPath: fileURL.path + suffix)
    }
  }

  private func readDatabase() throws -> AggregationCachePayload {
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    let metadata = try readMetadata(from: database)
    return AggregationCachePayload(
      createdAt: metadata.createdAt,
      updatedAt: metadata.updatedAt,
      cachedThrough: metadata.cachedThrough,
      metrics: try readMetrics(from: database),
      sessions: try readSessions(from: database)
    )
  }

  private func writeDatabase(_ payload: AggregationCachePayload) throws {
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try execute("BEGIN IMMEDIATE", in: database)
    do {
      try execute("DELETE FROM cache_metadata; DELETE FROM daily_metrics; DELETE FROM session_metrics", in: database)
      try insertMetadata(payload, into: database)
      try insertMetrics(payload.metrics, into: database)
      try insertSessions(payload.sessions, into: database)
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
      """, in: database)
  }

  private func readMetadata(from database: OpaquePointer) throws -> CacheMetadata {
    let statement = try prepare("SELECT created_at, updated_at, cached_through FROM cache_metadata LIMIT 1", in: database)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw AggregationCacheError.invalidDatabase }
    return CacheMetadata(
      createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
      updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
      cachedThrough: try text(statement, column: 2)
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
        cacheReadTokens: Int(sqlite3_column_int64(statement, 7))
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
        dataQuality: dataQuality
      ))
    }
    return rows
  }

  private func insertMetadata(_ payload: AggregationCachePayload, into database: OpaquePointer) throws {
    let statement = try prepare(
      "INSERT INTO cache_metadata(created_at, updated_at, cached_through) VALUES (?, ?, ?)",
      in: database
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, payload.createdAt.timeIntervalSince1970)
    sqlite3_bind_double(statement, 2, payload.updatedAt.timeIntervalSince1970)
    try bind(payload.cachedThrough, to: 3, in: statement)
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

  private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw AggregationCacheError.invalidDatabase }
  }

  private func decimalText(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }

  private func isRetained(_ payload: AggregationCachePayload, now: Date) -> Bool {
    now.timeIntervalSince(payload.createdAt) < TimeInterval(retentionDays) * 86_400
  }

}

public enum AggregationCacheError: Error, Sendable {
  case databaseUnavailable
  case invalidDatabase
}
