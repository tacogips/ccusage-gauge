import Foundation
import Testing
@testable import AppCLI
@testable import AppCore

private struct StubCCUsageRunner: CCUsageCommandRunner {
  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    let payload: String
    switch arguments.first {
    case "blocks": payload = #"{"blocks":[]}"#
    case "daily": payload = #"{"daily":[]}"#
    case "session": payload = #"{"session":[]}"#
    default: throw CCUsageCommandFailure(runnerKind: .local, phase: .commandExited, exitStatus: 2)
    }
    return ProcessResult(stdout: Data(payload.utf8), stderr: Data(), exitStatus: 0)
  }
}

private struct LiveServer {
  let client: DashboardAPIClient
  let collector: MachineCollector
  let server: DashboardHTTPServer
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func startLiveServer() throws -> LiveServer {
  let root = try temporaryDirectory()
  let paths = AppPaths(
    configFile: root.appendingPathComponent("config/ccusage-gauge/ccusage-config.json"),
    stateFile: root.appendingPathComponent("state/ccusage-gauge/state.json"),
    aggregationCacheFile: root.appendingPathComponent("cache/ccusage-gauge/aggregates.sqlite3")
  )
  let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
  let registry = try registryStore.load()
  let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
  let stateStore = StateStore(fileURL: paths.stateFile)
  let collector = try MachineCollector(registry: registry, store: store) { descriptor in
    SnapshotService(
      stateStore: stateStore,
      client: CCUsageClient(commandRunner: StubCCUsageRunner(), machine: descriptor.id),
      aggregationCache: nil
    )
  }
  let owner = MachineRegistryMutationOwner(store: registryStore, registry: registry, runtime: collector)
  let machineRouter = MachineDashboardRouter(store: store, collector: collector, mutationOwner: owner, paths: paths)
  let router = DashboardRouter(machineRouter: machineRouter, assetResolver: StaticAssetResolver(explicitRoot: root))
  // Random ports can collide with other listeners, so retry a few candidates.
  var lastError: Error?
  for _ in 0..<5 {
    let server = DashboardHTTPServer(router: router)
    let port = UInt16.random(in: 20_000...50_000)
    do {
      try server.start(port: port)
      return LiveServer(
        client: DashboardAPIClient(port: Int(port)),
        collector: collector,
        server: server
      )
    } catch {
      lastError = error
    }
  }
  throw lastError ?? CocoaError(.fileNoSuchFile)
}

@Suite("ClientServerRoundTripTests")
struct ClientServerRoundTripTests {
  @Test func addsListsAndShowsMachinesAndReadsDashboard() async throws {
    let live = try startLiveServer()
    defer {
      live.server.stop()
      Task { await live.collector.stop() }
    }

    let payload = MachineCreatePayload(
      id: "remote",
      displayName: "Remote",
      enabled: true,
      ssh: MachineCreatePayload.SSHPayload(
        host: "example.com",
        port: 22,
        user: "ccusage",
        identityFile: nil,
        extraOptions: [],
        remoteCcusagePath: "ccusage"
      )
    )
    let created = try await live.client.machineAdd(payload)
    #expect(created.value.id == "remote")
    #expect(created.value.kind == .ssh)

    let list = try await live.client.machinesList()
    #expect(list.value.machines.map(\.id).sorted() == ["local", "remote"])

    let show = try await live.client.machineShow(id: "remote")
    #expect(show.value.ssh?.host == "example.com")

    let status = try await live.client.machineStatus(machine: .all)
    #expect(Set(status.value.machines.map(\.id)) == ["local", "remote"])

    let load = try await live.client.loadStatus(machine: .all)
    #expect(load.value.requested == "all")

    // Force a collection so a scope-bearing read succeeds.
    _ = await live.collector.refresh(machine: "local")
    let budget = try await live.client.budget(machine: .local)
    #expect(budget.value.scope.requested == "local")
    #expect(!budget.raw.isEmpty)
  }

  @Test func rejectsInvalidMachineWithStructuredError() async throws {
    let live = try startLiveServer()
    defer {
      live.server.stop()
      Task { await live.collector.stop() }
    }
    let payload = MachineCreatePayload(
      id: "remote",
      displayName: "Remote",
      enabled: true,
      ssh: MachineCreatePayload.SSHPayload(
        host: "example.com",
        port: 22,
        user: "bad user",
        identityFile: nil,
        extraOptions: [],
        remoteCcusagePath: "ccusage"
      )
    )
    do {
      _ = try await live.client.machineAdd(payload)
      Issue.record("Expected a validation rejection")
    } catch let DashboardClientError.api(error) {
      #expect(error.httpStatus == 422)
      #expect(error.isServerError == false)
      #expect(!error.fieldErrors.isEmpty)
    }
  }
}
