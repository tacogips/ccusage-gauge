import Foundation
import Testing
@testable import AppCore

@Suite("Machine unavailable cost-series responses")
struct MachineUnavailableResponseTests {
  @Test func snapshotUnavailablePreservesAvailabilityAndGapScope() async throws {
    let runtime = try unavailableRuntime()
    defer { Task { await runtime.collector.stop() } }

    let response = await runtime.router.route(
      target: "/api/cost-series?range=today&granularity=hourly&machine=local",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let object = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let scope = try #require(object["scope"] as? [String: Any])
    let availability = try #require(scope["machineAvailability"] as? [[String: Any]])
    let gaps = try #require(scope["lastHourDataGaps"] as? [[String: Any]])

    #expect(response.status == 503)
    #expect(object["error"] as? String == "snapshot_unavailable")
    #expect(availability.count == 1)
    #expect(availability.first?["machine"] as? String == "local")
    #expect(availability.first?["available"] as? Bool == false)
    #expect(gaps.count == 1)
    #expect(gaps.first?["machine"] as? String == "local")
  }

  @Test func aggregateSnapshotUnavailablePreservesPerMachineObservability() async throws {
    let runtime = try unavailableRuntime()
    defer { Task { await runtime.collector.stop() } }

    let response = await runtime.router.route(
      target: "/api/recent?machine=all",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let object = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let error = try #require(object["error"] as? [String: Any])
    let scope = try #require(object["scope"] as? [String: Any])
    let availability = try #require(scope["machineAvailability"] as? [[String: Any]])
    let gaps = try #require(scope["lastHourDataGaps"] as? [[String: Any]])

    #expect(response.status == 503)
    #expect(error["code"] as? String == "current_data_unavailable")
    #expect(scope["requested"] as? String == "all")
    #expect(scope["unavailableMachineIds"] as? [String] == ["local"])
    #expect(scope["excludedFromCurrentTotalsMachineIds"] as? [String] == ["local"])
    #expect(availability.count == 1)
    #expect(gaps.count == 1)
  }

  @Test func rangeUnavailablePreservesCoverageScopeAndLatestEvents() async throws {
    let runtime = try unavailableRuntime()
    defer { Task { await runtime.collector.stop() } }
    let now = Date()
    let snapshot = CostSnapshot(
      generatedAt: now,
      activeBoundaryAt: now.addingTimeInterval(-86_400),
      costSinceResetUSD: 0,
      budget: BudgetSummary(spentUSD: 0, budgetUSD: nil),
      resetCycle: .daily,
      points: []
    )
    await runtime.store.publish(
      machineID: "local",
      snapshot: snapshot,
      coverageStart: now.addingTimeInterval(-86_400),
      revision: 0,
      generation: 0,
      now: now
    )

    let response = await runtime.router.route(
      target: "/api/cost-series?range=custom&start=2020-01-01&end=2020-01-02&granularity=hourly&machine=local",
      method: "GET",
      headers: [:],
      body: Data(),
      listenerPort: 18_081
    )
    let object = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])

    #expect(response.status == 200)
    let rangeLoad = try #require(object["rangeLoad"] as? [String: Any])
    #expect(rangeLoad["isPartial"] as? Bool == true)
    #expect((object["machineLatestEvents"] as? [[String: Any]])?.count == 1)
    #expect(object["scope"] is [String: Any])
  }
}

private struct UnavailableRuntime {
  let router: MachineDashboardRouter
  let collector: MachineCollector
  let store: MachineSnapshotStore
}

private func unavailableRuntime() throws -> UnavailableRuntime {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let paths = AppPaths(
    configFile: root.appendingPathComponent("config/ccusage-gauge/ccusage-config.json"),
    stateFile: root.appendingPathComponent("state/ccusage-gauge/state.json"),
    aggregationCacheFile: root.appendingPathComponent("cache/ccusage-gauge/aggregates.sqlite3")
  )
  let persistence = MachineRegistryStore(fileURL: paths.machinesFile)
  let registry = try persistence.load()
  let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
  let state = StateStore(fileURL: paths.stateFile)
  let collector = try MachineCollector(registry: registry, store: store) { descriptor in
    SnapshotService(
      stateStore: state,
      client: CCUsageClient(commandRunner: AlwaysFailingRunner(), machine: descriptor.id),
      aggregationCache: nil
    )
  }
  let owner = MachineRegistryMutationOwner(store: persistence, registry: registry, runtime: collector)
  return UnavailableRuntime(
    router: MachineDashboardRouter(store: store, collector: collector, mutationOwner: owner, paths: paths),
    collector: collector,
    store: store
  )
}

private struct AlwaysFailingRunner: CCUsageCommandRunner {
  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    throw CCUsageCommandFailure(runnerKind: .local, phase: .commandExited, exitStatus: 1)
  }
}
