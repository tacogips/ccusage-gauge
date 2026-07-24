import Foundation
import Testing
@testable import AppCore

private actor HistoricalWarmupRunner: CCUsageCommandRunner {
  private var calls: [[String]] = []

  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    calls.append(arguments)
    let payload = arguments.first == "blocks" ? #"{"blocks":[]}"# : #"{"daily":[],"session":[]}"#
    return ProcessResult(stdout: Data(payload.utf8), stderr: Data(), exitStatus: 0)
  }

  func arguments() -> [[String]] { calls }
}

struct HistoricalWarmupCase: Sendable {
  let cachedFrom: String
  let expectedCoverageStart: String
  let skipsHistoricalCollection: Bool
}

@Suite struct MachineHistoricalWarmupTests {
  @Test(arguments: [
    HistoricalWarmupCase(
      cachedFrom: "2026-03-01",
      expectedCoverageStart: "2026-03-01",
      skipsHistoricalCollection: true
    ),
    HistoricalWarmupCase(
      cachedFrom: "2026-07-01",
      expectedCoverageStart: "2026-06-01",
      skipsHistoricalCollection: false
    )
  ])
  func historicalCollectionOnlyRunsForMissingCoverage(testCase: HistoricalWarmupCase) async throws {
    let root = try temporaryDirectory()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-24T12:00:00Z"))
    let expectedCoverageStart = try #require(day(testCase.expectedCoverageStart, calendar: calendar))
    let cache = UsageAggregationCache(fileURL: root.appendingPathComponent("aggregates-local.sqlite3"))
    try await cache.save(
      metrics: [],
      sessions: [],
      cachedFrom: testCase.cachedFrom,
      cachedThrough: "2026-07-23",
      now: now
    )
    let stateStore = StateStore(fileURL: root.appendingPathComponent("state.json"))
    let calculator = ResetWindowCalculator(calendar: calendar)
    try await stateStore.save(try calculator.validatedState(AppState(), now: now))
    let runner = HistoricalWarmupRunner()
    let registry = try MachineRegistry(sshMachines: [])
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20, calendar: calendar)
    let collector = try MachineCollector(
      registry: registry,
      store: store,
      calendar: calendar,
      now: { now },
      serviceFactory: { descriptor in
        SnapshotService(
          stateStore: stateStore,
          client: CCUsageClient(commandRunner: runner, machine: descriptor.id),
          calculator: calculator,
          aggregationCache: cache
        )
      }
    )
    await collector.start(machineIDs: ["local"])
    defer { Task { await collector.stop() } }

    for _ in 0..<1_000 {
      if await store.entry(machineID: "local")?.coverageStart == expectedCoverageStart { break }
      try await Task.sleep(for: .milliseconds(1))
    }

    let entry = try #require(await store.entry(machineID: "local"))
    #expect(entry.coverageStart == expectedCoverageStart)
    #expect(entry.loadStatus.phase == .ready)
    #expect(!entry.loadStatus.isLoading)
    let dailyCalls = await runner.arguments().filter { $0.first == "daily" }
    if testCase.skipsHistoricalCollection {
      #expect(dailyCalls.count == 1)
      #expect(dailyCalls[0].contains("2026-07-24"))
    } else {
      #expect(dailyCalls.contains { argumentValue(after: "--since", in: $0) == "2026-06-01" })
    }
  }

  private func day(_ text: String, calendar: Calendar) -> Date? {
    let fields = text.split(separator: "-").compactMap { Int($0) }
    guard fields.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2]))
  }

  private func argumentValue(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ccusage-historical-warmup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
