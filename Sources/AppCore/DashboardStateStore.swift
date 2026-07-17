import CSQLite
import Foundation

private let dashboardSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DashboardUIState: Codable, Equatable, Sendable {
  public let range: String
  public let customStart: String
  public let customEnd: String
  public let selectedModels: [String]
  public let selectedAgents: [String]
  public let granularity: String
  public let chartMetric: String

  public init(
    range: String,
    customStart: String,
    customEnd: String,
    selectedModels: [String],
    selectedAgents: [String],
    granularity: String,
    chartMetric: String
  ) {
    self.range = range
    self.customStart = customStart
    self.customEnd = customEnd
    self.selectedModels = selectedModels
    self.selectedAgents = selectedAgents
    self.granularity = granularity
    self.chartMetric = chartMetric
  }

  public func validate() throws {
    guard ["recent12h", "today", "yesterday", "week", "month", "custom"].contains(range),
          ["15min", "hourly", "6hour", "daily"].contains(granularity),
          ["costUSD", "totalTokens", "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens"].contains(chartMetric),
          Self.isDay(customStart), Self.isDay(customEnd), customStart <= customEnd,
          selectedModels.count <= 500, selectedAgents.count <= 50,
          selectedModels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 500 }),
          selectedAgents.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 }) else {
      throw DashboardStateError.invalidState
    }
  }

  private static func isDay(_ value: String) -> Bool {
    guard value.count == 10 else { return false }
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    return formatter.date(from: value) != nil
  }
}

public actor DashboardStateStore {
  public let fileURL: URL
  private let fileManager: FileManager

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public func load() throws -> DashboardUIState? {
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    let database = try openDatabase(createDirectory: false)
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT value FROM dashboard_state WHERE id = 1", -1, &statement, nil) == SQLITE_OK,
          let statement else { throw DashboardStateError.databaseUnavailable }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let bytes = sqlite3_column_blob(statement, 0) else { throw DashboardStateError.invalidState }
    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    let state = try JSONDecoder().decode(DashboardUIState.self, from: data)
    try state.validate()
    return state
  }

  public func save(_ state: DashboardUIState, now: Date = Date()) throws {
    try state.validate()
    let data = try JSONEncoder().encode(state)
    let database = try openDatabase(createDirectory: true)
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    var statement: OpaquePointer?
    let sql = "INSERT INTO dashboard_state(id, value, updated_at) VALUES (1, ?, ?) ON CONFLICT(id) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at"
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else { throw DashboardStateError.databaseUnavailable }
    defer { sqlite3_finalize(statement) }
    let bindResult = data.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), dashboardSQLiteTransient)
    }
    guard bindResult == SQLITE_OK else { throw DashboardStateError.databaseUnavailable }
    sqlite3_bind_double(statement, 2, now.timeIntervalSince1970)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw DashboardStateError.databaseUnavailable }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private func openDatabase(createDirectory: Bool) throws -> OpaquePointer {
    if createDirectory {
      try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw DashboardStateError.databaseUnavailable
    }
    return database
  }

  private func createSchema(in database: OpaquePointer) throws {
    let sql = "CREATE TABLE IF NOT EXISTS dashboard_state (id INTEGER PRIMARY KEY CHECK (id = 1), value BLOB NOT NULL, updated_at REAL NOT NULL)"
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw DashboardStateError.databaseUnavailable }
  }
}

public struct DashboardUIStateResponse: Codable, Equatable, Sendable {
  public let state: DashboardUIState?

  public init(state: DashboardUIState?) {
    self.state = state
  }
}

public enum DashboardStateError: Error, Sendable {
  case databaseUnavailable
  case invalidState
}
