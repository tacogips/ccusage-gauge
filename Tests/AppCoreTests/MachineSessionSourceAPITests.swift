import Foundation
import Testing
@testable import AppCore

private struct SessionSourceAPIRunner: CCUsageCommandRunner {
  func run(arguments: [String], timeoutSeconds: TimeInterval) async throws -> ProcessResult {
    let json = arguments.first == "blocks" ? #"{"blocks":[]}"# : #"{"daily":[],"session":[]}"#
    return ProcessResult(stdout: Data(json.utf8), stderr: Data(), exitStatus: 0)
  }
}

@Suite("MachineSessionSourceAPITests")
struct MachineSessionSourceAPITests {
  @Test func createPatchReadAndLocalPatchRoundTrip() async throws {
    let runtime = try await makeRuntime()
    defer { Task { await runtime.collector.stop() } }
    let create = #"""
      {"id":"remote","displayName":"Remote","kind":"ssh","enabled":true,
       "codexSessionDirs":["/srv/codex-a"],"claudeConfigDirs":["~/claude-a"],
       "includeDefaultCodexDir":false,"includeDefaultClaudeDir":false,
       "ssh":{"host":"localhost","port":22,"user":"user","extraOptions":[],"remoteCcusagePath":"ccusage"}}
      """#
    let created = await runtime.router.route(
      target: "/api/machines",
      method: "POST",
      headers: mutationHeaders,
      body: Data(create.utf8),
      listenerPort: 18_081
    )
    #expect(created.status == 201)
    #expect(try JSONDecoder().decode(MachineDescriptor.self, from: created.body).codexSessionDirs == ["/srv/codex-a"])

    let patched = await runtime.router.route(
      target: "/api/machines/remote",
      method: "PATCH",
      headers: mutationHeaders,
      body: Data(#"{"codexSessionDirs":[],"includeDefaultCodexDir":true}"#.utf8),
      listenerPort: 18_081
    )
    #expect(patched.status == 200)
    let remote = try JSONDecoder().decode(MachineDescriptor.self, from: patched.body)
    #expect(remote.codexSessionDirs.isEmpty)
    #expect(remote.includeDefaultCodexDir)
    #expect(remote.claudeConfigDirs == ["~/claude-a"])

    let localPatch = await runtime.router.route(
      target: "/api/machines/local",
      method: "PATCH",
      headers: mutationHeaders,
      body: Data(#"{"claudeConfigDirs":["/srv/local-claude"],"includeDefaultClaudeDir":false}"#.utf8),
      listenerPort: 18_081
    )
    #expect(localPatch.status == 200)
    let local = try JSONDecoder().decode(MachineDescriptor.self, from: localPatch.body)
    #expect(local.claudeConfigDirs == ["/srv/local-claude"])
    #expect(!local.includeDefaultClaudeDir)
  }

  @Test func malformedPathReturnsIndexedFieldError() async throws {
    let runtime = try await makeRuntime()
    defer { Task { await runtime.collector.stop() } }
    let create = #"""
      {"id":"remote","displayName":"Remote","kind":"ssh","enabled":true,
       "codexSessionDirs":["relative"],
       "ssh":{"host":"localhost","port":22,"user":"user"}}
      """#
    let response = await runtime.router.route(
      target: "/api/machines",
      method: "POST",
      headers: mutationHeaders,
      body: Data(create.utf8),
      listenerPort: 18_081
    )
    #expect(response.status == 422)
    let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    let error = try #require(object["error"] as? [String: Any])
    let fields = try #require(error["fieldErrors"] as? [String: String])
    #expect(fields["codexSessionDirs[0]"] != nil)
  }

  private var mutationHeaders: [String: String] {
    [
      "host": "127.0.0.1:18081",
      "content-type": "application/json",
      "x-ccusage-gauge-mutation": "1"
    ]
  }

  private func makeRuntime() async throws -> APIRuntime {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = AppPaths(
      configFile: root.appendingPathComponent("config/ccusage-gauge/config.json"),
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
        client: CCUsageClient(commandRunner: SessionSourceAPIRunner(), machine: descriptor.id)
      )
    }
    let owner = MachineRegistryMutationOwner(store: persistence, registry: registry, runtime: collector)
    return APIRuntime(
      router: MachineDashboardRouter(store: store, collector: collector, mutationOwner: owner, paths: paths),
      collector: collector
    )
  }
}

private struct APIRuntime {
  let router: MachineDashboardRouter
  let collector: MachineCollector
}
