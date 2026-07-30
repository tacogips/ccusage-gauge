import CSQLite
import Foundation

private let dashboardDirectorySQLiteTransient = unsafeBitCast(
  -1,
  to: sqlite3_destructor_type.self
)

public enum DashboardDirectoryNameError: Error, Equatable, Sendable {
  case invalidInput
  case machineDeletionPending
  case databaseUnavailable
}

private enum DashboardDirectoryNameDeletionPhase: String {
  case prepared
  case committed
  case rollback
}

public actor DashboardDirectoryNameStore: MachineRegistryMetadataLifecycle {
  public let fileURL: URL
  private let fileManager: FileManager

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public func setName(
    machine: String,
    directory: String,
    name: String?,
    now: Date = Date()
  ) throws -> String? {
    guard MachineValidation.isCanonicalMachineID(machine), !directory.isEmpty else {
      throw DashboardDirectoryNameError.invalidInput
    }
    let normalizedName = try Self.normalizedName(name)
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try transaction(in: database) {
      guard try machineDeletionPhase(machine: machine, in: database) == nil else {
        throw DashboardDirectoryNameError.machineDeletionPending
      }
      if let normalizedName {
        try upsert(
          machine: machine,
          directory: directory,
          name: normalizedName,
          now: now,
          in: database
        )
      } else {
        try delete(machine: machine, directory: directory, in: database)
      }
    }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    return normalizedName
  }

  public func names(machineIDs: [String]) throws -> [String: [String: String]] {
    guard machineIDs.allSatisfy(MachineValidation.isCanonicalMachineID) else {
      throw DashboardDirectoryNameError.invalidInput
    }
    guard !machineIDs.isEmpty else { return [:] }
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    var result: [String: [String: String]] = [:]
    for machine in Set(machineIDs) {
      if try machineDeletionPhase(machine: machine, in: database) != nil {
        continue
      }
      var statement: OpaquePointer?
      let sql = """
        SELECT directory, display_name
        FROM dashboard_directory_names
        WHERE machine_id = ?
        ORDER BY directory
        """
      guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement else {
        throw DashboardDirectoryNameError.databaseUnavailable
      }
      defer { sqlite3_finalize(statement) }
      guard bind(machine, at: 1, to: statement) == SQLITE_OK else {
        throw DashboardDirectoryNameError.databaseUnavailable
      }
      var stepResult = sqlite3_step(statement)
      while stepResult == SQLITE_ROW {
        let directory = try text(column: 0, from: statement)
        let name = try text(column: 1, from: statement)
        result[machine, default: [:]][directory] = name
        stepResult = sqlite3_step(statement)
      }
      guard stepResult == SQLITE_DONE else {
        throw DashboardDirectoryNameError.databaseUnavailable
      }
    }
    return result
  }

  public func reconcileMachineRegistry(machineIDs: [String]) throws {
    guard machineIDs.allSatisfy(MachineValidation.isCanonicalMachineID) else {
      throw DashboardDirectoryNameError.invalidInput
    }
    let activeMachineIDs = Set(machineIDs)
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try transaction(in: database) {
      for machineID in try metadataMachineIDs(in: database) {
        if activeMachineIDs.contains(machineID) {
          let phase = try machineDeletionPhase(machine: machineID, in: database)
          if phase == .committed {
            try deleteNames(machine: machineID, in: database)
          }
          try deleteMachineDeletionMarker(machine: machineID, in: database)
        } else {
          try writeMachineDeletionMarker(
            machine: machineID,
            phase: .committed,
            updateExisting: true,
            in: database
          )
          try deleteNames(machine: machineID, in: database)
        }
      }
    }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  public func prepareMachineCreation(machineID: String) throws {
    try validateMachineID(machineID)
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try transaction(in: database) {
      try deleteNames(machine: machineID, in: database)
      try deleteMachineDeletionMarker(machine: machineID, in: database)
    }
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  public func prepareMachineDeletion(machineID: String) throws {
    try validateMachineID(machineID)
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try writeMachineDeletionMarker(
      machine: machineID,
      phase: .prepared,
      updateExisting: true,
      in: database
    )
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  public func commitMachineDeletion(machineID: String) throws {
    try validateMachineID(machineID)
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try writeMachineDeletionMarker(
      machine: machineID,
      phase: .committed,
      updateExisting: true,
      in: database
    )
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  public func prepareMachineDeletionRollback(machineID: String) throws {
    try validateMachineID(machineID)
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try writeMachineDeletionMarker(
      machine: machineID,
      phase: .rollback,
      updateExisting: true,
      in: database
    )
    try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private func writeMachineDeletionMarker(
    machine: String,
    phase: DashboardDirectoryNameDeletionPhase,
    updateExisting: Bool,
    in database: OpaquePointer
  ) throws {
    var statement: OpaquePointer?
    let conflictClause = updateExisting
      ? """
        ON CONFLICT(machine_id) DO UPDATE SET
          deleted_at = excluded.deleted_at,
          phase = excluded.phase
        """
      : "ON CONFLICT(machine_id) DO NOTHING"
    let sql = """
      INSERT INTO dashboard_directory_name_machine_deletions(machine_id, deleted_at, phase)
      VALUES (?, ?, ?)
      \(conflictClause)
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    defer { sqlite3_finalize(statement) }
    guard bind(machine, at: 1, to: statement) == SQLITE_OK,
          sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970) == SQLITE_OK,
          bind(phase.rawValue, at: 3, to: statement) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
  }

  public func cancelMachineDeletion(machineID: String) throws {
    try validateMachineID(machineID)
    let database = try openDatabase()
    defer { sqlite3_close(database) }
    try createSchema(in: database)
    try deleteMachineDeletionMarker(machine: machineID, in: database)
  }

  public func finalizeMachineDeletion(machineID: String) -> Bool {
    guard MachineValidation.isCanonicalMachineID(machineID),
          let database = try? openDatabase() else {
      return false
    }
    defer { sqlite3_close(database) }
    do {
      try createSchema(in: database)
      try deleteNames(machine: machineID, in: database)
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      return true
    } catch {
      return false
    }
  }

  public static func normalizedName(_ name: String?) throws -> String? {
    guard let name else { return nil }
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty { return nil }
    guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          normalized.unicodeScalars.count <= 200 else {
      throw DashboardDirectoryNameError.invalidInput
    }
    return normalized
  }

  private func openDatabase() throws -> OpaquePointer {
    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
    } catch {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(fileURL.path, &database, flags, nil) == SQLITE_OK,
          let database else {
      if let database { sqlite3_close(database) }
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    sqlite3_busy_timeout(database, 5_000)
    return database
  }

  private func createSchema(in database: OpaquePointer) throws {
    let sql = """
      CREATE TABLE IF NOT EXISTS dashboard_directory_names (
        machine_id TEXT NOT NULL,
        directory TEXT NOT NULL,
        display_name TEXT NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY(machine_id, directory)
      );
      CREATE TABLE IF NOT EXISTS dashboard_directory_name_machine_deletions (
        machine_id TEXT PRIMARY KEY,
        deleted_at REAL NOT NULL,
        phase TEXT NOT NULL DEFAULT 'prepared'
      );
      """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    if try !deletionMarkerTableHasPhase(in: database) {
      guard sqlite3_exec(
        database,
        """
        ALTER TABLE dashboard_directory_name_machine_deletions
        ADD COLUMN phase TEXT NOT NULL DEFAULT 'prepared'
        """,
        nil,
        nil,
        nil
      ) == SQLITE_OK else {
        throw DashboardDirectoryNameError.databaseUnavailable
      }
    }
  }

  private func validateMachineID(_ machineID: String) throws {
    guard MachineValidation.isCanonicalMachineID(machineID) else {
      throw DashboardDirectoryNameError.invalidInput
    }
  }

  private func transaction(
    in database: OpaquePointer,
    operation: () throws -> Void
  ) throws {
    guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    do {
      try operation()
      guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
        throw DashboardDirectoryNameError.databaseUnavailable
      }
    } catch {
      sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
      throw error
    }
  }

  private func machineDeletionPhase(
    machine: String,
    in database: OpaquePointer
  ) throws -> DashboardDirectoryNameDeletionPhase? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "SELECT phase FROM dashboard_directory_name_machine_deletions WHERE machine_id = ?",
      -1,
      &statement,
      nil
    ) == SQLITE_OK, let statement else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    defer { sqlite3_finalize(statement) }
    guard bind(machine, at: 1, to: statement) == SQLITE_OK else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    let result = sqlite3_step(statement)
    guard result == SQLITE_ROW || result == SQLITE_DONE else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    guard result == SQLITE_ROW else { return nil }
    guard let phase = DashboardDirectoryNameDeletionPhase(
      rawValue: try text(column: 0, from: statement)
    ) else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    return phase
  }

  private func deletionMarkerTableHasPhase(in database: OpaquePointer) throws -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "PRAGMA table_info(dashboard_directory_name_machine_deletions)",
      -1,
      &statement,
      nil
    ) == SQLITE_OK, let statement else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    defer { sqlite3_finalize(statement) }
    var stepResult = sqlite3_step(statement)
    while stepResult == SQLITE_ROW {
      if try text(column: 1, from: statement) == "phase" {
        return true
      }
      stepResult = sqlite3_step(statement)
    }
    guard stepResult == SQLITE_DONE else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    return false
  }

  private func metadataMachineIDs(in database: OpaquePointer) throws -> [String] {
    var statement: OpaquePointer?
    let sql = """
      SELECT machine_id FROM dashboard_directory_names
      UNION
      SELECT machine_id FROM dashboard_directory_name_machine_deletions
      ORDER BY machine_id
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    defer { sqlite3_finalize(statement) }
    var result: [String] = []
    var stepResult = sqlite3_step(statement)
    while stepResult == SQLITE_ROW {
      result.append(try text(column: 0, from: statement))
      stepResult = sqlite3_step(statement)
    }
    guard stepResult == SQLITE_DONE else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    return result
  }

  private func deleteNames(
    machine: String,
    in database: OpaquePointer
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "DELETE FROM dashboard_directory_names WHERE machine_id = ?",
      -1,
      &statement,
      nil
    ) == SQLITE_OK, let statement else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    defer { sqlite3_finalize(statement) }
    guard bind(machine, at: 1, to: statement) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
  }

  private func deleteMachineDeletionMarker(
    machine: String,
    in database: OpaquePointer
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "DELETE FROM dashboard_directory_name_machine_deletions WHERE machine_id = ?",
      -1,
      &statement,
      nil
    ) == SQLITE_OK, let statement else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    defer { sqlite3_finalize(statement) }
    guard bind(machine, at: 1, to: statement) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
  }

  private func upsert(
    machine: String,
    directory: String,
    name: String,
    now: Date,
    in database: OpaquePointer
  ) throws {
    var statement: OpaquePointer?
    let sql = """
      INSERT INTO dashboard_directory_names(machine_id, directory, display_name, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(machine_id, directory)
      DO UPDATE SET display_name = excluded.display_name, updated_at = excluded.updated_at
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    defer { sqlite3_finalize(statement) }
    guard bind(machine, at: 1, to: statement) == SQLITE_OK,
          bind(directory, at: 2, to: statement) == SQLITE_OK,
          bind(name, at: 3, to: statement) == SQLITE_OK,
          sqlite3_bind_double(statement, 4, now.timeIntervalSince1970) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
  }

  private func delete(
    machine: String,
    directory: String,
    in database: OpaquePointer
  ) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
      database,
      "DELETE FROM dashboard_directory_names WHERE machine_id = ? AND directory = ?",
      -1,
      &statement,
      nil
    ) == SQLITE_OK, let statement else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    defer { sqlite3_finalize(statement) }
    guard bind(machine, at: 1, to: statement) == SQLITE_OK,
          bind(directory, at: 2, to: statement) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
  }

  private func bind(
    _ value: String,
    at index: Int32,
    to statement: OpaquePointer
  ) -> Int32 {
    guard value.utf8.count <= Int(Int32.max) else { return SQLITE_TOOBIG }
    return value.withCString {
      sqlite3_bind_text(
        statement,
        index,
        $0,
        Int32(value.utf8.count),
        dashboardDirectorySQLiteTransient
      )
    }
  }

  private func text(
    column: Int32,
    from statement: OpaquePointer
  ) throws -> String {
    guard let bytes = sqlite3_column_text(statement, column) else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    let count = Int(sqlite3_column_bytes(statement, column))
    let data = Data(bytes: bytes, count: count)
    guard let value = String(data: data, encoding: .utf8) else {
      throw DashboardDirectoryNameError.databaseUnavailable
    }
    return value
  }
}
