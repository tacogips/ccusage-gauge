import Foundation
import Testing
@testable import AppCore

private actor RangeRecordingRunner: CCUsageCommandRunner {
  private var calls: [[String]] = []
  private var blockedHistorical = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private let today: String

  init(today: String, blockedHistorical: Bool = false) {
    self.today = today
    self.blockedHistorical = blockedHistorical
  }

  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    calls.append(arguments)
    if blockedHistorical,
       arguments.first == "daily",
       argument(after: "--since", in: arguments) != today {
      await withCheckedContinuation { waiters.append($0) }
    }
    let payload = arguments.first == "blocks"
      ? #"{"blocks":[]}"#
      : #"{"daily":[],"session":[]}"#
    return ProcessResult(stdout: Data(payload.utf8), stderr: Data(), exitStatus: 0)
  }

  func recordedCalls() -> [[String]] { calls }

  func releaseHistorical() {
    blockedHistorical = false
    let pending = waiters
    waiters.removeAll()
    pending.forEach { $0.resume() }
  }

  private func argument(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option),
          arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }
}

private struct RangeFixture: Sendable {
  let service: SnapshotService
  let runner: RangeRecordingRunner
  let calendar: Calendar
  let now: Date
}

@Suite struct RangeLoadingTests {
  @Test func snapshotLoadsOnlyRequestedDayInsteadOfCurrentWeek() async throws {
    let fixture = try await makeFixture()
    let requested = try #require(day("2026-07-14", calendar: fixture.calendar))

    _ = try await fixture.service.snapshot(
      now: fixture.now,
      earliestDate: requested,
      latestDate: requested
    )

    let daily = await fixture.runner.recordedCalls().filter { $0.first == "daily" }
    #expect(daily.count == 1)
    #expect(argument(after: "--since", in: daily[0]) == "2026-07-14")
    #expect(argument(after: "--until", in: daily[0]) == "2026-07-14")
  }

  @Test func sparseCompletedCoverageSurvivesCacheReopen() async throws {
    let root = try temporaryDirectory()
    let file = root.appendingPathComponent("aggregates.sqlite3")
    let cache = UsageAggregationCache(fileURL: file, retentionDays: 365)
    try await cache.merge(
      metrics: [],
      sessions: [],
      coveredRange: AggregationCacheRange(since: "2026-07-01", through: "2026-07-07")
    )
    try await cache.merge(
      metrics: [],
      sessions: [],
      coveredRange: AggregationCacheRange(since: "2026-07-09", through: "2026-07-10")
    )
    let pending = AggregationCacheJob(since: "2026-07-01", through: "2026-07-31")
    try await cache.beginJob(pending)

    let reopened = UsageAggregationCache(fileURL: file, retentionDays: 365)
    let ranges = try #require(await reopened.load()?.coveredRanges)
    #expect(ranges == [
      AggregationCacheRange(since: "2026-07-01", through: "2026-07-07"),
      AggregationCacheRange(since: "2026-07-09", through: "2026-07-10")
    ])
    #expect(try await reopened.pendingJobs() == [pending])
    try await reopened.finishJob(pending)
    #expect(try await reopened.pendingJobs().isEmpty)
  }

  @Test func dayLoadCompletesWhileMonthLoadContinues() async throws {
    let fixture = try await makeFixture(blockedHistorical: true)
    let registry = try MachineRegistry(sshMachines: [])
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20, calendar: fixture.calendar)
    let collector = try MachineCollector(
      registry: registry,
      store: store,
      calendar: fixture.calendar,
      now: { fixture.now },
      serviceFactory: { _ in fixture.service }
    )
    let month = try #require(day("2026-07-01", calendar: fixture.calendar))
    let today = try #require(day("2026-07-16", calendar: fixture.calendar))

    await collector.expand(machine: "local", earliestDate: month, latestDate: today)
    try await waitUntil {
      await collector.rangeLoadStates(
        machine: "local",
        earliestDate: month,
        latestDate: today
      ).contains(where: \.isLoading)
    }
    await collector.expand(machine: "local", earliestDate: today, latestDate: today)
    try await waitUntil {
      await collector.rangeLoadStates(
        machine: "local",
        earliestDate: today,
        latestDate: today
      ).first?.phase == .ready
    }

    let monthState = await collector.rangeLoadStates(
      machine: "local",
      earliestDate: month,
      latestDate: today
    ).first
    #expect(monthState?.isLoading == true)
    await fixture.runner.releaseHistorical()
    try await waitUntil {
      await collector.rangeLoadStates(
        machine: "local",
        earliestDate: month,
        latestDate: today
      ).first?.phase == .ready
    }
    await collector.stop()
  }

  private func makeFixture(
    blockedHistorical: Bool = false
  ) async throws -> RangeFixture {
    let root = try temporaryDirectory()
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
    let stateStore = StateStore(fileURL: root.appendingPathComponent("state.json"))
    let calculator = ResetWindowCalculator(calendar: calendar)
    try await stateStore.save(try calculator.validatedState(AppState(), now: now))
    let runner = RangeRecordingRunner(today: "2026-07-16", blockedHistorical: blockedHistorical)
    let service = SnapshotService(
      stateStore: stateStore,
      client: CCUsageClient(commandRunner: runner, machine: "local"),
      calculator: calculator,
      aggregationCache: UsageAggregationCache(
        fileURL: root.appendingPathComponent("aggregates.sqlite3"),
        retentionDays: 365
      )
    )
    return RangeFixture(service: service, runner: runner, calendar: calendar, now: now)
  }

  private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
  ) async throws {
    for _ in 0..<2_000 {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for range load state")
  }

  private func day(_ text: String, calendar: Calendar) -> Date? {
    let values = text.split(separator: "-").compactMap { Int($0) }
    guard values.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
  }

  private func argument(after option: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: option),
          arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ccusage-range-loading-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
