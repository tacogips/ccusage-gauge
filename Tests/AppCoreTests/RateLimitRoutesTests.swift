import Foundation
import Testing
@testable import AppCore

@Suite("RateLimitRoutesTests")
struct RateLimitRoutesTests {
  @Test func routesAreIdenticalAndIndependent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let window = try RateLimitWindow(windowSeconds: 18_000, usedPercent: 47, resetsAt: now.addingTimeInterval(3600))
    let service = RateLimitUsageService(
      claude: FakeRateLimitFetcher([.success(RateLimitObservation(planType: "pro", observedAt: now, windows: [window]))]),
      codex: FakeRateLimitFetcher([.failure(RateLimitErrorCode.networkError)]),
      codexFallback: nil, now: { now }
    )
    let resolver = StaticAssetResolver(explicitRoot: root)
    let plain = DashboardRouter(snapshotProvider: { throw CancellationError() }, assetResolver: resolver, rateLimitService: service)
    let machine = try makeMachine(root: root, service: service)
    let delegated = DashboardRouter(machineRouter: machine, assetResolver: resolver)
    let first = await plain.route(target: "/api/rate-limits")
    let second = await machine.route(target: "/api/rate-limits?machine=remote1", method: "GET", headers: [:], body: Data(), listenerPort: 18081)
    let third = await delegated.route(target: "/api/rate-limits?machine=remote1")
    #expect(first.status == 200 && second.status == 200 && third.status == 200)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let result = try decoder.decode(RateLimitsResponse.self, from: first.body)
    let machineResult = try decoder.decode(RateLimitsResponse.self, from: second.body)
    let delegatedResult = try decoder.decode(RateLimitsResponse.self, from: third.body)
    #expect(result == machineResult)
    #expect(result == delegatedResult)
    #expect(result.scope == "local")
    #expect(result.providers[0].provider == .claude)
    #expect(result.providers[0].fiveHour?.remainingPercent == 53)
    #expect(result.providers[1].status == .unavailable)
    let object = try JSONSerialization.jsonObject(with: first.body)
    let allowed: Set<String> = [
      "generatedAt", "scope", "providers", "provider", "status", "errorCode", "message", "planType", "fetchedAt",
      "stale", "fiveHour", "weekly", "otherWindows", "kind", "windowSeconds", "usedPercent", "remainingPercent", "resetsAt"
    ]
    #expect(keys(in: object).isSubset(of: allowed))
    let text = try #require(String(bytes: first.body, encoding: .utf8))
    for secret in [testClaudeToken, testCodexToken, testCodexAccountID] { #expect(!text.contains(secret)) }
  }

  @Test func errorsOnBothSurfaces() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = DashboardRouter(snapshotProvider: { throw CancellationError() }, assetResolver: StaticAssetResolver(explicitRoot: root))
    let machine = try makeMachine(root: root, service: nil)
    for method in ["POST", "PUT", "GET"] {
      let responses = [await plain.route(target: "/api/rate-limits", method: method),
                       await machine.route(target: "/api/rate-limits", method: method, headers: [:], body: Data(), listenerPort: 18081)]
      for response in responses {
        #expect(response.status == (method == "GET" ? 503 : 405))
        let object = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: [String: String]])
        #expect(object["error"]?["code"] == (method == "GET" ? "rate_limits_unavailable" : "method_not_allowed"))
      }
    }
  }

  private func keys(in value: Any) -> Set<String> {
    if let dictionary = value as? [String: Any] {
      return dictionary.reduce(into: Set(dictionary.keys)) { $0.formUnion(keys(in: $1.value)) }
    }
    if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(keys(in: $1)) } }
    return []
  }

  private func makeMachine(root: URL, service: RateLimitUsageService?) throws -> MachineDashboardRouter {
    let paths = AppPaths(configFile: root.appendingPathComponent("config.json"), stateFile: root.appendingPathComponent("state.json"), aggregationCacheFile: root.appendingPathComponent("cache.sqlite3"))
    let registryStore = MachineRegistryStore(fileURL: paths.machinesFile)
    let registry = try registryStore.load()
    let store = MachineSnapshotStore(registry: registry, refreshIntervalSeconds: 20)
    let collector = try MachineCollector(registry: registry, store: store, connectionTester: { _ in }, serviceFactory: { _ in
      SnapshotService(stateStore: StateStore(fileURL: paths.stateFile), client: CCUsageClient(executable: URL(fileURLWithPath: "/usr/bin/false")), aggregationCache: nil)
    })
    let owner = MachineRegistryMutationOwner(store: registryStore, registry: registry, runtime: collector)
    return MachineDashboardRouter(store: store, collector: collector, mutationOwner: owner, paths: paths, rateLimitService: service)
  }
}
