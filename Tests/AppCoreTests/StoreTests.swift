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
}

@Suite("StateStoreTests") struct StateStoreTests {
  @Test func roundTripsEveryField() async throws {
    let file = try temporaryDirectory().appendingPathComponent("state/state.json")
    let store = StateStore(fileURL: file)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let state = AppState(
      budgetUSD: Decimal(string: "42.50"),
      resetCycle: .customHours(12),
      lastManualResetAt: now,
      baseline: ResetBaseline(
        scheduledBoundaryAt: now.addingTimeInterval(-3600), manualResetAtConsidered: now,
        activeBoundaryAt: now, boundaryKind: .manual, cycle: .customHours(12),
        calendarIdentifier: "gregorian", timeZoneIdentifier: "UTC", computedAt: now
      )
    )
    try await store.save(state)
    #expect(try await store.load() == state)
  }

  @Test func corruptStateIsReportedAndNotReplaced() async throws {
    let file = try temporaryDirectory().appendingPathComponent("state.json")
    let bytes = Data("not json".utf8)
    try bytes.write(to: file)
    await #expect(throws: (any Error).self) { try await StateStore(fileURL: file).load() }
    #expect(try Data(contentsOf: file) == bytes)
  }
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
