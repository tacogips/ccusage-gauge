import Foundation
import Testing
@testable import AppCore

@Suite("DesktopDashboardTests")
struct DesktopDashboardTests {
  @Test func routesReadsAndGuardedMutationsWithoutHTTP() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let router = try await makeRouter(root: root)
    let health = await DesktopDashboardRequest(id: 7, path: "/api/health", method: "GET", body: nil).route(using: router)
    #expect(health.id == 7)
    #expect(health.status == 200)
    let mutation = await DesktopDashboardRequest(
      id: 8, path: "/api/machines/local", method: "PATCH", body: "{\"codexSessionDirs\":[\"/tmp/desktop-sessions\"]}"
    ).route(using: router)
    #expect(mutation.status == 200)
    let machines = await DesktopDashboardRequest(id: 9, path: "/api/machines", method: "GET", body: nil).route(using: router)
    let decoded = try JSONDecoder().decode(MachinesResponse.self, from: Data(machines.body.utf8))
    #expect(decoded.machines.first?.codexSessionDirs == ["/tmp/desktop-sessions"])
    let invalid = await DesktopDashboardRequest(id: 10, path: "https://example.com", method: "GET", body: nil).route(using: router)
    #expect(invalid.status == 400)
  }

  @MainActor
  @Test func launchesExchangesPipeMessagesAndReopensAfterExit() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let executable = root.appendingPathComponent("window")
    let result = root.appendingPathComponent("response.json")
    try """
    #!/bin/sh
    printf '%s\\n' '{"id":42,"path":"/api/health","method":"GET","body":null}'
    IFS= read -r response
    printf '%s' "$response" > '\(result.path)'
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let router = try await makeRouter(root: root)
    let window = DesktopDashboard()
    defer { window.stop() }
    for _ in 0..<2 {
      try window.start(router: router, executable: executable)
      let deadline = Date().addingTimeInterval(5)
      while window.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
      #expect(!window.isRunning)
      let response = try JSONDecoder().decode(DesktopDashboardResponse.self, from: Data(contentsOf: result))
      #expect(response.id == 42)
      #expect(response.status == 200)
    }
  }

  @MainActor
  @Test func explicitMissingExecutableDoesNotFallBack() throws {
    #expect(throws: DesktopDashboardError.self) {
      try DesktopDashboard.executableURL(environment: ["CCUSAGE_GAUGE_DESKTOP_EXECUTABLE": "/missing/dashboard"])
    }
  }

  private func makeRouter(root: URL) async throws -> MachineDashboardRouter {
    let paths = AppPaths(
      configFile: root.appendingPathComponent("config/config.json"),
      stateFile: root.appendingPathComponent("state/state.json"),
      aggregationCacheFile: root.appendingPathComponent("cache/cache.sqlite3")
    )
    let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
    let registry = try registryStore.load()
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let collector = try MachineCollector(registry: registry, store: store, connectionTester: { _ in }, serviceFactory: { _ in
      SnapshotService(
        stateStore: StateStore(fileURL: paths.stateFile),
        client: CCUsageClient(executable: URL(fileURLWithPath: "/usr/bin/false")),
        aggregationCache: nil
      )
    })
    let owner = MachineRegistryMutationOwner(store: registryStore, registry: registry, runtime: collector)
    return MachineDashboardRouter(store: store, collector: collector, mutationOwner: owner, paths: paths)
  }
}
