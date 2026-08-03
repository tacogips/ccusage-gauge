import Foundation
import Testing
@testable import AppCore

private actor CancellationBlockingRunner: CCUsageCommandRunner {
  private var didStart = false

  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    didStart = true
    return try await CCUsageProcessRunner().run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"],
      timeoutSeconds: timeoutSeconds
    )
  }

  func started() -> Bool { didStart }
}

@Suite("Machine deletion cancellation")
struct MachineDeletionCancellationTests {
  @Test func deleteReturnsWhileRemoteCollectionProcessIsUnresponsive() async throws {
    let root = try temporaryDirectory()
    let paths = AppPaths(
      configFile: root.appendingPathComponent("config/ccusage-gauge/ccusage-config.json"),
      stateFile: root.appendingPathComponent("state/ccusage-gauge/state.json"),
      aggregationCacheFile: root.appendingPathComponent("cache/ccusage-gauge/aggregates.sqlite3")
    )
    let remote = MachineDescriptor(
      id: "remote",
      displayName: "Remote",
      kind: .ssh,
      enabled: true,
      ssh: SSHConnection(host: "unreachable.invalid", port: 22, user: "user")
    )
    let registry = try MachineRegistry(sshMachines: [remote])
    let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
    try registryStore.save(registry)
    let snapshotStore = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let stateStore = StateStore(fileURL: paths.stateFile)
    let runner = CancellationBlockingRunner()
    let collector = try MachineCollector(registry: registry, store: snapshotStore) { descriptor in
      SnapshotService(
        stateStore: stateStore,
        client: CCUsageClient(commandRunner: runner, machine: descriptor.id),
        aggregationCache: nil
      )
    }
    let owner = MachineRegistryMutationOwner(
      store: registryStore,
      registry: registry,
      runtime: collector
    )
    let router = MachineDashboardRouter(
      store: snapshotStore,
      collector: collector,
      mutationOwner: owner,
      paths: paths
    )
    await collector.start(machineIDs: ["remote"])
    defer { Task { await collector.stop() } }

    for _ in 0..<100 where !(await runner.started()) {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await runner.started())

    let startedAt = Date()
    let response = await router.route(
      target: "/api/machines/remote",
      method: "DELETE",
      headers: [
        "host": "127.0.0.1:18081",
        "x-ccusage-gauge-mutation": "1"
      ],
      body: Data(),
      listenerPort: 18_081
    )

    #expect(response.status == 204)
    #expect(Date().timeIntervalSince(startedAt) < 2)
    #expect(await owner.current().machine(id: "remote") == nil)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
