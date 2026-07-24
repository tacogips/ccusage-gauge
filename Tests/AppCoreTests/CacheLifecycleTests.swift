import Foundation
import Testing
@testable import AppCore

@Suite("CacheLifecycleTests")
struct CacheLifecycleTests {
  @Test func migratesValidLegacyCacheAndMakesRepeatMigrationIdempotent() async throws {
    let root = try temporaryDirectory()
    let legacy = root.appendingPathComponent("aggregates.sqlite3")
    let destination = root.appendingPathComponent("aggregates-local.sqlite3")
    let cache = UsageAggregationCache(fileURL: legacy)
    try await cache.save(
      metrics: [],
      sessions: [],
      cachedFrom: "2026-07-01",
      cachedThrough: "2026-07-24"
    )

    let migrator = LocalCacheMigrator(legacyURL: legacy, destinationURL: destination)
    try migrator.migrateIfNeeded()
    try migrator.migrateIfNeeded()

    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(FileManager.default.fileExists(atPath: destination.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test func ignoresMissingAndInvalidLegacyCachesButRejectsUnsafeDestination() throws {
    let root = try temporaryDirectory()
    let legacy = root.appendingPathComponent("aggregates.sqlite3")
    let destination = root.appendingPathComponent("aggregates-local.sqlite3")
    let migrator = LocalCacheMigrator(legacyURL: legacy, destinationURL: destination)

    try migrator.migrateIfNeeded()
    try Data("not sqlite".utf8).write(to: legacy)
    try migrator.migrateIfNeeded()
    #expect(!FileManager.default.fileExists(atPath: destination.path))

    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    #expect(throws: CacheLifecycleError.cacheFailed) {
      try migrator.migrateIfNeeded()
    }
  }

  @Test func clearRemovesPrimaryAndSidecarFilesAtomically() async throws {
    let root = try temporaryDirectory()
    let cache = root.appendingPathComponent("aggregates-remote.sqlite3")
    for suffix in ["", "-journal", "-shm", "-wal"] {
      try Data(suffix.utf8).write(to: URL(fileURLWithPath: cache.path + suffix))
    }

    try await MachineCacheClearCoordinator().clear(machineID: "remote", cacheURL: cache)

    for suffix in ["", "-journal", "-shm", "-wal"] {
      #expect(!FileManager.default.fileExists(atPath: cache.path + suffix))
    }
    let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(!contents.contains { $0.hasPrefix(".clear-remote-") })
  }

  @Test func recoveryRestoresUncommittedTransactionAndDiscardsCommittedOne() throws {
    let root = try temporaryDirectory()
    let cache = root.appendingPathComponent("aggregates-remote.sqlite3")
    let uncommitted = root.appendingPathComponent(".clear-remote-uncommitted", isDirectory: true)
    try FileManager.default.createDirectory(at: uncommitted, withIntermediateDirectories: false)
    try Data("cache".utf8).write(to: uncommitted.appendingPathComponent(cache.lastPathComponent))

    try MachineCacheRecovery.reconcile(machineID: "remote", cacheURL: cache)
    #expect(try Data(contentsOf: cache) == Data("cache".utf8))
    #expect(!FileManager.default.fileExists(atPath: uncommitted.path))

    try FileManager.default.removeItem(at: cache)
    let committed = root.appendingPathComponent(".clear-remote-committed", isDirectory: true)
    try FileManager.default.createDirectory(at: committed, withIntermediateDirectories: false)
    try Data("cache".utf8).write(to: committed.appendingPathComponent(cache.lastPathComponent))
    try Data("committed\n".utf8).write(to: committed.appendingPathComponent("COMMITTED"))

    try MachineCacheRecovery.reconcile(machineID: "remote", cacheURL: cache)
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    #expect(!FileManager.default.fileExists(atPath: committed.path))
  }

  @Test func recoveryFailsClosedWhenRestoringWouldOverwriteAFile() throws {
    let root = try temporaryDirectory()
    let cache = root.appendingPathComponent("aggregates-remote.sqlite3")
    try Data("current".utf8).write(to: cache)
    let transaction = root.appendingPathComponent(".clear-remote-conflict", isDirectory: true)
    try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: false)
    try Data("staged".utf8).write(to: transaction.appendingPathComponent(cache.lastPathComponent))

    #expect(throws: CacheLifecycleError.cacheFailed) {
      try MachineCacheRecovery.reconcile(machineID: "remote", cacheURL: cache)
    }
    #expect(try Data(contentsOf: cache) == Data("current".utf8))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ccusage-cache-lifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
