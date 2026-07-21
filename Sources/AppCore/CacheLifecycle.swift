import Foundation
import CSQLite
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum CacheLifecycleError: Error, Equatable, Sendable {
  case cacheFailed
}

public struct LocalCacheMigrator: @unchecked Sendable {
  public let legacyURL: URL
  public let destinationURL: URL
  private let fileManager: FileManager

  public init(legacyURL: URL, destinationURL: URL, fileManager: FileManager = .default) {
    self.legacyURL = legacyURL
    self.destinationURL = destinationURL
    self.fileManager = fileManager
  }

  public func migrateIfNeeded() throws {
    let directory = destinationURL.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      if fileManager.fileExists(atPath: destinationURL.path) {
        try enforceRegularFile(destinationURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
        return
      }
      guard fileManager.fileExists(atPath: legacyURL.path) else { return }
      guard isRegularSingleLink(legacyURL), isValidCache(legacyURL) else { return }
      try checkpoint(legacyURL)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacyURL.path)
      guard !fileManager.fileExists(atPath: destinationURL.path), rename(legacyURL.path, destinationURL.path) == 0 else {
        throw CacheLifecycleError.cacheFailed
      }
      for suffix in ["-wal", "-shm"] where fileManager.fileExists(atPath: legacyURL.path + suffix) {
        throw CacheLifecycleError.cacheFailed
      }
    } catch let error as CacheLifecycleError {
      throw error
    } catch {
      throw CacheLifecycleError.cacheFailed
    }
  }

  private func isRegularSingleLink(_ url: URL) -> Bool {
    var metadata = stat()
    return lstat(url.path, &metadata) == 0 &&
      (metadata.st_mode & S_IFMT) == S_IFREG && metadata.st_nlink == 1 && metadata.st_uid == getuid()
  }

  private func enforceRegularFile(_ url: URL) throws {
    guard isRegularSingleLink(url) else { throw CacheLifecycleError.cacheFailed }
  }

  private func isValidCache(_ url: URL) -> Bool {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      return false
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK, let statement else { return false }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let text = sqlite3_column_text(statement, 0), String(cString: text) == "ok" else { return false }
    return tableExists("cache_metadata", in: database) && tableExists("daily_metrics", in: database)
  }

  private func tableExists(_ table: String, in database: OpaquePointer) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &statement, nil) == SQLITE_OK,
          let statement else { return false }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func checkpoint(_ url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw CacheLifecycleError.cacheFailed
    }
    defer { sqlite3_close(database) }
    guard sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else {
      throw CacheLifecycleError.cacheFailed
    }
  }
}

public actor MachineCacheClearCoordinator {
  public init() {}

  public func clear(machineID: String, cacheURL: URL, legacyLocalURL: URL? = nil) throws {
    let directory = cacheURL.deletingLastPathComponent()
    let transaction = directory.appendingPathComponent(".clear-\(machineID)-\(UUID().uuidString)", isDirectory: true)
    do {
      try MachineCacheRecovery.reconcile(machineID: machineID, cacheURL: cacheURL)
      try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
      var paths = cachePaths(cacheURL)
      if let legacyLocalURL { paths += cachePaths(legacyLocalURL) }
      var staged: [(source: URL, staged: URL)] = []
      do {
        for source in paths where FileManager.default.fileExists(atPath: source.path) {
          let stagedURL = transaction.appendingPathComponent(source.lastPathComponent)
          try FileManager.default.moveItem(at: source, to: stagedURL)
          staged.append((source, stagedURL))
        }
        try Data("committed\n".utf8).write(to: transaction.appendingPathComponent("COMMITTED"), options: .withoutOverwriting)
      } catch {
        for item in staged.reversed() { try? FileManager.default.moveItem(at: item.staged, to: item.source) }
        throw error
      }
      try? FileManager.default.removeItem(at: transaction)
    } catch {
      throw CacheLifecycleError.cacheFailed
    }
  }

  private func cachePaths(_ url: URL) -> [URL] {
    ["", "-journal", "-shm", "-wal"].map { URL(fileURLWithPath: url.path + $0) }
  }
}

public enum MachineCacheRecovery {
  public static func reconcile(machineID: String, cacheURL: URL) throws {
    let fileManager = FileManager.default
    let directory = cacheURL.deletingLastPathComponent()
    guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
    for transaction in contents where transaction.lastPathComponent.hasPrefix(".clear-\(machineID)-") {
      do {
        let committed = transaction.appendingPathComponent("COMMITTED")
        if fileManager.fileExists(atPath: committed.path) {
          try fileManager.removeItem(at: transaction)
          continue
        }
        for staged in try fileManager.contentsOfDirectory(at: transaction, includingPropertiesForKeys: nil) {
          let original = directory.appendingPathComponent(staged.lastPathComponent)
          guard !fileManager.fileExists(atPath: original.path) else { throw CacheLifecycleError.cacheFailed }
          try fileManager.moveItem(at: staged, to: original)
        }
        try fileManager.removeItem(at: transaction)
      } catch {
        throw CacheLifecycleError.cacheFailed
      }
    }
  }
}
